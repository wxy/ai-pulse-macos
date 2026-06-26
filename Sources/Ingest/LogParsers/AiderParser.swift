import Foundation

/// Parses aider's LLM usage history. Aider stores token/cost data in two formats:
/// 1. `.aider.llm.history` — JSON Lines with model, tokens, cost (preferred)
/// 2. `.aider.chat.history.md` — Markdown with inline token stats (fallback)
struct AiderParser {

    /// Parse JSONL format from `.aider.llm.history`
    /// Format: {"model":"gpt-4o","input_tokens":1234,"output_tokens":567,"cost":0.0123,"timestamp":"2026-06-26T10:00:00"}
    static func parseJSONL(line: String, cwd: String?) -> UsageEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let model = json["model"] as? String
        let inTokens = json["input_tokens"] as? Int ?? 0
        let outTokens = json["output_tokens"] as? Int ?? 0
        // Aider tracks its own cost in the JSON
        let cost = json["cost"] as? Double

        let ts: Int
        if let tsStr = json["timestamp"] as? String {
            ts = parseISO8601(tsStr) ?? Int(Date().timeIntervalSince1970 * 1000)
        } else {
            ts = Int(Date().timeIntervalSince1970 * 1000)
        }

        // Dedupe by timestamp (one entry per LLM call)
        let dedupeKey: String
        if let t = json["timestamp"] as? String {
            dedupeKey = "aider|\(t)|\(model ?? "unknown")"
        } else {
            dedupeKey = "aider|\(line.hash)"
        }

        // Aider files live in the repo root, cwd is the repo path
        // OR we can use the file's parent directory as cwd
        return UsageEvent(
            ts: ts,
            source: "aider",
            model: model,
            inTokens: inTokens,
            outTokens: outTokens,
            cacheTokens: 0, // aider doesn't track cache tokens
            repoPath: cwd,
            sessionId: nil,
            dedupeKey: dedupeKey
        )
    }

    /// Parse Markdown format from `.aider.chat.history.md`
    /// Token format: `#### tokens: 1,234 input, 567 output`
    static func parseMarkdown(line: String, cwd: String?, previousModel: String?) -> UsageEvent? {
        // Look for token usage line
        guard line.contains("#### tokens:"),
              let tokensMatch = try? NSRegularExpression(
                pattern: #"tokens:\s*([\d,]+)\s*input\w*\s*,\s*([\d,]+)\s*output"#,
                options: .caseInsensitive
              ).firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }

        let inStr = (line as NSString).substring(with: tokensMatch.range(at: 1))
            .replacingOccurrences(of: ",", with: "")
        let outStr = (line as NSString).substring(with: tokensMatch.range(at: 2))
            .replacingOccurrences(of: ",", with: "")

        guard let inTokens = Int(inStr), let outTokens = Int(outStr) else { return nil }

        // Model is usually on the previous line: `#### model: gpt-4o`
        let model = previousModel

        return UsageEvent(
            ts: Int(Date().timeIntervalSince1970 * 1000),
            source: "aider",
            model: model,
            inTokens: inTokens,
            outTokens: outTokens,
            cacheTokens: 0,
            repoPath: cwd,
            sessionId: nil,
            dedupeKey: "aider|md|\(line.hash)"
        )
    }

    private static func parseISO8601(_ str: String) -> Int? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fmt.date(from: str) { return Int(date.timeIntervalSince1970 * 1000) }
        fmt.formatOptions = [.withInternetDateTime]
        if let date = fmt.date(from: str) { return Int(date.timeIntervalSince1970 * 1000) }
        return nil
    }
}
