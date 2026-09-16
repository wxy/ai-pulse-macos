import XCTest
import GRDB
@testable import AIPulse

final class HourlyBaselineTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
        }
        return dbQueue
    }

    private func insertEvent(_ db: Database, ts: Int64, cost: Double?, tokens: Int,
                             model: String? = "glm-5.3-flash", dedupe: String) throws {
        try db.execute(sql: """
            INSERT INTO usage_event
              (ts, source, provider_id, model, in_tokens, out_tokens, cache_tokens,
               cost_usd, dedupe_key, cost_source_id, cost_confidence)
            VALUES (?, 'claude-code', 'deepseek', ?, ?, 0, 0, ?, ?, 'unattributed', 'estimated')
            """, arguments: [ts, model, tokens, cost, dedupe])
    }

    private static let hour: Int64 = 3_600_000

    func testFetchHourlyGroupsByEpochHourAndOrdersNewestFirst() throws {
        let dbQueue = try makeDB()
        let h1: Int64 = 1_000
        try dbQueue.write { db in
            try insertEvent(db, ts: h1 * Self.hour + 1_000, cost: 2.0, tokens: 100, dedupe: "a")
            try insertEvent(db, ts: h1 * Self.hour + 2_000, cost: 1.0, tokens: 50, dedupe: "b")
            try insertEvent(db, ts: (h1 + 2) * Self.hour, cost: 4.0, tokens: 200, dedupe: "c")
        }

        let rows = try dbQueue.read { db in
            try HourlyBaseline.fetchHourly(in: db, sinceMs: 0)
        }

        XCTAssertEqual(rows.count, 2, "two distinct hours (empty hour H+1 must not appear)")
        XCTAssertEqual(rows[0].hour, h1 + 2, "newest hour first")
        XCTAssertEqual(rows[0].cost, 4.0, accuracy: 1e-9)
        XCTAssertEqual(rows[1].hour, h1)
        XCTAssertEqual(rows[1].cost, 3.0, accuracy: 1e-9, "same-hour rows summed")
        XCTAssertEqual(rows[1].tokens, 150)
    }

    func testFetchHourlyExcludesSyntheticRows() throws {
        let dbQueue = try makeDB()
        let h: Int64 = 2_000
        try dbQueue.write { db in
            try insertEvent(db, ts: h * Self.hour, cost: 1.0, tokens: 10, dedupe: "real")
            try insertEvent(db, ts: h * Self.hour + 1, cost: 99.0, tokens: 10,
                            model: "<synthetic>", dedupe: "synthetic")
        }

        let rows = try dbQueue.read { db in
            try HourlyBaseline.fetchHourly(in: db, sinceMs: 0)
        }

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].cost, 1.0, accuracy: 1e-9, "subscription-amortization rows never burn")
    }

    func testBaselineExcludingLatestMatchesOriginalFormula() {
        // Newest-first ordering is the contract (fetchHourly returns hr DESC):
        // [5,4,3,2,1] → drop latest (5) → mean([4,3,2,1]) = 2.5, the original
        // AnomalyDetector formula kept as the single source of truth.
        let hours = (0..<5).map {
            HourlyBaseline.HourlySpend(hour: Int64(100 - $0), cost: 5 - Double($0), tokens: 0)
        }
        XCTAssertEqual(HourlyBaseline.baselineExcludingLatest(hours), 2.5, accuracy: 1e-9)
    }

    func testBaselineNeedsAtLeastTwoSamples() {
        XCTAssertEqual(HourlyBaseline.baselineExcludingLatest([]), 0)
        XCTAssertEqual(HourlyBaseline.baselineExcludingLatest(
            [HourlyBaseline.HourlySpend(hour: 1, cost: 9, tokens: 0)]), 0)
    }
}
