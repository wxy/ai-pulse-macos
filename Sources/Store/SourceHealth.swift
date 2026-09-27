import Foundation
import GRDB

/// Per-source collection facts for the settings health card: when a source
/// last produced an observed event, how many events it contributed inside the
/// report window, and how many of those are missing token components.
/// A missing row means "no observation on record" — that is neither zero
/// usage nor a fault, and the UI must say so.
struct SourceHealthFact: Equatable {
    let source: String
    let lastEventMs: Int64?
    let events7d: Int64
    let incomplete7d: Int64
}

enum SourceHealth {
    /// Display order for the known log sources; anything else found in the
    /// database is appended after these so new adapters stay visible.
    static let knownSourceOrder = [
        "claude-code", "codex", "deepseek-harness", "aider",
        "opencode", "qwen-code", "gemini-cli", "copilot",
    ]

    /// One grouped pass over `usage_event`. `lastEventMs` spans all history
    /// (a source whose logs stopped years ago still shows its real last
    /// observation); the event and incompleteness counters are scoped to the
    /// window starting at `windowStartMs` (inclusive).
    static func facts(in db: Database, windowStartMs: Int64) throws -> [SourceHealthFact] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT source,
                   MAX(ts) AS last_ts,
                   COALESCE(SUM(CASE WHEN ts >= ? THEN 1 ELSE 0 END), 0) AS events7d,
                   COALESCE(SUM(CASE WHEN ts >= ? AND \(TokenAccounting.missingComponentsSQL) THEN 1 ELSE 0 END), 0) AS incomplete7d
            FROM usage_event
            GROUP BY source
            """, arguments: [windowStartMs, windowStartMs])
        return rows.map { row in
            SourceHealthFact(
                source: row["source"] as String? ?? "unknown",
                lastEventMs: row["last_ts"] as Int64?,
                events7d: row["events7d"] as Int64? ?? 0,
                incomplete7d: row["incomplete7d"] as Int64? ?? 0)
        }
    }

    /// Known sources first (in display order), then any additional sources
    /// present in the database, then known sources without any observation.
    static func orderedRows(facts: [SourceHealthFact]) -> [(source: String, fact: SourceHealthFact?)] {
        let bySource = Dictionary(facts.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = knownSourceOrder.map { ($0, bySource[$0]) }
        let known = Set(knownSourceOrder)
        let extras = facts
            .filter { !known.contains($0.source) }
            .sorted { $0.source < $1.source }
            .map { ($0.source, Optional($0)) }
        rows.append(contentsOf: extras)
        return rows
    }
}
