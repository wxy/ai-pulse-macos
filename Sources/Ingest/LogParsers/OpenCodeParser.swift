import Foundation

/// Parses OpenCode CLI usage (`~/.local/share/opencode/storage/message/<sid>/msg_*.json`).
///
/// OpenCode stores one JSON file per message under `storage/message/`, plus a
/// `storage/session/<projectHash>/<sid>.json` for session metadata. The message
/// payload carries `tokens.input / tokens.output / tokens.cache.read` and a
/// `model`. Only assistant messages with token usage produce events.
struct OpenCodeParser {
    /// Parse one OpenCode message JSON dictionary into a UsageEvent.
    /// `fallbackTimestampMs` (typically the message file's mtime) is used when
    /// the payload carries neither `created_at` nor `timestamp`. For the rare
    /// id-less message the dedupe key includes the timestamp, so a stable
    /// mtime fallback also keeps rescans from minting a fresh key each pass.
    static func parse(json: [String: Any], cwd: String?, fallbackTimestampMs: Int? = nil) -> UsageEvent? {
        let role = json["role"] as? String
        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let input = (tokens["input"] as? NSNumber)?.intValue ?? 0
        let output = (tokens["output"] as? NSNumber)?.intValue ?? 0
        let cache = ((tokens["cache"] as? [String: Any])?["read"] as? NSNumber)?.intValue ?? 0
        let cacheWrite = ((tokens["cache"] as? [String: Any])?["write"] as? NSNumber)?.intValue
        let reasoning = (tokens["reasoning"] as? NSNumber)?.intValue

        // Only assistant messages with actual usage produce an event.
        guard (role == "assistant" || role == nil),
              [input, output, cache, cacheWrite ?? 0, reasoning ?? 0].contains(where: { $0 > 0 }) else { return nil }

        let model = json["model"] as? String
        let id = json["id"] as? String ?? ""

        let parsedTs: Int? = (json["created_at"] as? NSNumber).map { $0.intValue * 1000 }
            ?? (json["timestamp"] as? NSNumber).map { $0.intValue * 1000 }
        let ts = EventTimestamp.resolve(
            parsed: parsedTs, fileModifiedMs: fallbackTimestampMs, source: "opencode")

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
            dedupeKey: dedupeKey,
            cacheCreationTokens: cacheWrite,
            reportedOutputTokens: output,
            reasoningTokens: reasoning
        )
    }

    /// Parse a message JSON file (decodes then delegates to `parse(json:cwd:)`),
    /// offering the file's mtime as the fallback timestamp.
    static func parseFile(_ file: URL, cwd: String?) -> UsageEvent? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let mtimeMs = Int(((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
        return parse(json: json, cwd: cwd, fallbackTimestampMs: mtimeMs)
    }
}
