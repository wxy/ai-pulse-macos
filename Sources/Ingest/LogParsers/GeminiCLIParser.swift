import Foundation

/// Parses Gemini CLI session logs (`~/.gemini/tmp/<projectHash>/chats/*.jsonl`).
///
/// Format verified against upstream `google-gemini/gemini-cli`
/// (`packages/core/src/services/chatRecordingService.ts` + `chatRecordingTypes.ts`):
///
/// - Files are JSONL under the project temp dir, one `session-*.jsonl` per
///   session; subagent sessions nest one level deeper as
///   `chats/<parentSessionId>/<sessionId>.jsonl` (no `session-` prefix).
/// - The first line is metadata `{sessionId, projectHash, startTime,
///   lastUpdated, kind?, directories?}` — no `type` field.
/// - Message records follow: `{id, timestamp, type: "user"|"info"|"error"|
///   "warning"|"gemini", content, …}`; only `"gemini"` messages carry
///   `tokens?: {input, output, cached, thoughts?, tool?, total}` and `model?`.
///   Token semantics match the Qwen Code fork exactly, so parsing delegates
///   to `QwenCodeParser` under this integration's own source label.
/// - Timestamps are ISO-8601 UTC strings from `Date.toISOString()`.
///
/// The record's `projectHash` is an opaque SHA-256 of the project root, so
/// `repoPath` stays nil (token facts without repository attribution), the
/// same trade the Qwen scanner already makes.
struct GeminiCLIParser {
    static let source = "gemini-cli"

    static func parse(line: String, cwd: String?, fallbackTimestampMs: Int? = nil) -> UsageEvent? {
        QwenCodeParser.parse(
            line: line, cwd: cwd, fallbackTimestampMs: fallbackTimestampMs,
            source: source, dedupePrefix: source)
    }

    /// Session files live in a `chats` directory, either directly (main
    /// sessions) or one level below it (subagent sessions named after the
    /// parent id). Checking the directory chain — not the `session-` prefix —
    /// keeps subagent files included.
    static func isSessionFile(_ url: URL) -> Bool {
        guard url.pathExtension == "jsonl" else { return false }
        let parent = url.deletingLastPathComponent().lastPathComponent
        let grandparent = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return parent == "chats" || grandparent == "chats"
    }
}
