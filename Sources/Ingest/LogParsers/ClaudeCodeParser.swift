import Foundation

/// Raw event parsed from a Claude Code session JSONL line
struct UsageEvent: Codable {
    let ts: Int          // epoch milliseconds
    let source: String   // "claude-code"
    let model: String?
    let inTokens: Int
    let outTokens: Int
    let cacheTokens: Int
    let repoPath: String?
    let sessionId: String?
    let dedupeKey: String
}

/// Parses Claude Code session logs (~/.claude/projects/<encoded-cwd>/*.jsonl)
struct ClaudeCodeParser {
    /// Parse a Claude Code JSONL line. The `cwd` is read from the JSON's "cwd" field,
    /// NOT from the directory name (which uses ambiguous dash-encoding).
    static func parse(line: String) -> UsageEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // cwd is at top level: "cwd":"/Users/..."
        let cwd = json["cwd"] as? String

        // sessionId at top level
        let sessionId = json["sessionId"] as? String

        // Claude Code wraps the actual message in `message`
        let msg = (json["message"] as? [String: Any]) ?? json
        let usage = (msg["usage"] as? [String: Any]) ?? json["usage"] as? [String: Any]

        // Only process assistant messages with usage
        guard (msg["role"] as? String) == "assistant",
              usage != nil
        else { return nil }

        let inTokens = (usage?["input_tokens"] as? Int) ?? 0
        let outTokens = (usage?["output_tokens"] as? Int) ?? 0
        let cacheTokens = (usage?["cache_read_input_tokens"] as? Int) ?? 0
        let model = msg["model"] as? String

        // Dedupe: sessionId + message UUID
        let dedupeKey: String
        let messageId = (msg["id"] as? String) ?? json["uuid"] as? String
        if let sid = sessionId, let mid = messageId {
            dedupeKey = "claude-code|\(sid)|\(mid)"
        } else {
            dedupeKey = "claude-code|\(line.hash)"
        }

        return UsageEvent(
            ts: Int((parseTimestamp(json["timestamp"]) ?? Date().timeIntervalSince1970) * 1000),
            source: "claude-code",
            model: model,
            inTokens: inTokens,
            outTokens: outTokens,
            cacheTokens: cacheTokens,
            repoPath: cwd,
            sessionId: sessionId,
            dedupeKey: dedupeKey
        )
    }

    /// Parse ISO 8601 timestamp string (e.g. "2026-06-18T09:29:32.485Z") or numeric epoch
    private static func parseTimestamp(_ value: Any?) -> TimeInterval? {
        if let num = value as? TimeInterval { return num }
        if let str = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) { return date.timeIntervalSince1970 }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: str) { return date.timeIntervalSince1970 }
        }
        return nil
    }
}
