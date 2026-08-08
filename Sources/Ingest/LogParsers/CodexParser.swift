import Foundation

/// Parses Codex / ChatGPT session logs (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
///
/// The same directory is written by both the Codex CLI and the ChatGPT
/// desktop app (formerly Codex). Two event shapes exist:
///
/// - Legacy CLI: `{ "type": "token_count", "payload": { "last_token_usage": … } }`
/// - Desktop app: `{ "type": "event_msg", "payload": { "type": "token_count",
///   "info": { "last_token_usage": … } } }`
///
/// Both carry per-turn deltas (`last_token_usage`) with `input_tokens` /
/// `cached_input_tokens` / `output_tokens` / `reasoning_output_tokens`.
/// `cwd`, `model` and `session_id` are not on every line — the caller threads
/// them through from `session_meta` / `turn_context` lines.
struct CodexParser {
    private static nonisolated(unsafe) let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parse one rollout JSONL line into a UsageEvent (only `token_count` lines
    /// produce an event). `cwd` / `model` / `sessionId` are threaded in from
    /// surrounding lines.
    static func parse(line: String, cwd: String?, model: String?, sessionId: String? = nil) -> UsageEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let type = json["type"] as? String
        let payload = json["payload"] as? [String: Any] ?? [:]

        // Only token_count events carry token usage. The desktop app wraps the
        // event in `event_msg` and nests usage under `info`.
        let usage: [String: Any]?
        if type == "token_count" {
            usage = payload["last_token_usage"] as? [String: Any]
        } else if type == "event_msg",
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any] {
            usage = info["last_token_usage"] as? [String: Any]
        } else {
            usage = nil
        }
        guard let usage else { return nil }

        let inTokens = usage["input_tokens"] as? Int ?? 0
        let cacheTokens = usage["cached_input_tokens"] as? Int ?? 0
        let outTokens = usage["output_tokens"] as? Int ?? 0
        let reasoningTokens = usage["reasoning_output_tokens"] as? Int ?? 0

        // Reasoning tokens are billed as output.
        let totalOut = outTokens + reasoningTokens

        let ts: Int
        if let tsStr = json["timestamp"] as? String, let date = iso8601.date(from: tsStr) {
            ts = Int(date.timeIntervalSince1970 * 1000)
        } else {
            ts = Int(Date().timeIntervalSince1970 * 1000)
        }

        return UsageEvent(
            ts: ts,
            source: "codex",
            model: model,
            inTokens: inTokens,
            outTokens: totalOut,
            cacheTokens: cacheTokens,
            repoPath: cwd,
            sessionId: (payload["session_id"] as? String) ?? sessionId,
            dedupeKey: "codex|\(stableHash(line))"
        )
    }

    /// Extract `cwd` from a `session_meta` line (first line of a rollout).
    static func cwd(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "session_meta",
              let payload = json["payload"] as? [String: Any]
        else { return nil }
        return payload["cwd"] as? String
    }

    /// Extract `session_id` from a `session_meta` line (first line of a rollout).
    static func sessionId(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "session_meta",
              let payload = json["payload"] as? [String: Any]
        else { return nil }
        return payload["session_id"] as? String
    }

    /// Extract `model` from a `turn_context` line (per-turn model snapshot).
    static func model(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "turn_context",
              let payload = json["payload"] as? [String: Any]
        else { return nil }
        return payload["model"] as? String
    }
}
