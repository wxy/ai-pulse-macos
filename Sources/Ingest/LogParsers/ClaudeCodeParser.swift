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
    /// Each JSONL line is a full message object. Claude Code nests the assistant
    /// message under `message`, with `message.type == "assistant"` and `message.usage`.
    static func parse(line: String, cwd: String?, sessionId: String?) -> UsageEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Claude Code wraps the actual message in `message`
        let msg = (json["message"] as? [String: Any]) ?? json
        let usage = (msg["usage"] as? [String: Any]) ?? json["usage"] as? [String: Any]

        // Only process assistant messages with usage. Claude Code uses `role: "assistant"`.
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
        } else if let sid = sessionId, let ts = json["timestamp"] as? String {
            dedupeKey = "claude-code|\(sid)|\(ts)"
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
