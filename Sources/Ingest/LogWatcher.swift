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
    /// the mutable scan state below (filePositions) and on GitMonitor's
    /// watched-repo set when start() is called from multiple places (launch,
    /// after granting access, after adding a directory) or when an FSEvent fires
    /// while an initial scan is still running.
    private let scanQueue = DispatchQueue(label: "com.wxy.aipulse.logwatcher.scan", qos: .utility,
                                         autoreleaseFrequency: .workItem)
    private var stopped = false // scanQueue only
    private var positionsLoaded = false // retry if DB was not ready at init
    private var suppressConsumptionEvents = false // initial history scan only
    private let liveObservationStartMs = Int64(Date().timeIntervalSince1970 * 1_000)

    /// Last complete-line byte offset per file path, persisted in SQLite.
    private var filePositions: [String: UInt64] = [:]
    /// Only offsets advanced by this process need another durable write.
    private var pendingPositions: [String: UInt64] = [:]
    private var codexMetadata: [String: CodexResumeMetadata] = [:]
    private var openCodeFingerprints: [String: OpenCodeFingerprint] = [:]
    private var scanChanged = false
    private var scanFreshTokens: Int64 = 0
    private var scanSource: String?

    private struct OpenCodeFingerprint: Equatable {
        let size: UInt64
        let modifiedAt: Date
        let fileNumber: UInt64?
    }
    /// Last seen model per aider file (survives incremental scans).
    private var aiderModels: [String: String] = [:]
    /// VS Code chat journals are patches over prior request state. Retain the
    /// reconstructed metadata while the app is running so appended patches can
    /// be interpreted without replaying the whole session on every scan.
    private var copilotStates: [String: CopilotChatParser.State] = [:]

    /// FSEvents can fire many times while one cold-history scan is running.
    /// Coalesce those notifications into a single follow-up scan; a serial
    /// queue alone would otherwise preserve a backlog of duplicate full scans.
    private var scanQueued = false

    /// Visible while a cold database is still importing history. The app can
    /// already show balances and cached snapshots, but usage panels must not be
    /// mistaken for an empty account while backfill is running.
    static let backfill = IngestionBackfillState()

    private init() {
        scanQueue.async { self.loadPositionsFromDB() }
    }

    private func loadPositionsFromDB() {
        dispatchPrecondition(condition: .onQueue(scanQueue))
        do {
            filePositions = try AppDatabase.shared.readSynchronously { try LogCheckpointStore.load(in: $0) }
            positionsLoaded = true
            AppHealthMonitor.shared.clearIngestError(source: "log.offsets.load")
        } catch {
            Logger.warning("LogWatcher: DB positions load failed, re-scanning all files: \(error)")
            AppHealthMonitor.shared.reportIngestError(error.localizedDescription, source: "log.offsets.load")
        }
    }

    func start() {
        scanQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            if !self.positionsLoaded { self.loadPositionsFromDB() }
        let isColdStart = self.filePositions.values.allSatisfy { $0 == 0 }
        self.suppressConsumptionEvents = true
        defer { self.suppressConsumptionEvents = false }
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
            guard let self, !self.stopped, !self.scanQueued else { return }
            self.scanQueued = true
            self.scanQueue.async { [weak self] in
                guard let self else { return }
                defer { self.scanQueued = false }
                guard !self.stopped else { return }
                self.runScan(includeClaudeProjects: true)
            }
        }
    }

    /// Completes one incremental scan before returning. Used for explicit
    /// user refreshes that must publish a snapshot of the newly collected data.
    func scanAndWait() async {
        await withCheckedContinuation { continuation in
            scanQueue.async { [weak self] in
                guard let self, !self.stopped else {
                    continuation.resume()
                    return
                }
                if !self.positionsLoaded { self.loadPositionsFromDB() }
                self.runScan(includeClaudeProjects: true)
                continuation.resume()
            }
        }
    }

    /// Wait for scans already queued at the call site, including scan()'s
    /// second queue hop and the initial startup import. Does not rescan.
    func waitForPendingScan() async {
        await withCheckedContinuation { continuation in
            scanQueue.async {
                self.scanQueue.async { continuation.resume() }
            }
        }
    }

    private func runScan(includeClaudeProjects: Bool) {
        dispatchPrecondition(condition: .onQueue(scanQueue))
        scanChanged = false
        scanFreshTokens = 0
        scanSource = nil
        LogScanObservation.shared.begin()
        defer { LogScanObservation.shared.finish() }
        if includeClaudeProjects {
                self.scanClaudeProjectsOnly()
        }
        discoverAndWatchRepos()
        scanCodexSessions()
        scanCopilotChatSessions()
        scanDeepSeekHarnessSessions()
        scanQwenSessions()
        scanOpenCodeSessions()
        persistPendingPositions()
        if scanChanged {
            let event: ConsumptionEvent? = scanFreshTokens > 0 && !suppressConsumptionEvents
                ? ConsumptionEvent(spendUSD: nil, tokens: Int(clamping: scanFreshTokens),
                                   source: scanSource ?? "log")
                : nil
            DataRefreshCoordinator.shared.notifyPhaseIngest(event)
        }
    }

    func stop() {
        // Never block the main thread waiting for ingest or queued UI work.
        scanQueue.async {
            self.stopped = true
            LogScanObservation.shared.stop()
            self.claudeSource?.cancel()
            self.claudeSource = nil
            self.codexSource?.cancel()
            self.codexSource = nil
            self.persistPendingPositions()
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

    /// Watch `~/.codex/sessions` with FSEvents for Codex rollout activity;
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

    // MARK: - GitHub Copilot Chat / Agent in VS Code

    private struct CopilotSessionFile {
        let url: URL
        let repoPath: String?
        let modified: Date
    }

    /// Scan VS Code's native chat journals. These contain full conversations,
    /// but CopilotChatParser decodes only IDs, timestamps, models and usage.
    private func scanCopilotChatSessions() {
        let home = FileManager.default.realHomeDirectory
        let applicationSupport = home.appendingPathComponent("Library/Application Support")
        let userRoots = ["Code", "Code - Insiders"].map {
            applicationSupport.appendingPathComponent($0).appendingPathComponent("User")
        }
        var files: [CopilotSessionFile] = []

        for userRoot in userRoots {
            let workspaceStorage = userRoot.appendingPathComponent("workspaceStorage")
            if let workspaces = try? FileManager.default.contentsOfDirectory(
                at: workspaceStorage,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for workspace in workspaces {
                    let repoPath = Self.vsCodeWorkspacePath(
                        from: workspace.appendingPathComponent("workspace.json"))
                    appendCopilotSessionFiles(
                        in: workspace.appendingPathComponent("chatSessions"),
                        repoPath: repoPath,
                        to: &files)
                }
            }
            appendCopilotSessionFiles(
                in: userRoot.appendingPathComponent("globalStorage/emptyWindowChatSessions"),
                repoPath: nil,
                to: &files)
        }

        for file in files.sorted(by: { $0.modified > $1.modified }) {
            parseCopilotSessionFile(file.url, repoPath: file.repoPath)
        }
    }

    private func appendCopilotSessionFiles(
        in directory: URL,
        repoPath: String?,
        to files: inout [CopilotSessionFile]
    ) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        // Legacy .json files are pretty-printed conversation snapshots and do
        // not contain the server usage counters. Current usage journals are
        // append-only .jsonl files.
        for url in urls where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            files.append(CopilotSessionFile(
                url: url,
                repoPath: repoPath,
                modified: values?.contentModificationDate ?? .distantPast))
        }
    }

    /// Resolve only the file URI from workspace metadata. No workspace content
    /// is opened, and repository normalization still happens in insertEvents.
    static func vsCodeWorkspacePath(from metadataFile: URL) -> String? {
        guard let data = try? Data(contentsOf: metadataFile),
              let metadata = try? JSONDecoder().decode(VSCodeWorkspaceMetadata.self, from: data),
              let raw = metadata.folder,
              let url = URL(string: raw), url.isFileURL
        else { return nil }
        return url.standardizedFileURL.path
    }

    private struct VSCodeWorkspaceMetadata: Decodable {
        let folder: String?
    }

    private func parseCopilotSessionFile(_ file: URL, repoPath: String?) {
        let path = file.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64
        else { return }

        let lastPosition = filePositions[path] ?? 0
        let startPosition = lastPosition <= fileSize ? lastPosition : 0
        guard startPosition < fileSize else { return }

        var state = startPosition == 0
            ? CopilotChatParser.State(repoPath: repoPath)
            : copilotStates[path] ?? CopilotChatParser.State(repoPath: repoPath)

        do {
            // After relaunch, rebuild the small metadata state up to the durable
            // checkpoint. Parsed text is discarded and no usage is persisted.
            if startPosition > 0, copilotStates[path] == nil {
                let rebuilt = try JSONLCheckpoint.read(
                    at: file, from: 0, fileSize: startPosition,
                    parse: { line -> Int? in
                        _ = state.consume(line: line)
                        return nil
                    },
                    persist: { (_: [Int]) in })
                guard rebuilt == startPosition else { throw JSONLCheckpoint.Failure.shortRead }
            }

            var minTs = Int.max
            var maxTs = 0
            var parsedCount = 0
            let checkpoint = try JSONLCheckpoint.read(
                at: file, from: startPosition, fileSize: fileSize,
                parse: { line -> [UsageEvent]? in
                    let events = state.consume(line: line)
                    guard !events.isEmpty else { return nil }
                    for event in events {
                        minTs = min(minTs, event.ts)
                        maxTs = max(maxTs, event.ts)
                    }
                    parsedCount += events.count
                    return events
                },
                persist: { batches in
                    guard self.insertEvents(batches.flatMap { $0 }) else {
                        throw JSONLCheckpoint.Failure.persistenceFailed
                    }
                })
            copilotStates[path] = state
            filePositions[path] = checkpoint
            pendingPositions[path] = checkpoint
            Self.recordFileScanResult(path: path, error: nil)

            if let sessionId = state.sessionId, maxTs > 0 {
                upsertSessionInfo(SessionInfoRecord(
                    source: "copilot", sessionId: sessionId, title: nil, repo: repoPath,
                    firstTs: minTs, lastTs: maxTs, completed: nil, windowTokens: nil))
            }
            if parsedCount > 0 {
                Logger.info("LogWatcher: parsed \(parsedCount) Copilot usage updates from \(path)")
            }
        } catch {
            Logger.warning("LogWatcher: Copilot scan failed for \(path): \(error.localizedDescription)")
            Self.recordFileScanResult(path: path, error: error)
        }
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
        where url.lastPathComponent.hasPrefix("session")
            && url.lastPathComponent.hasSuffix(".jsonl.zstd") {
            // Matches session.jsonl.zstd (journal v1/v2) AND session.v3.jsonl.zstd
            // (v3, 2026-09) — prefix+suffix so future generations keep flowing.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, modified))
        }
        for item in files.sorted(by: { $0.modified > $1.modified }) {
            parseDeepSeekHarnessFile(item.url)
        }
    }

    /// DSH replay cooldown gate: a corrupt or truncated journal cannot be
    /// advanced (no byte boundary in a compressed stream), so without a
    /// cooldown it would be fully decompressed — potentially hundreds of MB —
    /// and reported on every 30-second scan, forever. Retry when the file
    /// changes (size/mtime) or the cooldown lapses.
    private struct DshFailureGate {
        let size: UInt64
        let mtime: Date?
        let failedAt: Date
    }
    private let dshFailureLock = NSLock()
    private var dshFailures: [String: DshFailureGate] = [:]
    private static let dshRetryCooldown: TimeInterval = 300

    private func parseDeepSeekHarnessFile(_ file: URL) {
        let path = file.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64
        else { return }
        let mtime = attrs[.modificationDate] as? Date

        // A zstd journal cannot be safely read at a byte boundary. Re-parse on
        // size changes and rely on usage_event dedupe keys to keep idempotence.
        if filePositions[path] == fileSize { return }

        dshFailureLock.lock()
        let gate = dshFailures[path]
        dshFailureLock.unlock()
        if let gate, gate.size == fileSize, gate.mtime == mtime,
           Date().timeIntervalSince(gate.failedAt) < Self.dshRetryCooldown {
            return
        }

        let result: DeepSeekHarnessScanResult
        do {
            result = try Self.parseDeepSeekHarnessStream(at: file) { events in
                guard self.insertEvents(events) else { throw JSONLCheckpoint.Failure.persistenceFailed }
            }
        } catch {
            Logger.warning("LogWatcher: DSH scan failed for \(path): \(error.localizedDescription)")
            Self.recordFileScanResult(path: path, error: error)
            dshFailureLock.lock()
            if dshFailures.count > 4096 { dshFailures.removeAll() }
            dshFailures[path] = DshFailureGate(size: fileSize, mtime: mtime, failedAt: Date())
            dshFailureLock.unlock()
            return
        }

        dshFailureLock.lock()
        dshFailures.removeValue(forKey: path)
        dshFailureLock.unlock()
        Self.recordFileScanResult(path: path, error: nil)
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
        pendingPositions[path] = fileSize
    }

    struct DeepSeekHarnessScanResult {
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
    static func parseDeepSeekHarnessStream(
        at url: URL, persist: ([UsageEvent]) throws -> Void
    ) throws -> DeepSeekHarnessScanResult {
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
        var persistenceError: Error?

        func processLine(_ line: String) {
            guard persistenceError == nil else { return }
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
                do { try persist(result.events) } catch { persistenceError = error }
                result.events.removeAll(keepingCapacity: false)
            }
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        while true {
            let hasInput = try autoreleasepool {
                guard let compressedChunk = try handle.read(upToCount: 256 << 10), !compressedChunk.isEmpty else {
                    return false
                }
                try decoder.decompress(compressedChunk) { chunk in
                    splitter.append(chunk, handler: processLine)
                    if let persistenceError { throw persistenceError }
                }
                return true
            }
            if !hasInput { break }
        }
        try decoder.finish { chunk in
            splitter.append(chunk, handler: processLine)
        }
        splitter.finish(handler: processLine)
        if let persistenceError { throw persistenceError }
        if !result.events.isEmpty { try persist(result.events) }
        result.events.removeAll(keepingCapacity: false)
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
        let lastPos = filePositions[filePath] ?? 0
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: filePath))?[.size] as? UInt64 ?? 0
        let resume = lastPos != fileSize && lastPos <= fileSize
            ? codexMetadata[filePath] ?? codexResumeMetadata(at: file)
            : nil
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
        if filePositions[filePath] != lastPos {
            codexMetadata[filePath] = CodexResumeMetadata(
                cwd: currentCwd, sessionId: currentSessionId, model: currentModel)
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

    struct CodexResumeMetadata {
        let cwd: String?
        let sessionId: String?
        let model: String?
    }

    /// Incremental reads begin at the stored byte offset, so parser state from
    /// earlier lines no longer exists. Rebuild only the small metadata needed to
    /// attribute the new events; token_count parsing still stays incremental.
    private func codexResumeMetadata(at file: URL) -> CodexResumeMetadata? {
        guard let lastPos = filePositions[file.path] else { return nil }
        return Self.codexResumeMetadata(at: file, lastPosition: lastPos)
    }

    static func codexResumeMetadata(at file: URL, lastPosition lastPos: UInt64) -> CodexResumeMetadata? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let fileSize = attrs[.size] as? UInt64,
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
        // Only the jsonl files inside a `chats` directory. Matching the
        // directory itself (hasPrefix) fed it through the parser, where the
        // FileHandle read failed and logged an error on every single scan.
        where url.pathExtension == "jsonl"
            && url.deletingLastPathComponent().lastPathComponent.hasPrefix("chats") {
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
        let fingerprint: OpenCodeFingerprint? = {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = attributes[.size] as? UInt64,
                  let modifiedAt = attributes[.modificationDate] as? Date else { return nil }
            let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            return OpenCodeFingerprint(size: size, modifiedAt: modifiedAt, fileNumber: fileNumber)
        }()
        if let fingerprint, openCodeFingerprints[file.path] == fingerprint { return }
        guard let event = OpenCodeParser.parseFile(file, cwd: nil) else {
            // Valid JSON that simply carries no usage (user-side messages,
            // meta entries) is a stable verdict: remember the fingerprint so
            // every future scan doesn't re-read and re-parse the file.
            if let fingerprint {
                openCodeFingerprints[file.path] = fingerprint
            }
            return
        }
        let saved = insertEvents([event])
        if saved, let fingerprint { openCodeFingerprints[file.path] = fingerprint }
        Self.recordFileScanResult(path: file.path,
                                  error: saved ? nil : JSONLCheckpoint.Failure.persistenceFailed)
        Logger.debug("LogWatcher: parsed opencode event from \(file.path)")
    }

    // MARK: - aider

    private func discoverAndWatchRepos() {
        let dirs = RepositoryScope.configuredRoots()
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
                    // The fallback timestamp is the file's mtime — constant
                    // for the whole pass, so stat once instead of per line.
                    let fileTS = Int(((try? chatMD.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?
                        .timeIntervalSince1970 ?? 0) * 1000)
                    parseLinesIncremental(from: chatMD) { line in
                        // Track model across lines & scans
                        if let m = AiderParser.parseModelLine(line) { aiderModels[filePath] = m; return nil }
                        let model = aiderModels[filePath]
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

        do {
            let checkpoint = try JSONLCheckpoint.read(at: url, from: startPos, fileSize: fileSize,
                parse: parser, persist: { events in
                    guard insertEvents(events) else { throw JSONLCheckpoint.Failure.persistenceFailed }
                })
            filePositions[path] = checkpoint
            pendingPositions[path] = checkpoint
            Self.recordFileScanResult(path: path, error: nil)
        } catch {
            Logger.error("LogWatcher: file scan did not advance checkpoint: \(error)")
            Self.recordFileScanResult(path: path, error: error)
        }
    }

    private func persistPendingPositions() {
        dispatchPrecondition(condition: .onQueue(scanQueue))
        guard !pendingPositions.isEmpty else { return }
        do {
            let positions = pendingPositions
            try AppDatabase.shared.writeSynchronously { try LogCheckpointStore.save(positions, in: $0) }
            pendingPositions.removeAll(keepingCapacity: true)
            AppHealthMonitor.shared.clearIngestError(source: "log.offsets")
        } catch {
            Logger.error("LogWatcher: persist positions failed: \(error)")
            AppHealthMonitor.shared.reportIngestError(error.localizedDescription, source: "log.offsets")
        }
    }

    private func enumerateGitRepos(in dir: URL, handler: (URL) -> Void) {
        GitRepoScanner.enumerate(in: dir, handler)
    }

    /// A retry may contain different batches after the log grows. Track the
    /// stable file identity, clearing only after its whole scan succeeds.
    static func recordFileScanResult(path: String, error: Error?, monitor: AppHealthMonitor = .shared) {
        let source = "Log.file.\(path)"
        if let error {
            monitor.reportIngestError(error.localizedDescription, source: source)
        } else {
            monitor.clearIngestError(source: source)
        }
    }

    /// Batch all events read from one file into a single SQLite transaction.
    /// A historical JSONL can contain thousands of rows; spawning one Task per
    /// row makes first launch fight itself for the database queue and UI.
    @discardableResult
    private func insertEvents(_ events: [UsageEvent]) -> Bool {
        dispatchPrecondition(condition: .onQueue(scanQueue))
        guard !events.isEmpty else { return true }
        let roots = RepositoryScope.configuredRoots()
        var normalizedRepos: [String: String?] = [:]
        let rows = events.map { rawEvent -> (event: UsageEvent, providerId: String) in
            let normalizedRepo: String? = rawEvent.repoPath.flatMap { path in
                if let cached = normalizedRepos[path] { return cached }
                let resolved = RepositoryScope.authorizedGitRoot(for: path, roots: roots)
                normalizedRepos[path] = .some(resolved)
                return resolved
            }
            let event = UsageEvent(
                ts: rawEvent.ts, source: rawEvent.source, model: rawEvent.model,
                inTokens: rawEvent.inTokens, outTokens: rawEvent.outTokens,
                cacheTokens: rawEvent.cacheTokens, repoPath: normalizedRepo,
                sessionId: rawEvent.sessionId, dedupeKey: rawEvent.dedupeKey,
                cacheCreationTokens: rawEvent.cacheCreationTokens,
                reportedOutputTokens: rawEvent.reportedOutputTokens,
                reasoningTokens: rawEvent.reasoningTokens)
            let providerId = ModelCatalogManager.shared.providerId(for: event.model) ?? "unknown"
            return (event, providerId)
        }

            do {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
                let batchTokens = try AppDatabase.shared.writeSynchronously { db in
                    try Self.persistObservedEvents(in: db, rows: rows, nowMs: nowMs,
                                                   liveSinceMs: liveObservationStartMs)
                }
                let event: ConsumptionEvent? = batchTokens > 0 && !suppressConsumptionEvents
                    ? ConsumptionEvent(spendUSD: nil, tokens: Int(clamping: batchTokens),
                                       source: rows.first?.event.source ?? "log")
                    : nil
                scanChanged = true
                if let event, let tokens = event.tokens {
                    scanFreshTokens += min(Int64(tokens), Int64.max - scanFreshTokens)
                    if scanSource == nil { scanSource = event.source }
                }
                return true
            } catch {
                Logger.error("Failed to insert usage_event: \(error)")
                return false
            }
    }

    /// Logs contain activity facts, not bills. Existing legacy amounts remain
    /// untouched; new rows have no derived amount. Replays are not new spending.
    static func persistObservedEvents(in db: Database, rows: [(event: UsageEvent, providerId: String)],
                                      nowMs: Int64, liveSinceMs: Int64? = nil) throws -> Int64 {
        var freshTokens: Int64 = 0
        for row in rows {
            let event = row.event
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM usage_event WHERE dedupe_key = ?)",
                                          arguments: [event.dedupeKey]) ?? false
            try db.execute(sql: """
                INSERT INTO usage_event
                  (ts, source, provider_id, model, in_tokens, out_tokens, cache_tokens, cache_creation_tokens,
                   reported_output_tokens, reasoning_tokens,
                   repo_path, session_id, dedupe_key)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(dedupe_key) DO UPDATE SET
                  ts = CASE WHEN excluded.source = 'copilot' THEN excluded.ts ELSE usage_event.ts END,
                  provider_id = excluded.provider_id, model = excluded.model,
                  in_tokens = CASE WHEN excluded.source = 'copilot' THEN excluded.in_tokens ELSE usage_event.in_tokens END,
                  out_tokens = CASE WHEN excluded.source = 'copilot' THEN excluded.out_tokens ELSE usage_event.out_tokens END,
                  cache_tokens = CASE WHEN excluded.source = 'copilot' THEN excluded.cache_tokens ELSE usage_event.cache_tokens END,
                  repo_path = excluded.repo_path,
                  cache_creation_tokens = CASE WHEN excluded.source = 'copilot'
                    THEN excluded.cache_creation_tokens
                    ELSE COALESCE(excluded.cache_creation_tokens, usage_event.cache_creation_tokens) END,
                  reported_output_tokens = CASE WHEN excluded.source = 'copilot'
                    THEN excluded.reported_output_tokens
                    ELSE COALESCE(excluded.reported_output_tokens, usage_event.reported_output_tokens) END,
                  reasoning_tokens = CASE WHEN excluded.source = 'copilot'
                    THEN excluded.reasoning_tokens
                    ELSE COALESCE(excluded.reasoning_tokens, usage_event.reasoning_tokens) END
                """, arguments: [event.ts, event.source, row.providerId, event.model,
                    event.inTokens, event.outTokens, event.cacheTokens, event.cacheCreationTokens,
                    event.reportedOutputTokens, event.reasoningTokens, event.repoPath,
                    event.sessionId, event.dedupeKey])
            if !exists, event.model != "<synthetic>", event.ts <= nowMs,
               event.ts >= max(nowMs - 300_000, liveSinceMs ?? Int64.min) {
                freshTokens += Int64(TokenAccounting.observedTotal(event: event))
            }
        }
        return freshTokens
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
    /// Cache for `discoverAndWatchRepo`: path → (fingerprint, resolved repo).
    /// Repo discovery re-reads the file head and walks git roots on every
    /// scan for every Claude jsonl; the answer cannot change while the file
    /// head is unchanged. Nil repoPath caches the "no repo" verdict too.
    private let repoDiscoveryLock = NSLock()
    private var repoDiscoveryCache: [String: (fingerprint: SessionInfoBackfill.PrefixFingerprint, repoPath: String?)] = [:]

    private func discoverAndWatchRepo(from file: URL) {
        let fingerprint = SessionInfoBackfill.prefixFingerprint(of: file)
        repoDiscoveryLock.lock()
        if let fingerprint, let cached = repoDiscoveryCache[file.path], cached.fingerprint == fingerprint {
            repoDiscoveryLock.unlock()
            if let repoPath = cached.repoPath {
                GitMonitor.shared.watch(repoPath: repoPath)
            }
            return
        }
        repoDiscoveryLock.unlock()

        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096),
              let text = String(data: data, encoding: .utf8),
              let firstLine = text.components(separatedBy: .newlines).first,
              !firstLine.isEmpty,
              let jsonData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let cwd = json["cwd"] as? String
        else { return }
        let repoUrl = findGitRepo(containing: cwd)
        if let fingerprint {
            repoDiscoveryLock.lock()
            if repoDiscoveryCache.count > 4096 { repoDiscoveryCache.removeAll() }
            repoDiscoveryCache[file.path] = (fingerprint, repoUrl?.path)
            repoDiscoveryLock.unlock()
        }
        guard let repoUrl else { return }
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
            autoreleasepool {
                if let line = consume(piece, terminated: true), !skippingOversizedLine {
                    handler(line)
                }
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
