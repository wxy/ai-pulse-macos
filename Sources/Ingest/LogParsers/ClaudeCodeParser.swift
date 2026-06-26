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
    /// Each JSONL line is a full message object. We extract usage from assistant messages.
    static func parse(line: String, cwd: String?, sessionId: String?) -> UsageEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Only process assistant messages with usage
        guard let type = json["type"] as? String,
              type == "assistant",
              let usage = json["usage"] as? [String: Any]
        else { return nil }

        let inTokens = (usage["input_tokens"] as? Int) ?? 0
        let outTokens = (usage["output_tokens"] as? Int) ?? 0
        let cacheTokens = (usage["cache_read_input_tokens"] as? Int) ?? 0
        let model = json["model"] as? String

        // Compute dedupe key: session + line index if available, else hash
        let dedupeKey: String
        if let sid = sessionId, let ts = json["timestamp"] as? TimeInterval {
            dedupeKey = "claude-code|\(sid)|\(Int(ts * 1000))"
        } else {
            dedupeKey = "claude-code|\(line.hash)"
        }

        return UsageEvent(
            ts: Int((json["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970) * 1000),
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
}
