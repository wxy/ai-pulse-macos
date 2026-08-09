import Foundation

/// One-time backfill: read the first chunk of every existing Codex/Claude
/// session log and upsert its session metadata, so old sessions get titles
/// without a full re-parse. Guarded by UserDefaults so it runs once.
enum SessionInfoBackfill {
    private static let doneKey = "session_info_backfill_v1"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let home = FileManager.default.realHomeDirectory
        backfillCodex(home: home)
        backfillClaude(home: home)
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    /// Extract session metadata from the first chunk of one session log.
    /// Timestamps come from each line's top-level `timestamp` field so a
    /// snippet without token-count events still yields a valid record.
    static func metadataFromSnippet(
        _ data: Data,
        source: String,
        sessionId: String?,
        repo: String?
    ) -> SessionInfoRecord? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var sid = sessionId
        var title: String? = nil
        var repoPath = repo
        var completed = false
        var window: Int? = nil
        var minTs = Int.max
        var maxTs = 0
        text.enumerateLines { line, _ in
            if sid == nil, let s = CodexParser.sessionId(fromLine: line) { sid = s }
            if repoPath == nil, let c = CodexParser.cwd(fromLine: line) { repoPath = c }
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
            if let e = CodexParser.parse(line: line, cwd: nil, model: nil) {
                minTs = min(minTs, e.ts)
                maxTs = max(maxTs, e.ts)
            } else if let e = ClaudeCodeParser.parse(line: line) {
                minTs = min(minTs, e.ts)
                maxTs = max(maxTs, e.ts)
            }
        }
        guard let session = sid, maxTs > 0 else { return nil }
        return SessionInfoRecord(
            source: source, sessionId: session, title: title, repo: repoPath,
            firstTs: minTs, lastTs: maxTs, completed: completed ? true : nil,
            windowTokens: source == "codex" ? window : nil)
    }

    private static func backfillCodex(home: URL) {
        let dir = home.appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: dir.path),
              let enumerator = FileManager.default.enumerator(
                  at: dir, includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            guard let data = try? readPrefix(of: url, bytes: 64 * 1024),
                  let record = metadataFromSnippet(data, source: "codex", sessionId: nil, repo: nil)
            else { continue }
            LogWatcher.upsertForBackfill(record)
        }
    }

    private static func backfillClaude(home: URL) {
        let dir = home.appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: dir.path),
              let enumerator = FileManager.default.enumerator(
                  at: dir, includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let sid = url.deletingPathExtension().lastPathComponent
            guard let data = try? readPrefix(of: url, bytes: 64 * 1024),
                  let record = metadataFromSnippet(data, source: "claude-code", sessionId: sid, repo: nil)
            else { continue }
            LogWatcher.upsertForBackfill(record)
        }
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
