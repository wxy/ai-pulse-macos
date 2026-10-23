import Foundation

/// One-time backfill: read the first chunk of every existing Codex/Claude
/// session log and upsert its session metadata, so old sessions get titles
/// without a full re-parse. Guarded by UserDefaults so it runs once.
enum SessionInfoBackfill {
    // v3: re-derives titles with the concise first-line/first-sentence rule.
    private static let doneKey = "session_info_backfill_v3"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let preparation = LocalDataProcessing.shared.begin(.preparing)
        defer { preparation.finish() }
        let home = FileManager.default.realHomeDirectory
        backfillCodex(home: home)
        backfillClaude(home: home)
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    /// Extract session metadata from the first chunk of one session log.
    /// Timestamps come from each line's top-level `timestamp` field so a
    /// snippet without token-count events still yields a valid record.
    /// `fallbackTimestampMs` (typically the file's mtime) bounds the session
    /// when lines lack usable timestamps, instead of the backfill run time.
    static func metadataFromSnippet(
        _ data: Data,
        source: String,
        sessionId: String?,
        repo: String?,
        fallbackTimestampMs: Int? = nil
    ) -> SessionInfoRecord? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Claude's content identity wins over an alias name. The logical
        // filename remains a fallback for older snippets with no sessionId.
        var sid = source == "claude-code" ? nil : sessionId
        var title: String? = nil
        var repoPath = repo
        var completed = false
        var window: Int? = nil
        var minTs = Int.max
        var maxTs = 0
        text.enumerateLines { line, _ in
            if source == "claude-code" {
                if sid == nil || repoPath == nil,
                   let data = line.data(using: .utf8),
                   let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if sid == nil, let value = fields["sessionId"] as? String, !value.isEmpty { sid = value }
                    if repoPath == nil { repoPath = fields["cwd"] as? String }
                }
            } else {
                if sid == nil { sid = CodexParser.sessionId(fromLine: line) }
                if repoPath == nil { repoPath = CodexParser.cwd(fromLine: line) }
            }
            if title == nil {
                if source == "codex", let m = CodexParser.firstUserMessage(fromLine: line) {
                    title = SessionInfoRecord.makeTitle(m)
                } else if source == "claude-code", let m = ClaudeCodeParser.firstUserMessage(fromLine: line) {
                    title = SessionInfoRecord.makeTitle(m)
                }
            }
            if window == nil, let w = CodexParser.windowTokens(fromLine: line) { window = w }
            if CodexParser.isSessionComplete(fromLine: line) { completed = true }
            if let ts = tsMillis(fromLine: line) {
                minTs = min(minTs, ts)
                maxTs = max(maxTs, ts)
            }
            if let e = CodexParser.parse(line: line, cwd: nil, model: nil,
                                         fallbackTimestampMs: fallbackTimestampMs) {
                minTs = min(minTs, e.ts)
                maxTs = max(maxTs, e.ts)
            } else if let e = ClaudeCodeParser.parse(line: line, fallbackTimestampMs: fallbackTimestampMs) {
                minTs = min(minTs, e.ts)
                maxTs = max(maxTs, e.ts)
            }
        }
        guard let session = sid ?? sessionId, maxTs > 0 else { return nil }
        return SessionInfoRecord(
            source: source, sessionId: session, title: title, repo: repoPath,
            firstTs: minTs, lastTs: maxTs, completed: completed ? true : nil,
            windowTokens: source == "codex" ? window : nil)
    }

    private static func backfillCodex(home: URL) {
        let dir = home.appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: dir.path),
              let enumerator = SymlinkFileTree.enumerator(
                  at: dir, includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
                  matchingFiles: { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" })
        else { return }
        for case let url as URL in enumerator {
            guard let data = try? readPrefix(of: url, bytes: 64 * 1024),
                  let record = metadataFromSnippet(
                      data, source: "codex", sessionId: nil, repo: nil,
                      fallbackTimestampMs: LogWatcher.fileModificationMs(url)),
                  let sid = record.sessionId
            else { continue }
            let resolvedTitle = CodexThreadTitles.title(for: sid) ?? record.title
            LogWatcher.upsertForBackfill(SessionInfoRecord(
                source: record.source, sessionId: sid, title: resolvedTitle,
                repo: record.repo, firstTs: record.firstTs, lastTs: record.lastTs,
                completed: record.completed, windowTokens: record.windowTokens))
        }
    }

    static func backfillClaude(home: URL, persist: (SessionInfoRecord) -> Void = LogWatcher.upsertForBackfill) {
        let dir = home.appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: dir.path),
              let enumerator = SymlinkFileTree.enumerator(
                  at: dir, includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
                  matchingFiles: { $0.pathExtension == "jsonl" })
        else { return }
        for case let url as URL in enumerator {
            let sid = enumerator.logicalURL?.deletingPathExtension().lastPathComponent
            guard let data = try? readPrefix(of: url, bytes: 64 * 1024),
                  let record = metadataFromSnippet(
                      data, source: "claude-code", sessionId: sid, repo: nil,
                      fallbackTimestampMs: LogWatcher.fileModificationMs(url))
            else { continue }
            persist(record)
        }
    }

    /// Content fingerprint of a file head: the first bytes cannot change
    /// while size, mtime and inode are unchanged, so prefix readers can skip
    /// the read entirely for steady-state files.
    struct PrefixFingerprint: Equatable {
        let size: UInt64
        let mtime: Date
        let inode: UInt64
    }

    static func prefixFingerprint(of url: URL) -> PrefixFingerprint? {
        guard let values = try? url.resourceValues(
                  forKeys: [.fileSizeKey, .contentModificationDateKey, .fileIdentifierKey]),
              let size = values.fileSize,
              let mtime = values.contentModificationDate,
              let inode = values.fileIdentifier
        else { return nil }
        return PrefixFingerprint(size: UInt64(size), mtime: mtime, inode: UInt64(inode))
    }

    private static let prefixCacheLock = NSLock()
    private static nonisolated(unsafe) var prefixMetadataCache:
        [String: (fingerprint: PrefixFingerprint, value: (sessionId: String?, title: String?, repo: String?)?)] = [:]

    /// Claude session metadata read from the file head (first user message +
    /// session id + cwd), so titles are correct even when a session is scanned
    /// while still being written.
    ///
    /// Cached by (size, mtime, inode): the scan loop calls this for every
    /// jsonl on every 30-second pass, and an unchanged head would otherwise
    /// cost a 4KB read plus per-line JSON re-parsing each tick.
    static func claudePrefixMetadata(from file: URL) -> (sessionId: String?, title: String?, repo: String?)? {
        let fingerprint = prefixFingerprint(of: file)
        prefixCacheLock.lock()
        if let fingerprint, let cached = prefixMetadataCache[file.path], cached.fingerprint == fingerprint {
            prefixCacheLock.unlock()
            return cached.value
        }
        prefixCacheLock.unlock()

        let value: (sessionId: String?, title: String?, repo: String?)?
        if let data = try? readPrefix(of: file, bytes: 4096),
           let record = metadataFromSnippet(data, source: "claude-code", sessionId: nil, repo: nil) {
            value = (record.sessionId, record.title, record.repo)
        } else {
            value = nil
        }

        if let fingerprint {
            prefixCacheLock.lock()
            // Sessions accumulate across project directories; drop the whole
            // table rather than tracking LRU — the next pass repopulates it
            // with one 4KB read per file.
            if prefixMetadataCache.count > 4096 { prefixMetadataCache.removeAll() }
            prefixMetadataCache[file.path] = (fingerprint, value)
            prefixCacheLock.unlock()
        }
        return value
    }

    private static func readPrefix(of url: URL, bytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: bytes) ?? Data()
    }

    private static nonisolated(unsafe) let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static nonisolated(unsafe) let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse a line's top-level `timestamp` (ISO 8601) into epoch milliseconds.
    private static func tsMillis(fromLine line: String) -> Int? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["timestamp"] as? String,
              let date = iso8601WithFraction.date(from: raw) ?? iso8601.date(from: raw)
        else { return nil }
        return Int(date.timeIntervalSince1970 * 1000)
    }
}
