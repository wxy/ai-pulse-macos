import Foundation

/// Parses OpenCode CLI usage (`~/.local/share/opencode/storage/message/<sid>/msg_*.json`).
///
/// OpenCode stores one JSON file per message under `storage/message/`, plus a
/// `storage/session/<projectHash>/<sid>.json` for session metadata. The message
/// payload carries `tokens.input / tokens.output / tokens.cache.read` and a
/// `model`. Only assistant messages with token usage produce events.
struct OpenCodeParser {
    /// Parse one OpenCode message JSON dictionary into a UsageEvent.
    static func parse(json: [String: Any], cwd: String?) -> UsageEvent? {
        let role = json["role"] as? String
        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let input = (tokens["input"] as? NSNumber)?.intValue ?? 0
        let output = (tokens["output"] as? NSNumber)?.intValue ?? 0
        let cache = ((tokens["cache"] as? [String: Any])?["read"] as? NSNumber)?.intValue ?? 0

        // Only assistant messages with actual usage produce an event.
        guard (role == "assistant" || role == nil), input + output > 0 else { return nil }

        let model = json["model"] as? String
        let id = json["id"] as? String ?? ""

        let ts: Int
        if let t = json["created_at"] as? NSNumber {
            ts = t.intValue * 1000  // OpenCode timestamps are seconds
        } else if let t = json["timestamp"] as? NSNumber {
            ts = t.intValue * 1000
        } else {
            ts = Int(Date().timeIntervalSince1970 * 1000)
        }

        let dedupeKey: String = id.isEmpty
            ? "opencode|\(stableHash("\(ts)-\(model ?? "")-\(input)-\(output)"))"
            : "opencode|\(id)"
        return UsageEvent(
            ts: ts,
            source: "opencode",
            model: model,
            inTokens: input,
            outTokens: output,
            cacheTokens: cache,
            repoPath: cwd,
            sessionId: id.isEmpty ? nil : id,
            dedupeKey: dedupeKey
        )
    }

    /// Parse a message JSON file (decodes then delegates to `parse(json:cwd:)`).
    static func parseFile(_ file: URL, cwd: String?) -> UsageEvent? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(json: json, cwd: cwd)
    }
}
