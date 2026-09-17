import XCTest
import GRDB
@testable import AIPulse

final class ObservedLogIngestTests: XCTestCase {
    func testOnlyNewRecentActivityGeneratesConsumptionAndNoCatalogAmountIsStored() throws {
        let queue = try DatabaseQueue()
        let now: Int64 = 1_000_000
        func row(_ key: String, ts: Int) -> (event: UsageEvent, providerId: String) {
            (UsageEvent(ts: ts, source: "codex", model: "gpt-5", inTokens: 100, outTokens: 10,
                cacheTokens: 20, repoPath: nil, sessionId: "s", dedupeKey: key, reportedOutputTokens: 10), "openai")
        }
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            let rows = [row("fresh", ts: Int(now)), row("history", ts: 1), row("future", ts: Int(now + 1))]
            XCTAssertEqual(try LogWatcher.persistObservedEvents(in: db, rows: rows, nowMs: now), 110)
            XCTAssertEqual(try LogWatcher.persistObservedEvents(in: db, rows: rows, nowMs: now), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event WHERE cost_usd IS NOT NULL"), 0)
            try db.execute(sql: "UPDATE usage_event SET cost_usd = 42 WHERE dedupe_key = 'fresh'")
            XCTAssertEqual(try LogWatcher.persistObservedEvents(in: db, rows: rows, nowMs: now), 0)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT cost_usd FROM usage_event WHERE dedupe_key = 'fresh'"), 42)
        }
    }
}
