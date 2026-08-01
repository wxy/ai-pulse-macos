import Foundation
import GRDB

/// Watches log directories for AI coding tools and incrementally parses them.
///
/// Incremental parsing: tracks per-file byte positions so FSEvent rescans only
/// read new data (not the whole file).  Positions are persisted to UserDefaults
/// so they survive restarts.
final class LogWatcher: @unchecked Sendable {
    static let shared = LogWatcher()
    private var claudeSource: DispatchSourceFileSystemObject?

    /// Serial queue for ALL scanning/parsing. Serializing prevents data races on
    /// the mutable state below (filePositions/partialLines) and on GitMonitor's
    /// watched-repo set when start() is called from multiple places (launch,
    /// after granting access, after adding a directory) or when an FSEvent fires
    /// while an initial scan is still running.
    private let scanQueue = DispatchQueue(label: "com.wxy.aipulse.logwatcher.scan", qos: .utility)

    /// Last-read byte offset per file path.  Persisted in UserDefaults.
    private var filePositions: [String: UInt64] = [:]
    /// Leftover partial line (when a write stops mid-line) per file path.
    private var partialLines: [String: String] = [:]
    /// Last seen model per aider file (survives incremental scans).
    private var aiderModels: [String: String] = [:]

    /// Ensures positions are loaded before the first scan() runs.
    private let loadGroup = DispatchGroup()
    /// Tracks in-flight persist tasks so stop() can wait for them.
    private let persistGroup = DispatchGroup()

    private init() {
        loadGroup.enter()
        Task { await loadPositionsFromDB(); loadGroup.leave() }
    }

    private func loadPositionsFromDB() async {
        do {
            let rows = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT file_path, byte_offset FROM logwatcher_position")
            }
            var map = [String: UInt64]()
            for r in rows {
                if let path: String = r["file_path"], let offset: Int64 = r["byte_offset"] {
                    map[path] = UInt64(offset)
                }
            }
            if !map.isEmpty {
                filePositions = map
            } else if let saved = UserDefaults.standard.dictionary(forKey: "logwatcher_positions") as? [String: UInt64], !saved.isEmpty {
                // One-time migration from UserDefaults to DB
                filePositions = saved
                persistPositions()
                UserDefaults.standard.removeObject(forKey: "logwatcher_positions")
            }
        } catch {
            Logger.warning("LogWatcher: DB positions load failed, re-scanning all files: \(error)")
        }
    }

    func start() {
        scanQueue.async { [weak self] in
            let timedOut = self?.loadGroup.wait(timeout: .now() + 5.0) == .timedOut
            Task { @MainActor [weak self] in
                guard let self else { return }
                if timedOut {
                    Logger.warning("LogWatcher: DB positions load timed out after 5s, using in-memory positions")
                }
                self.watchClaudeCode()
                self.discoverAndWatchRepos()
            }
        }
    }

    /// Perform an incremental scan without setting up FSEvent watchers.
    /// Safe to call repeatedly; idempotent. Used by DataRefreshCoordinator.
    func scan() {
        scanQueue.async { [weak self] in
            let timedOut = self?.loadGroup.wait(timeout: .now() + 5.0) == .timedOut
            Task { @MainActor [weak self] in
                guard let self else { return }
                if timedOut {
                    Logger.warning("LogWatcher: DB positions load timed out after 5s, using in-memory positions")
                }
                self.scanClaudeProjectsOnly()
                self.discoverAndWatchRepos()
            }
        }
    }

    func stop() {
        claudeSource?.cancel()
        claudeSource = nil
        persistPositions()
        if persistGroup.wait(timeout: .now() + 3.0) == .timedOut {
            Logger.warning("LogWatcher: persist positions timed out during stop")
        }
    }

    // MARK: - Claude Code

    /// Scan-only variant of watchClaudeCode() — no FSEvent registration.
    /// Used by DataRefreshCoordinator for periodic incremental scans.
    private func scanClaudeProjectsOnly() {
        let dir = FileManager.default.realHomeDirectory
            .appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        scanClaudeCode(at: dir)
    }

    private func watchClaudeCode() {
        let dir = FileManager.default.realHomeDirectory
            .appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            Logger.warning("Claude Code projects dir not found")
            return
        }
        scanClaudeCode(at: dir)

        // Already watching (start() may be called again after granting access
        // or adding repos) — re-scan above is enough; don't create a 2nd source.
        guard claudeSource == nil else { return }

        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        claudeSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        claudeSource?.setEventHandler { [weak self] in
            guard let self else { return }
            self.scanQueue.async { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.scanClaudeCode(at: dir)
                }
            }
        }
        claudeSource?.setCancelHandler { close(fd) }
        claudeSource?.resume()
    }

    private func scanClaudeCode(at dir: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            // Register the repo even for files with no new content — ensures
            // repos from past sessions are re-watched after an app restart.
            discoverAndWatchRepo(from: file)
            parseLinesIncremental(from: file) { line in
                guard let event = ClaudeCodeParser.parse(line: line) else { return nil }
                // Resolve cwd to git repo root for consistent repo_path
                var repoPath = event.repoPath
                if let repoUrl = findGitRepo(containing: repoPath) {
                    GitMonitor.shared.watch(repoPath: repoUrl.path)
                    repoPath = repoUrl.path
                }
                return UsageEvent(ts: event.ts, source: event.source, model: event.model,
                    inTokens: event.inTokens, outTokens: event.outTokens, cacheTokens: event.cacheTokens,
                    repoPath: repoPath, sessionId: event.sessionId, dedupeKey: event.dedupeKey)
            }
        }
    }

    // MARK: - aider

    private func discoverAndWatchRepos() {
        let dirs = UserDefaults.standard.stringArray(forKey: "repo_search_dirs")
            ?? ["~/dev", "~/projects", "~/code"]
        for dir in dirs {
            let expanded = NSString(string: dir).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { continue }
            enumerateGitRepos(in: URL(fileURLWithPath: expanded)) { repoURL in
                GitMonitor.shared.watch(repoPath: repoURL.path)
                // aider v0.75+: Markdown chat history
                let chatMD = repoURL.appendingPathComponent(".aider.chat.history.md")
                if FileManager.default.fileExists(atPath: chatMD.path) {
                    Logger.debug("LogWatcher: found aider chat history at \(chatMD.path)")
                    var parsedCount = 0
                    let filePath = chatMD.path
                    parseLinesIncremental(from: chatMD) { line in
                        // Track model across lines & scans
                        if let m = AiderParser.parseModelLine(line) { aiderModels[filePath] = m; return nil }
                        let model = aiderModels[filePath]
                        let fileModDate = (try? chatMD.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        let fileTS = Int((fileModDate?.timeIntervalSince1970 ?? 0) * 1000)
                        if let event = AiderParser.parseMarkdown(line: line, cwd: repoURL.path, model: model, fallbackDate: fileTS) {
                            parsedCount += 1
                            return event
                        }
                        return nil
                    }
                    if parsedCount > 0 {
                        Logger.info("LogWatcher: parsed \(parsedCount) aider events from \(chatMD.path)")
                    }
                }
                // aider pre-0.75: JSONL format
                let llmFile = repoURL.appendingPathComponent(".aider.llm.history")
                if FileManager.default.fileExists(atPath: llmFile.path) {
                    parseLinesIncremental(from: llmFile) { line in
                        AiderParser.parseJSONL(line: line, cwd: repoURL.path)
                    }
                }
            }
        }
    }

    // MARK: - Shared helpers

    /// Read only new bytes since the last scan.  Uses FileHandle seeking +
    /// a partial-line buffer so we never lose or duplicate a line when the
    /// file is appended mid-write.
    private func parseLinesIncremental(from url: URL, parser: (String) -> UsageEvent?) {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64
        else { return }

        let lastPos = filePositions[path] ?? 0

        // File was truncated or rotated — start over
        let startPos = lastPos <= fileSize ? lastPos : 0
        guard startPos < fileSize else { return } // nothing new

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        try? handle.seek(toOffset: startPos)
        let newBytes = handle.readData(ofLength: Int(fileSize - startPos))
        guard let raw = String(data: newBytes, encoding: .utf8), !raw.isEmpty else {
            filePositions[path] = fileSize; persistPositions(); return
        }

        // Prepend any partial line left over from the last read
        let content = (partialLines[path] ?? "") + raw
        let lines = content.components(separatedBy: .newlines)

        // Process all complete lines (drop the last — it may be incomplete)
        for line in lines.dropLast() {
            guard !line.isEmpty, let event = parser(line) else { continue }
            insertEvent(event)
        }

        // Save the trailing (potentially incomplete) line for next time
        partialLines[path] = lines.last ?? ""

        filePositions[path] = fileSize
        persistPositions()
    }

    private func persistPositions() {
        let positions = filePositions
        persistGroup.enter()
        Task {
            defer { persistGroup.leave() }
            do {
                try await AppDatabase.shared.write { db in
                    for (path, offset) in positions {
                        try db.execute(sql: """
                            INSERT OR REPLACE INTO logwatcher_position (file_path, byte_offset)
                            VALUES (?, ?)
                            """, arguments: [path, Int64(offset)])
                    }
                }
            } catch {
                Logger.error("LogWatcher: persist positions failed: \(error)")
            }
        }
    }

    private func enumerateGitRepos(in dir: URL, handler: (URL) -> Void) {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        for case let url as URL in enumerator {
            let gitDir = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            handler(url)
            enumerator.skipDescendants()
        }
    }

    private func insertEvent(_ event: UsageEvent) {
        let providerId = PricingManager.shared.providerId(for: event.model) ?? "unknown"

        // CostSource arbitration
        let sources = IntegrationRegistry.activeCostSources()
        let preferred = IntegrationRegistry.config(for: event.source).preferredAPIKeyCostSourceId
        let (csId, confidence) = Arbitrator.resolve(
            model: event.model, source: event.source,
            costSources: sources, preferredAPIKeyId: preferred
        )

        // Always compute token-pricing cost for per-repo CPL attribution.
        // Balance delta (ApiPoller) gives the exact total but can't be attributed per-repo.
        let cost = PricingManager.shared.costUSD(
            model: event.model,
            inTokens: event.inTokens,
            outTokens: event.outTokens,
            cacheTokens: event.cacheTokens
        )

        // For apiKey balance-tracked sources, the per-event cost is token-pricing (estimated),
        // while the CostSource itself is .exact (from balance delta).
        let effectiveConfidence: CostConfidence
        if let cs = sources.first(where: { $0.id == csId }),
           case .apiKey(let pid) = cs.kind,
           ProviderRegistry.byId(pid)?.canFetchBalance == true {
            effectiveConfidence = .estimated
        } else {
            effectiveConfidence = confidence
        }

        Task {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(sql: """
                        INSERT INTO usage_event
                          (ts, source, provider_id, model, in_tokens, out_tokens,
                           cache_tokens, cost_usd, repo_path, session_id, dedupe_key,
                           cost_source_id, cost_confidence)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(dedupe_key) DO UPDATE SET
                          provider_id = excluded.provider_id,
                          model       = excluded.model,
                          cost_usd    = excluded.cost_usd,
                          repo_path   = excluded.repo_path,
                          cost_source_id = excluded.cost_source_id,
                          cost_confidence = excluded.cost_confidence
                        """, arguments: [
                            event.ts, event.source, providerId, event.model,
                            event.inTokens, event.outTokens, event.cacheTokens,
                            cost, event.repoPath, event.sessionId, event.dedupeKey,
                            csId, effectiveConfidence.rawValue,
                        ])
                }
                DataRefreshCoordinator.shared.notifyPhaseIngest()
            } catch {
                Logger.error("Failed to insert usage_event: \(error)")
            }
        }
    }

    /// Walk up from a path until we find a .git directory
    private func findGitRepo(containing path: String?) -> URL? {
        guard var url = path.map({ URL(fileURLWithPath: $0) }) else { return nil }
        while url.path != "/" {
            let git = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// Read the first line of a Claude Code JSONL file to discover and register
    /// the associated git repo — regardless of whether the file has new content.
    /// Failures are silent (the file may be mid-write); the next scan will retry.
    private func discoverAndWatchRepo(from file: URL) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096),
              let text = String(data: data, encoding: .utf8),
              let firstLine = text.components(separatedBy: .newlines).first,
              !firstLine.isEmpty,
              let jsonData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let cwd = json["cwd"] as? String,
              let repoUrl = findGitRepo(containing: cwd)
        else { return }
        GitMonitor.shared.watch(repoPath: repoUrl.path)
    }

}
