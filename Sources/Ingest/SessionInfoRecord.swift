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

    /// A concise session title derived from the first user message: first
    /// line, whitespace-collapsed, cut at the first sentence end or
    /// `maxLength` characters — closer to how chat apps auto-title sessions.
    static func makeTitle(_ text: String?, maxLength: Int = 40) -> String? {
        guard let text else { return nil }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = firstLine
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        let cut = sentenceCut(in: collapsed, maxLength: maxLength)
        return String(collapsed.prefix(cut))
    }

    private static func sentenceCut(in text: String, maxLength: Int) -> Int {
        if let idx = text.firstIndex(where: { "。！？.!?".contains($0) }) {
            let dist = text.distance(from: text.startIndex, to: idx) + 1
            if dist <= maxLength { return dist }
        }
        return maxLength
    }
}
