import Foundation
import GRDB

/// Watches log directories for AI coding tools and incrementally parses them.
///
/// Incremental parsing: tracks per-file byte positions so FSEvent rescans only
/// read new data (not the whole file).  Positions are persisted to UserDefaults
/// so they survive restarts.
final class LogWatcher {
    static let shared = LogWatcher()
    private var claudeSource: DispatchSourceFileSystemObject?

    /// Last-read byte offset per file path.  Persisted in UserDefaults.
    private var filePositions: [String: UInt64] = [:]
    /// Leftover partial line (when a write stops mid-line) per file path.
    private var partialLines: [String: String] = [:]

    private init() {
        // Restore saved positions from previous run
        if let saved = UserDefaults.standard.dictionary(forKey: "logwatcher_positions") as? [String: UInt64] {
            filePositions = saved
        }
    }

    func start() {
        // Offload the initial scan to a background queue — scanning all git
        // repos and JSONL files on the main thread blocks the run loop and
        // makes the menu bar item unresponsive for seconds after launch.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.watchClaudeCode()
            self?.discoverAndWatchRepos()
        }
    }

    func stop() {
        claudeSource?.cancel()
        claudeSource = nil
        persistPositions()
    }

    // MARK: - Claude Code

    private func watchClaudeCode() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("Claude Code projects dir not found")
            return
        }
        scanClaudeCode(at: dir)

        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        claudeSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        claudeSource?.setEventHandler { [weak self] in self?.scanClaudeCode(at: dir) }
        claudeSource?.setCancelHandler { close(fd) }
        claudeSource?.resume()
    }

    private func scanClaudeCode(at dir: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
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
                let llmFile = repoURL.appendingPathComponent(".aider.llm.history")
                guard FileManager.default.fileExists(atPath: llmFile.path) else { return }
                parseLinesIncremental(from: llmFile) { line in
                    AiderParser.parseJSONL(line: line, cwd: repoURL.path)
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
        UserDefaults.standard.set(filePositions, forKey: "logwatcher_positions")
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
        let cost = PricingManager.shared.costUSD(
            model: event.model,
            inTokens: event.inTokens,
            outTokens: event.outTokens,
            cacheTokens: event.cacheTokens
        )
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(sql: """
                        INSERT INTO usage_event
                          (ts, source, provider_id, model, in_tokens, out_tokens, cache_tokens, cost_usd, repo_path, session_id, dedupe_key)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(dedupe_key) DO UPDATE SET
                          provider_id = excluded.provider_id,
                          model       = excluded.model,
                          cost_usd    = excluded.cost_usd,
                          repo_path   = excluded.repo_path
                        """, arguments: [
                            event.ts, event.source, providerId, event.model,
                            event.inTokens, event.outTokens, event.cacheTokens,
                            cost, event.repoPath, event.sessionId, event.dedupeKey,
                        ])
                }
            } catch {
                print("Failed to insert: \(error)")
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

}
