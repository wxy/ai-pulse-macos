import XCTest
import GRDB
@testable import AIPulse

/// The settings source-health card aggregates per-source collection facts.
/// These tests pin the SQL semantics: last observation spans all history,
/// window counters are scoped, and incomplete components are counted per the
/// shared TokenAccounting rule instead of guessed.
final class SourceHealthTests: XCTestCase {
    private func insertEvent(_ db: Database, ts: Int64, source: String,
                             cacheCreation: Int64? = nil, reportedOutput: Int64? = nil,
                             key: String) throws {
        try db.execute(sql: """
            INSERT INTO usage_event (ts, source, model, in_tokens, out_tokens, cache_tokens,
                                     cache_creation_tokens, reported_output_tokens, repo_path, dedupe_key)
            VALUES (?, ?, 'm', 10, 5, 0, ?, ?, NULL, ?)
            """, arguments: [ts, source, cacheCreation, reportedOutput, key])
    }

    func testFactsAggregatePerSourceWithWindowScope() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            let window = Int64(1_000)

            // claude-code: one recent complete + one old event.
            try insertEvent(db, ts: window + 100, source: "claude-code", cacheCreation: 0, reportedOutput: 5, key: "a")
            try insertEvent(db, ts: window - 500_000, source: "claude-code", cacheCreation: 0, reportedOutput: 5, key: "b")
            // qwen-code: recent event missing nothing (source not in the
            // incomplete rules) and an unknown source entirely outside order.
            try insertEvent(db, ts: window + 200, source: "qwen-code", cacheCreation: nil, reportedOutput: nil, key: "c")
            try insertEvent(db, ts: window + 300, source: "mystery", cacheCreation: nil, reportedOutput: nil, key: "d")

            let facts = try SourceHealth.facts(in: db, windowStartMs: window)
            let bySource = Dictionary(uniqueKeysWithValues: facts.map { ($0.source, $0) })

            let claude = bySource["claude-code"]
            XCTAssertEqual(claude?.lastEventMs, window + 100, "last observation spans all history")
            XCTAssertEqual(claude?.events7d, 1, "window counters ignore out-of-window rows")
            XCTAssertEqual(claude?.incomplete7d, 0)

            let qwen = bySource["qwen-code"]
            XCTAssertEqual(qwen?.events7d, 1)
            XCTAssertEqual(qwen?.incomplete7d, 0, "sources without component rules are never 'incomplete'")

            XCTAssertEqual(bySource["mystery"]?.events7d, 1)
            XCTAssertNil(bySource["aider"], "sources without rows produce no fact — absence is the blind-spot signal")
        }
    }

    func testOrderedRowsPutKnownSourcesFirstThenExtrasThenUnobserved() {
        let claude = SourceHealthFact(source: "claude-code", lastEventMs: 10, events7d: 1, incomplete7d: 0)
        let zeta = SourceHealthFact(source: "zeta-tool", lastEventMs: 20, events7d: 1, incomplete7d: 0)
        let rows = SourceHealth.orderedRows(facts: [zeta, claude])
        let sources = rows.map(\.source)
        XCTAssertEqual(sources.first, "claude-code", "known display order wins")
        XCTAssertTrue(sources.contains("gemini-cli"), "known sources with no observation still appear as blind spots")
        XCTAssertEqual(sources.last, "zeta-tool", "unknown sources stay visible after the known list")
        XCTAssertEqual(sources.contains("zeta-tool"), true, "unknown sources stay visible after the known list")
        let unobserved = rows.first { $0.source == "opencode" }
        XCTAssertNil(unobserved?.fact, "known-but-unobserved sources carry a nil fact for 'no observation'")
    }
}
