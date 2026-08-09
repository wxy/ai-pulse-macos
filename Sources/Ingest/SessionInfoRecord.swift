import Foundation

/// One row of `session_info`: session-level metadata captured while parsing logs.
struct SessionInfoRecord {
    let source: String
    let sessionId: String?
    let title: String?
    let repo: String?
    let firstTs: Int
    let lastTs: Int
    let completed: Bool?
    let windowTokens: Int?

    /// First user message, whitespace-collapsed and truncated to `maxLength` characters.
    static func makeTitle(_ text: String?, maxLength: Int = 60) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxLength))
    }
}
