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
        _ = json["cost"] as? Double

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

    /// Extract model name from aider markdown line.
    /// Format: `Model: deepseek/deepseek-chat with diff edit format, prompt cache, infinite output`
    static func parseModelLine(_ line: String) -> String? {
        guard line.hasPrefix("Model: ") else { return nil }
        // Extract model id: "deepseek/deepseek-chat"
        guard let match = try? NSRegularExpression(
            pattern: #"^Model:\s*([^\s]+)"#,
            options: []
        ).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (line as NSString).substring(with: match.range(at: 1))
    }

    /// Parse Markdown format from `.aider.chat.history.md`
    /// Token format: `> Tokens: 12k sent, 47 received. Cost: $0.0034 message, $0.0034 session.`
    /// - Parameter fallbackDate: used as the event timestamp when the Markdown
    ///   line contains no timestamp of its own (unlike JSONL, Markdown has no
    ///   per-line time). Typically the file's modification date.
    static func parseMarkdown(line: String, cwd: String?, model: String?,
                              fallbackDate: Int? = nil) -> UsageEvent? {
        // Only parse token usage lines (they contain cost data)
        guard line.hasPrefix("> Tokens:") || line.hasPrefix("> Tokens: ") else { return nil }

        // Extract numbers using regex: e.g. "12k sent, 47 received"
        guard let match = try? NSRegularExpression(
            pattern: #"([\d.]+k?)\s*sent\w*\s*,\s*([\d.]+k?)\s*received"#,
            options: .caseInsensitive
        ).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }

        let inStr = (line as NSString).substring(with: match.range(at: 1))
        let outStr = (line as NSString).substring(with: match.range(at: 2))

        func parseK(_ s: String) -> Int {
            if s.hasSuffix("k") {
                let num = Double(s.dropLast()) ?? 0
                return Int(num * 1000)
            }
            return Int(s) ?? 0
        }

        let inTokens = parseK(inStr)
        let outTokens = parseK(outStr)

        return UsageEvent(
            ts: fallbackDate ?? Int(Date().timeIntervalSince1970 * 1000),
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
