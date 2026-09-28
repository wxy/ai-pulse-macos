import Foundation

/// Parses Qwen Code CLI session logs (`~/.qwen/projects/<project>/chats/*.jsonl`).
///
/// Qwen Code is a fork of the Gemini CLI, so the on-disk format matches Gemini:
/// message records are `{id, timestamp, type: "user"|"gemini", model, content,
/// tokens: {input, output, cached, thoughts, tool, total}}`. Only model
/// (gemini) messages carry token usage.
struct QwenCodeParser {
    private static nonisolated(unsafe) let iso8601Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static nonisolated(unsafe) let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse one chat JSONL line into a UsageEvent (only model/gemini messages
    /// with a `tokens` object produce an event). `cwd` is threaded in from the
    /// session header or the project directory. `fallbackTimestampMs`
    /// (typically the file's mtime) is used when the line's timestamp is
    /// missing or unparseable. The Gemini CLI writes the same record shape
    /// (see `GeminiCLIParser`), so it reuses this parser under its own
    /// `source` label and dedupe prefix; the qwen defaults keep existing
    /// dedupe keys stable across the refactor.
    static func parse(line: String, cwd: String?, fallbackTimestampMs: Int? = nil,
                      source: String = "qwen-code", dedupePrefix: String = "qwen",
                      headerSessionId: String? = nil) -> UsageEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Only gemini (model) messages carry tokens.
        let type = json["type"] as? String
        guard type == "gemini", let tokens = json["tokens"] as? [String: Any]
        else { return nil }

        let model = json["model"] as? String
        let sessionId = (json["sessionId"] as? String) ?? headerSessionId

        // Gemini-style token object: input includes cached; cached/tool/thoughts are sub-slices.
        let input = (tokens["input"] as? NSNumber)?.intValue ?? 0
        let cached = (tokens["cached"] as? NSNumber)?.intValue ?? 0
        let thoughts = (tokens["thoughts"] as? NSNumber)?.intValue ?? 0
        let tool = (tokens["tool"] as? NSNumber)?.intValue ?? 0
        // output may already include thoughts/tool — use total minus input to be safe.
        let total = (tokens["total"] as? NSNumber)?.intValue ?? 0
        let out = max(total - input, thoughts + tool)

        let parsedTs: Int? = (json["timestamp"] as? String)
            .flatMap { iso8601Frac.date(from: $0) ?? iso8601.date(from: $0) }
            .map { Int($0.timeIntervalSince1970 * 1000) }
        let ts = EventTimestamp.resolve(
            parsed: parsedTs, fileModifiedMs: fallbackTimestampMs, source: source)

        return UsageEvent(
            ts: ts,
            source: source,
            model: model,
            inTokens: input,
            outTokens: out,
            cacheTokens: cached,
            repoPath: cwd,
            sessionId: sessionId,
            dedupeKey: "\(dedupePrefix)|\(stableHash(line))"
        )
    }

    /// Extract `cwd` from the session header line (contains `sessionId`,
    /// `projectHash`, `kind`) — but the header has no cwd field. The caller
    /// passes the project directory as cwd instead.
    static func isSessionHeader(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["kind"] != nil || (json["sessionId"] != nil && json["projectHash"] != nil)
    }
}
