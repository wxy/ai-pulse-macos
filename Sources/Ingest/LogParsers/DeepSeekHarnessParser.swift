import Foundation

/// Parses DeepSeek Harness session journals under `~/.dsh/sessions`.
///
/// DSH stores journals as one JSON object per line, then compresses the file
/// with zstd. Usage is emitted per model step in `assistant/chunk` events.
struct DeepSeekHarnessParser {
    struct SessionMetadata {
        let sessionId: String?
        let cwd: String?
        let title: String?
        let model: String?
    }

    static func metadata(fromLine line: String) -> SessionMetadata? {
        guard let json = Self.json(line) else { return nil }

        switch json["type"] as? String {
        case "session":
            return SessionMetadata(
                sessionId: json["id"] as? String,
                cwd: json["cwd"] as? String,
                title: nil,
                model: nil)
        case "session/title":
            let data = json["data"] as? [String: Any] ?? [:]
            return SessionMetadata(
                sessionId: nil, cwd: nil,
                title: data["title"] as? String,
                model: nil)
        case "request/header":
            let data = json["data"] as? [String: Any] ?? [:]
            let header = data["header"] as? [String: Any] ?? [:]
            let config = header["config"] as? [String: Any] ?? [:]
            return SessionMetadata(
                sessionId: nil, cwd: nil, title: nil,
                model: config["model"] as? String)
        case "request/context":
            let data = json["data"] as? [String: Any] ?? [:]
            return SessionMetadata(
                sessionId: nil, cwd: nil, title: nil,
                model: data["model"] as? String)
        case "assistant/message":
            let data = json["data"] as? [String: Any] ?? [:]
            let message = data["message"] as? [String: Any] ?? [:]
            let source = message["source"] as? [String: Any] ?? [:]
            return SessionMetadata(
                sessionId: nil, cwd: nil, title: nil,
                model: source["model"] as? String)
        default:
            return nil
        }
    }

    static func isComplete(fromLine line: String) -> Bool {
        guard let json = Self.json(line),
              json["type"] as? String == "turn/end",
              let data = json["data"] as? [String: Any],
              let reason = data["reason"] as? [String: Any]
        else { return false }
        return reason["kind"] as? String == "completed"
    }

    static func parse(line: String, cwd: String?, model: String?, sessionId: String?) -> UsageEvent? {
        guard let json = Self.json(line),
              json["type"] as? String == "assistant/chunk",
              let data = json["data"] as? [String: Any],
              let chunk = data["chunk"] as? [String: Any],
              chunk["type"] as? String == "usage",
              let usage = chunk["usage"] as? [String: Any]
        else { return nil }

        let inTokens = usage["inputTokens"] as? Int ?? 0
        let outTokens = usage["outputTokens"] as? Int ?? 0
        let cacheTokens = usage["cacheReadTokens"] as? Int ?? 0
        let reasoningTokens = usage["reasoningTokens"] as? Int ?? 0

        return UsageEvent(
            ts: json["time"] as? Int ?? Int(Date().timeIntervalSince1970 * 1000),
            source: "deepseek-harness",
            model: model,
            inTokens: inTokens,
            outTokens: outTokens + reasoningTokens,
            cacheTokens: cacheTokens,
            repoPath: cwd,
            sessionId: sessionId,
            dedupeKey: "deepseek-harness|\(stableHash(line))")
    }

    private static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}
