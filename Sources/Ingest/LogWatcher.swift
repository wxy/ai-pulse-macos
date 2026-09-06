import Foundation
import GRDB
import Darwin
import zstd

/// Watches log directories for AI coding tools and incrementally parses them.
///
/// Incremental parsing: tracks per-file byte positions so FSEvent rescans only
/// read new data (not the whole file).  Positions are persisted to UserDefaults
/// so they survive restarts.
nonisolated final class LogWatcher: @unchecked Sendable {
    static let shared = LogWatcher()
    private var claudeSource: DispatchSourceFileSystemObject?
    private var codexSource: DispatchSourceFileSystemObject?

    /// Serial queue for ALL scanning/parsing. Serializing prevents data races on
    /// the mutable state below (filePositions/partialLines) and on GitMonitor's
    /// watched-repo set when start() is called from multiple places (launch,
    /// after granting access, after adding a directory) or when an FSEvent fires
    /// while an initial scan is still running.
    private let scanQueue = DispatchQueue(label: "com.wxy.aipulse.logwatcher.scan", qos: .utility)
    private let stateLock = NSLock()

    /// Last-read byte offset per file path.  Persisted in UserDefaults.
    private var filePositions: [String: UInt64] = [:]
    /// Leftover partial line (when a write stops mid-line) per file path.
    private var partialLines: [String: String] = [:]
    /// Last seen model per aider file (survives incremental scans).
    private var aiderModels: [String: String] = [:]

    /// FSEvents can fire many times while one cold-history scan is running.
    /// Coalesce those notifications into a single follow-up scan; a serial
    /// queue alone would otherwise preserve a backlog of duplicate full scans.
    private var scanQueued = false

    /// Visible while a cold database is still importing history. The app can
    /// already show balances and cached snapshots, but usage panels must not be
    /// mistaken for an empty account while backfill is running.
    static let backfill = IngestionBackfillState()

    /// Ensures positions are loaded before the first scan() runs.
    private let loadGroup = DispatchGroup()
    /// Tracks in-flight persist tasks so stop() can wait for them.
    private let persistGroup = DispatchGroup()

    private init() {
        loadGroup.enter()
        scanQueue.async {
            Task { await self.loadPositionsFromDB(); self.loadGroup.leave() }
        }
    }

    private func loadPositionsFromDB() async {
        do {
            let map = try await AppDatabase.shared.read { db -> [String: UInt64] in
                let rows = try Row.fetchAll(db, sql: "SELECT file_path, byte_offset FROM logwatcher_position")
                var result = [String: UInt64]()
                for r in rows {
                    if let path: String = r["file_path"], let offset: Int64 = r["byte_offset"] {
                        result[path] = UInt64(offset)
                    }
                }
                return result
            }
            applyLoadedPositions(map)
        } catch {
            Logger.warning("LogWatcher: DB positions load failed, re-scanning all files: \(error)")
        }
    }

    private func applyLoadedPositions(_ map: [String: UInt64]) {
        stateLock.withLock {
            if !map.isEmpty {
                filePositions = map
            } else if let saved = UserDefaults.standard.dictionary(forKey: "logwatcher_positions") as? [String: UInt64], !saved.isEmpty {
                // One-time migration from UserDefaults to DB
                filePositions = saved
                persistPositions(filePositions)
                UserDefaults.standard.removeObject(forKey: "logwatcher_positions")
            }
        }
    }

    func start() {
        scanQueue.async { [weak self] in
            let timedOut = self?.loadGroup.wait(timeout: .now() + 5.0) == .timedOut
            guard let self else { return }
            if timedOut {
                Logger.warning("LogWatcher: DB positions load timed out after 5s, using in-memory positions")
            }
        let isColdStart = self.filePositions.isEmpty
        LogWatcher.backfill.setActive(isColdStart)
        self.watchClaudeCode(scanNow: false)
        self.watchCodex(scanNow: false)
        self.runScan(includeClaudeProjects: true)
        LogWatcher.backfill.setActive(false)
            if isColdStart {
                // A previous launch could have cached a snapshot before the
                // cold backfill finished. Rebuild after history is settled.
                Task { await DashboardCache.invalidateAll() }
                DispatchQueue.main.async {
                    DataRefreshCoordinator.shared.notifyDataChange()
                }
            }
        }
    }

    /// Perform an incremental scan without setting up FSEvent watchers.
    /// Safe to call repeatedly; idempotent. Used by DataRefreshCoordinator.
    func scan() {
        scanQueue.async { [weak self] in
            guard let self, !self.scanQueued else { return }
            self.scanQueued = true
            self.scanQueue.async { [weak self] in
                guard let self else { return }
                defer { self.scanQueued = false }
                self.runScan(includeClaudeProjects: true)
            }
        }
    }

    private func runScan(includeClaudeProjects: Bool) {
        let timedOut = loadGroup.wait(timeout: .now() + 5.0) == .timedOut
        if timedOut {
            Logger.warning("LogWatcher: DB positions load timed out after 5s, using in-memory positions")
        }
        if includeClaudeProjects {
                self.scanClaudeProjectsOnly()
        }
        discoverAndWatchRepos()
        scanCodexSessions()
        scanDeepSeekHarnessSessions()
        scanQwenSessions()
        scanOpenCodeSessions()
    }

    func stop() {
        claudeSource?.cancel()
        claudeSource = nil
        codexSource?.cancel()
        codexSource = nil
        persistPositions()
        // Deliberately NO blocking wait for the persist group: at quit the main
        // thread must stay on the run loop so queued @MainActor work (the FSEvent
        // handler's `Task { @MainActor ... }`) can be dispatched. Blocking here
        // wedges the Swift MainActor executor and crashes with
        // _dispatch_assert_queue_fail ("did not quit normally"). Persisting the
        // last byte offsets is best-effort; losing them just re-scans on next run.
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

    private func watchClaudeCode(scanNow: Bool = true) {
        let dir = FileManager.default.realHomeDirectory
            .appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            Logger.warning("Claude Code projects dir not found")
            return
        }
        if scanNow {
            scanClaudeCode(at: dir)
        }

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
            self.scan()
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
            let prefixMeta = SessionInfoBackfill.claudePrefixMetadata(from: file)
            var sessionId: String? = prefixMeta?.sessionId
            var title: String? = prefixMeta?.title
            var repo: String? = prefixMeta?.repo
            var minTs = Int.max
            var maxTs = 0
            parseLinesIncremental(from: file) { line in
                if sessionId == nil { sessionId = line.jsonStringField("sessionId") }
                if repo == nil { repo = line.jsonStringField("cwd") }
                if title == nil, let msg = ClaudeCodeParser.firstUserMessage(fromLine: line) {
                    title = SessionInfoRecord.makeTitle(msg)
                }
                guard let event = ClaudeCodeParser.parse(line: line) else { return nil }
                minTs = min(minTs, event.ts)
                maxTs = max(maxTs, event.ts)
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
            guard let sid = sessionId, maxTs > 0 else { continue }
            upsertSessionInfo(SessionInfoRecord(
                source: "claude-code", sessionId: sid, title: title, repo: repo,
                firstTs: minTs, lastTs: maxTs, completed: nil, windowTokens: nil))
        }
    }

    // MARK: - Codex CLI / ChatGPT desktop

    /// Scan `~/.codex/sessions/**/rollout-*.jsonl` incrementally.
    /// Idempotent — `parseLinesIncremental` resumes from the persisted byte
    /// offset of each file. Runs on every phase-1 tick.
    private func scanCodexSessions() {
        let home = FileManager.default.realHomeDirectory
        let sessionsDir = home.appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir.path),
              let enumerator = FileManager.default.enumerator(
                  at: sessionsDir,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }

        var files = [URL]()
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            files.append(url)
        }

        // Cold starts used to parse month-old files before the current day.
        // Rollout names sort chronologically, so newest-first makes Today and
        // the current session visible while older history continues backfilling.
        for url in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            parseCodexFile(url)
        }
    }

    /// Watch `~/.codex/sessions` with FSEvents so ChatGPT desktop / Codex CLI
    /// sessions are ingested in real time, mirroring the Claude Code watcher.
    private func watchCodex(scanNow: Bool = true) {
        let home = FileManager.default.realHomeDirectory
        let sessionsDir = home.appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            Logger.warning("Codex sessions dir not found")
            return
        }
        if scanNow {
            scanCodexSessions()
        }

        guard codexSource == nil else { return }

        let fd = open(sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        codexSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        codexSource?.setEventHandler { [weak self] in
            guard let self else { return }
            self.scan()
        }
        codexSource?.setCancelHandler { close(fd) }
        codexSource?.resume()
    }

    // MARK: - DeepSeek Harness

    private func scanDeepSeekHarnessSessions() {
        let home = FileManager.default.realHomeDirectory
        let sessionsDir = home.appendingPathComponent(".dsh/sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir.path),
              let enumerator = FileManager.default.enumerator(
                  at: sessionsDir,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }

        var files = [(url: URL, modified: Date)]()
        for case let url as URL in enumerator
        where url.lastPathComponent == "session.jsonl.zstd" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, modified))
        }
        for item in files.sorted(by: { $0.modified > $1.modified }) {
            parseDeepSeekHarnessFile(item.url)
        }
    }

    private func parseDeepSeekHarnessFile(_ file: URL) {
        let path = file.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64
        else { return }

        // A zstd journal cannot be safely read at a byte boundary. Re-parse on
        // size changes and rely on usage_event dedupe keys to keep idempotence.
        if filePositions[path] == fileSize { return }

        let result: DeepSeekHarnessScanResult
        do {
            result = try parseDeepSeekHarnessStream(at: file)
        } catch {
            Logger.warning("LogWatcher: DSH decompression failed for \(path): \(error.localizedDescription)")
            return
        }

        if !result.events.isEmpty {
            insertEvents(result.events)
        }
        if let sessionId = result.sessionId, result.maxTs > 0 {
            upsertSessionInfo(SessionInfoRecord(
                source: "deepseek-harness", sessionId: sessionId,
                title: result.title, repo: result.cwd,
                firstTs: result.minTs, lastTs: result.maxTs,
                completed: result.completed ? true : nil, windowTokens: nil))
        }
        if result.parsedCount > 0 {
            Logger.info("LogWatcher: parsed \(result.parsedCount) DeepSeek Harness events from \(path), decompressedBytes=\(result.byteCount)")
        }
        filePositions[path] = fileSize
        persistPositions([path: fileSize])
    }

    private struct DeepSeekHarnessScanResult {
        var events: [UsageEvent]
        var cwd: String?
        var sessionId: String?
        var title: String?
        var model: String?
        var completed: Bool
        var minTs: Int
        var maxTs: Int
        var parsedCount: Int
        var byteCount: Int
    }

    /// Stream zstd output and retain only a bounded working set. The previous
    /// implementation materialized the decompressed journal three times: as
    /// Data, String, and an array of every line.
    private func parseDeepSeekHarnessStream(at url: URL) throws -> DeepSeekHarnessScanResult {
        let decoder = try ZstdStreamDecoder()

        var state = (
            cwd: String?.none,
            sessionId: String?.none,
            title: String?.none,
            completed: false
        )
        var currentModel: String? = nil
        var result = DeepSeekHarnessScanResult(
            events: [], cwd: nil, sessionId: nil, title: nil,
            completed: false, minTs: Int.max, maxTs: 0,
            parsedCount: 0, byteCount: 0
        )
        var splitter = LineSplitter()

        func processLine(_ line: String) {
            guard !line.isEmpty else { return }
            result.byteCount += line.utf8.count + 1
            if let metadata = DeepSeekHarnessParser.metadata(fromLine: line) {
                state.cwd = metadata.cwd ?? state.cwd
                state.sessionId = metadata.sessionId ?? state.sessionId
                state.title = metadata.title ?? state.title
                currentModel = metadata.model ?? currentModel
            }
            if DeepSeekHarnessParser.isComplete(fromLine: line) {
                state.completed = true
            }
            guard let event = DeepSeekHarnessParser.parse(
                line: line, cwd: state.cwd, model: currentModel,
                sessionId: state.sessionId)
            else { return }
            result.minTs = min(result.minTs, event.ts)
            result.maxTs = max(result.maxTs, event.ts)
            result.parsedCount += 1
            result.events.append(event)
            if result.events.count >= 512 {
                insertEvents(result.events)
                result.events.removeAll(keepingCapacity: false)
            }
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        while let compressedChunk = try handle.read(upToCount: 256 << 10), !compressedChunk.isEmpty {
            try decoder.decompress(compressedChunk) { chunk in
                splitter.append(chunk, handler: processLine)
            }
        }
        try decoder.finish { chunk in
            splitter.append(chunk, handler: processLine)
        }
        splitter.finish(handler: processLine)
        result.cwd = state.cwd
        result.sessionId = state.sessionId
        result.title = state.title
        result.model = currentModel
        result.completed = state.completed
        return result
    }

    private func parseCodexFile(_ file: URL) {
        var currentCwd: String? = nil
        var currentModel: String? = nil
        var currentSessionId: String? = nil
        var currentTitle: String? = nil
        var currentWindow: Int? = nil
        var currentCompleted = false
        var minTs = Int.max
        var maxTs = 0
        var parsedCount = 0
        let filePath = file.path
        let resume = hasNewBytes(at: file) ? codexResumeMetadata(at: file) : nil
        currentCwd = resume?.cwd
        currentModel = resume?.model
        currentSessionId = resume?.sessionId
        parseLinesIncremental(from: file) { line in
            // Track cwd / session_id (session_meta) and model (turn_context) across lines.
            if let m = CodexParser.sessionMetaModel(fromLine: line) { currentModel = m }
            if let cwd = CodexParser.cwd(fromLine: line) { currentCwd = cwd }
            if let sid = CodexParser.sessionId(fromLine: line) { currentSessionId = sid }
            if let m = CodexParser.model(fromLine: line) { currentModel = m }
            if currentTitle == nil, let msg = CodexParser.firstUserMessage(fromLine: line) {
                currentTitle = SessionInfoRecord.makeTitle(msg)
            }
            if currentWindow == nil, let w = CodexParser.windowTokens(fromLine: line) { currentWindow = w }
            if CodexParser.isSessionComplete(fromLine: line) { currentCompleted = true }
            if let event = CodexParser.parse(
                line: line,
                cwd: currentCwd,
                model: currentModel,
                sessionId: currentSessionId
            ) {
                minTs = min(minTs, event.ts)
                maxTs = max(maxTs, event.ts)
                parsedCount += 1
                return event
            }
            return nil
        }
        guard let sid = currentSessionId, maxTs > 0 else { return }
        // Prefer the ChatGPT app's own thread title over the first log message.
        let resolvedTitle = CodexThreadTitles.title(for: sid) ?? currentTitle
        upsertSessionInfo(SessionInfoRecord(
            source: "codex", sessionId: sid, title: resolvedTitle, repo: currentCwd,
            firstTs: minTs, lastTs: maxTs, completed: currentCompleted ? true : nil,
            windowTokens: currentWindow))
        if parsedCount > 0 {
            Logger.info("LogWatcher: parsed \(parsedCount) codex events from \(filePath)")
        }
    }

    private struct CodexResumeMetadata {
        let cwd: String?
        let sessionId: String?
        let model: String?
    }

    /// Incremental reads begin at the stored byte offset, so parser state from
    /// earlier lines no longer exists. Rebuild only the small metadata needed to
    /// attribute the new events; token_count parsing still stays incremental.
    private func codexResumeMetadata(at file: URL) -> CodexResumeMetadata? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let fileSize = attrs[.size] as? UInt64,
              let lastPos = filePositions[file.path],
              lastPos > 0, lastPos <= fileSize,
              let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }

        var cwd: String? = nil
        var sessionId: String? = nil
        var model: String? = nil

        var splitter = LineSplitter()
        var bytesRead = 0
        while bytesRead < lastPos,
              let chunk = try? handle.read(upToCount: min(1 << 20, Int(lastPos - UInt64(bytesRead)))),
              !chunk.isEmpty {
            bytesRead += chunk.count
            splitter.append(chunk) { line in
            if let value = CodexParser.cwd(fromLine: line) { cwd = value }
            if let value = CodexParser.sessionId(fromLine: line) { sessionId = value }
            if let value = CodexParser.sessionMetaModel(fromLine: line) ?? CodexParser.model(fromLine: line) {
                model = value
            }
            }
        }
        // `lastPos` is a byte boundary observed after a complete line in the
        // normal case. Do not consume a trailing partial line as metadata.
        return CodexResumeMetadata(cwd: cwd, sessionId: sessionId, model: model)
    }

    private func hasNewBytes(at file: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let fileSize = attrs[.size] as? UInt64
        else { return false }
        return filePositions[file.path] != fileSize
    }

    // MARK: - Qwen Code

    /// Scan `~/.qwen/projects/*/chats/*.jsonl` incrementally.
    /// Idempotent via `parseLinesIncremental` byte-offset resume.
    private func scanQwenSessions() {
        let home = FileManager.default.realHomeDirectory
        let projectsDir = home.appendingPathComponent(".qwen/projects")
        guard FileManager.default.fileExists(atPath: projectsDir.path),
              let enumerator = FileManager.default.enumerator(
                  at: projectsDir,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }

        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("chats")
        || (url.pathExtension == "jsonl" && url.deletingLastPathComponent().lastPathComponent == "chats") {
            // cwd is not in the Qwen log; use nil (token tracking only).
            parseQwenFile(url, cwd: nil)
        }
    }

    private func parseQwenFile(_ file: URL, cwd: String?) {
        var parsedCount = 0
        let filePath = file.path
        parseLinesIncremental(from: file) { line in
            if let event = QwenCodeParser.parse(line: line, cwd: cwd) {
                parsedCount += 1
                return event
            }
            return nil
        }
        if parsedCount > 0 {
            Logger.info("LogWatcher: parsed \(parsedCount) qwen-code events from \(filePath)")
        }
    }

    // MARK: - OpenCode

    /// Scan `~/.local/share/opencode/storage/message/**/msg_*.json`.
    /// Each file is one message JSON; dedupe is via the stable message id.
    private func scanOpenCodeSessions() {
        let home = FileManager.default.realHomeDirectory
        let msgDir = home.appendingPathComponent(".local/share/opencode/storage/message")
        guard FileManager.default.fileExists(atPath: msgDir.path),
              let enumerator = FileManager.default.enumerator(
                  at: msgDir,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }

        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("msg_") && url.pathExtension == "json" {
            insertOpenCodeFile(url)
        }
    }

    private func insertOpenCodeFile(_ file: URL) {
        guard let event = OpenCodeParser.parseFile(file, cwd: nil) else { return }
        insertEvent(event)
        Logger.debug("LogWatcher: parsed opencode event from \(file.path)")
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
        var events = [UsageEvent]()
        let pendingLine = partialLines[path].map { Data($0.utf8) } ?? Data()
        var splitter = LineSplitter(initialBytes: pendingLine)
        var bytesRead = 0

        while bytesRead < Int(fileSize - startPos),
              let chunk = try? handle.read(upToCount: min(1 << 20, Int(fileSize - startPos) - bytesRead)),
              !chunk.isEmpty {
            bytesRead += chunk.count
            splitter.append(chunk) { line in
                guard !line.isEmpty, let event = parser(line) else { return }
                events.append(event)
                if events.count >= 512 {
                    insertEvents(events)
                    events.removeAll(keepingCapacity: false)
                }
            }
        }

        // Save the trailing (potentially incomplete) line for next time.
        partialLines[path] = String(decoding: splitter.pendingBytes, as: UTF8.self)
        if !events.isEmpty {
            insertEvents(events)
        }

        filePositions[path] = fileSize
        persistPositions(filePositions)
    }

    private func persistPositions() {
        let positions = filePositions
        persistPositions(positions)
    }

    private func persistPositions(_ positions: [String: UInt64]) {
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
        GitRepoScanner.enumerate(in: dir, handler)
    }

    private func insertEvent(_ event: UsageEvent) {
        insertEvents([event])
    }

    /// Batch all events read from one file into a single SQLite transaction.
    /// A historical JSONL can contain thousands of rows; spawning one Task per
    /// row makes first launch fight itself for the database queue and UI.
    private func insertEvents(_ events: [UsageEvent]) {
        guard !events.isEmpty else { return }
        let rows = events.map { event -> (event: UsageEvent, providerId: String, confidence: CostConfidence, csId: String, cost: Double?) in
            let providerId = PricingManager.shared.providerId(for: event.model) ?? "unknown"

        // CostSource arbitration
        let sources = IntegrationRegistry.activeCostSources()
        let (csId, confidence) = Arbitrator.resolve(
            model: event.model, source: event.source,
            costSources: sources
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

        return (event, providerId, effectiveConfidence, csId, cost)
        }

        Task {
            do {
                try await AppDatabase.shared.write { db in
                    for row in rows {
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
                                row.event.ts, row.event.source, row.providerId, row.event.model,
                                row.event.inTokens, row.event.outTokens, row.event.cacheTokens,
                                row.cost, row.event.repoPath, row.event.sessionId, row.event.dedupeKey,
                                row.csId, row.confidence.rawValue,
                            ])
                    }
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

    /// Upsert one session's metadata into `session_info`. Runs async like the
    /// other DB writes in this file; failures are logged, never fatal.
    private func upsertSessionInfo(_ record: SessionInfoRecord) {
        guard let sid = record.sessionId else { return }
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(sql: """
                        INSERT INTO session_info (source, session_id, title, repo, first_ts, last_ts, completed, window_tokens)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(source, session_id) DO UPDATE SET
                            title = COALESCE(excluded.title, session_info.title),
                            repo = COALESCE(excluded.repo, session_info.repo),
                            first_ts = MIN(session_info.first_ts, excluded.first_ts),
                            last_ts = MAX(session_info.last_ts, excluded.last_ts),
                            completed = COALESCE(excluded.completed, session_info.completed),
                            window_tokens = COALESCE(excluded.window_tokens, session_info.window_tokens)
                        """, arguments: [record.source, sid, record.title, record.repo,
                                         record.firstTs, record.lastTs, record.completed, record.windowTokens])
                }
            } catch {
                Logger.error("LogWatcher: session_info upsert failed: \(error)")
            }
        }
    }

    /// Entry point for the one-time backfill (SessionInfoBackfill) to reuse
    /// the same upsert path without exposing it.
    static func upsertForBackfill(_ record: SessionInfoRecord) {
        LogWatcher.shared.upsertSessionInfo(record)
    }
}

/// Small thread-safe flag shared with UI during the first cold-history import.
final class IngestionBackfillState: @unchecked Sendable {
    static let changeNotification = Notification.Name("ingestionBackfillDidChange")
    private let lock = NSLock()
    private var active = false

    var isActive: Bool {
        lock.withLock { active }
    }

    func setActive(_ isActive: Bool) {
        let didChange: Bool = lock.withLock {
            let didChange = active != isActive
            active = isActive
            return didChange
        }
        guard didChange else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.changeNotification, object: nil)
        }
    }
}

private enum ZstdDecoderError: LocalizedError {
    case decompressionFailed(Int)
    case truncatedStream

    var errorDescription: String? {
        switch self {
        case .decompressionFailed(let code):
            return "zstd decompression failed with code \(code)"
        case .truncatedStream:
            return "zstd stream ended before its final frame"
        }
    }
}

/// Streams compressed DSH journals through libzstd without spawning a helper
/// process or materializing the decompressed file in memory.
final class ZstdStreamDecoder {
    private let context: OpaquePointer
    private var pendingInput = Data()
    private var frameComplete = false

    init() throws {
        guard let context = ZSTD_createDCtx() else {
            throw ZstdDecoderError.decompressionFailed(0)
        }
        self.context = context
    }

    deinit {
        _ = ZSTD_freeDCtx(context)
    }

    func decompress(_ input: Data, outputHandler: (Data) throws -> Void) throws {
        var compressed = pendingInput
        compressed.append(input)
        pendingInput.removeAll(keepingCapacity: true)
        frameComplete = false

        var consumed = 0
        try compressed.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while consumed < raw.count {
                let source = raw.baseAddress?.advanced(by: consumed)
                var inputBuffer = ZSTD_inBuffer(
                    src: source,
                    size: raw.count - consumed,
                    pos: 0
                )
                let code = try withUnsafeMutablePointer(to: &inputBuffer) { inputPointer in
                    try run(allowPendingInput: true, outputHandler: outputHandler) { outputBuffer in
                        ZSTD_decompressStream(context, outputBuffer, inputPointer)
                    }
                }
                guard inputBuffer.pos > 0 else { break }
                consumed += inputBuffer.pos
                if code == 0 {
                    frameComplete = true
                } else {
                    frameComplete = false
                    break
                }
            }
        }

        if consumed < compressed.count {
            pendingInput = compressed.subdata(in: consumed..<compressed.count)
        }
    }

    func finish(outputHandler: (Data) throws -> Void) throws {
        if !pendingInput.isEmpty {
            let pending = pendingInput
            pendingInput.removeAll(keepingCapacity: false)
            try decompress(pending, outputHandler: outputHandler)
            if !pendingInput.isEmpty {
                throw ZstdDecoderError.truncatedStream
            }
        }

        guard !frameComplete else { return }
        var inputBuffer = ZSTD_inBuffer(src: nil, size: 0, pos: 0)
        _ = try withUnsafeMutablePointer(to: &inputBuffer) { inputPointer in
            try run(allowPendingInput: false, outputHandler: outputHandler) { outputBuffer in
                ZSTD_decompressStream(context, outputBuffer, inputPointer)
            }
        }
    }

    private func run(
        allowPendingInput: Bool,
        outputHandler: (Data) throws -> Void,
        decompress: (UnsafeMutablePointer<ZSTD_outBuffer>) -> Int
    ) throws -> Int {
        let capacity = 1 << 20
        let output = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { output.deallocate() }
        var outputBuffer = ZSTD_outBuffer(dst: output, size: capacity, pos: 0)
        var noProgressCalls = 0

        while true {
            outputBuffer.pos = 0
            let code = decompress(&outputBuffer)
            if ZSTD_isError(code) != 0 {
                throw ZstdDecoderError.decompressionFailed(code)
            }
            if outputBuffer.pos > 0 {
                try outputHandler(Data(bytes: output, count: outputBuffer.pos))
            } else {
                noProgressCalls += 1
                if noProgressCalls >= 16 {
                    throw ZstdDecoderError.decompressionFailed(-16)
                }
            }
            if code == 0 {
                frameComplete = true
                return code
            }
            if outputBuffer.pos == 0 {
                if allowPendingInput {
                    // The decoder consumed the chunk and is waiting for more.
                    frameComplete = false
                    return code
                }
            }
            // At EOF, keep draining the decoder even when a call emits no
            // bytes; a final empty call can still complete the frame.
        }
    }
}

/// Splits streamed UTF-8 input into complete lines without materializing the
/// whole stream. Multi-byte characters split across read boundaries remain in
/// the pending byte buffer until the next newline.
struct LineSplitter {
    private var pending = [UInt8]()
    private var skippingOversizedLine = false
    private let maxLineBytes: Int

    /// A practical ceiling for parser input. Normal JSONL records are far
    /// smaller; this prevents one malformed line from becoming an unbounded
    /// allocation even when the source stream is large.
    static let defaultMaxLineBytes = 64 * 1_048_576

    var pendingBytes: Data {
        Data(pending)
    }

    init(initialBytes: Data = Data(), maxLineBytes: Int = LineSplitter.defaultMaxLineBytes) {
        self.maxLineBytes = maxLineBytes
        pending = [UInt8](initialBytes)
        skippingOversizedLine = pending.count > maxLineBytes
    }

    mutating func append(_ chunk: Data, handler: (String) -> Void) {
        let pieces = chunk.split(separator: UInt8(0x0A), omittingEmptySubsequences: false)
        guard let last = pieces.last else { return }

        for piece in pieces.dropLast() {
            if let line = consume(piece, terminated: true), !skippingOversizedLine {
                handler(line)
            }
            skippingOversizedLine = false
        }

        // The final piece is incomplete unless the chunk ended with a newline;
        // a newline produces a trailing empty piece and is emitted immediately.
        _ = consume(last, terminated: false)
    }

    mutating func finish(handler: (String) -> Void) {
        guard !skippingOversizedLine, !pending.isEmpty else { return }
        handler(String(decoding: pending, as: UTF8.self))
        pending.removeAll(keepingCapacity: false)
    }

    private mutating func consume(_ piece: Data, terminated: Bool) -> String? {
        if !skippingOversizedLine {
            if pending.count + piece.count <= maxLineBytes {
                pending.append(contentsOf: piece)
            } else {
                pending.removeAll(keepingCapacity: false)
                skippingOversizedLine = true
            }
        }

        if terminated || piece.isEmpty {
            let line = String(decoding: pending, as: UTF8.self)
            pending.removeAll(keepingCapacity: false)
            if terminated, !skippingOversizedLine {
                return line
            }
        }
        return nil
    }
}

private extension String {
    /// Read a top-level string field from a JSON line.
    func jsonStringField(_ key: String) -> String? {
        guard let data = data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json[key] as? String
    }
}
