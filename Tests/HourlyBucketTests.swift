import XCTest
import GRDB
import AIPulseShared
@testable import AIPulse

/// The Today rhythm must be real per-hour activity buckets: each event lands
/// in the local hour it actually occurred in (the closed 2026-09-17 debt in
/// data-facts-and-surfaces.md — the old "session start hour" approximation is
/// gone), with synthetic rows excluded and unknown never becoming zero.
final class HourlyBucketTests: XCTestCase {
    /// Fixed calendar so local-hour buckets and day bounds are deterministic.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func ms(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Int64 {
        let date = cal.date(from: DateComponents(year: year, month: month, day: day,
                                                 hour: hour, minute: minute))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func insertEvent(_ db: Database, ts: Int64, inTokens: Int, outTokens: Int,
                             model: String? = "qwen3-coder", key: String) throws {
        try db.execute(sql: """
            INSERT INTO usage_event (ts, source, model, in_tokens, out_tokens, cache_tokens, repo_path, dedupe_key)
            VALUES (?, 'qwen-code', ?, ?, ?, 0, NULL, ?)
            """, arguments: [ts, model, inTokens, outTokens, key])
    }

    func testEventsLandInTheirActualLocalHour() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            // Two events in the 09:00 local hour, one in the 23:00 hour.
            try insertEvent(db, ts: ms(year: 2026, month: 9, day: 27, hour: 9, minute: 15),
                            inTokens: 100, outTokens: 50, key: "a")
            try insertEvent(db, ts: ms(year: 2026, month: 9, day: 27, hour: 9, minute: 45),
                            inTokens: 10, outTokens: 5, key: "b")
            try insertEvent(db, ts: ms(year: 2026, month: 9, day: 27, hour: 23, minute: 59),
                            inTokens: 7, outTokens: 0, key: "c")

            let startMs = ms(year: 2026, month: 9, day: 27, hour: 0)
            let endMs = ms(year: 2026, month: 9, day: 28, hour: 0)
            let buckets = try StatsService.hourlyUsageStats(in: db, startMs: startMs, endMs: endMs,
                                                            now: Date(), calendar: cal)
            XCTAssertEqual(buckets.count, 2, "one bucket per hour with observed events, no invented hours")
            XCTAssertEqual(buckets[0].date, Date(timeIntervalSince1970: Double(ms(year: 2026, month: 9, day: 27, hour: 9)) / 1000))
            XCTAssertEqual(buckets[0].calls, 2)
            XCTAssertEqual(buckets[0].tokens, 165)
            XCTAssertEqual(buckets[1].date, Date(timeIntervalSince1970: Double(ms(year: 2026, month: 9, day: 27, hour: 23)) / 1000))
            XCTAssertEqual(buckets[1].tokens, 7)
        }
    }

    func testHalfOpenBoundsExcludeOutsideDayAndSyntheticRows() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            // Yesterday evening: before the window.
            try insertEvent(db, ts: ms(year: 2026, month: 9, day: 26, hour: 23, minute: 59),
                            inTokens: 500, outTokens: 0, key: "prev")
            // Exactly at the exclusive upper bound: outside the window.
            try insertEvent(db, ts: ms(year: 2026, month: 9, day: 28, hour: 0),
                            inTokens: 500, outTokens: 0, key: "next")
            // Synthetic capacity rows never count as consumption.
            try db.execute(sql: """
                INSERT INTO usage_event (ts, source, model, in_tokens, out_tokens, cache_tokens, repo_path, dedupe_key)
                VALUES (?, 'qwen-code', '<synthetic>', 900, 0, 0, NULL, 'synthetic')
                """, arguments: [ms(year: 2026, month: 9, day: 27, hour: 12)])

            let startMs = ms(year: 2026, month: 9, day: 27, hour: 0)
            let endMs = ms(year: 2026, month: 9, day: 28, hour: 0)
            let buckets = try StatsService.hourlyUsageStats(in: db, startMs: startMs, endMs: endMs,
                                                            now: Date(), calendar: cal)
            XCTAssertTrue(buckets.isEmpty, "outside-window and synthetic rows must not invent activity")
        }
    }

    func testNegativeComponentsClampToZeroButStillCountAsCalls() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            try insertEvent(db, ts: ms(year: 2026, month: 9, day: 27, hour: 8, minute: 1),
                            inTokens: -5, outTokens: -2, key: "neg")
            let startMs = ms(year: 2026, month: 9, day: 27, hour: 0)
            let endMs = ms(year: 2026, month: 9, day: 28, hour: 0)
            let buckets = try StatsService.hourlyUsageStats(in: db, startMs: startMs, endMs: endMs,
                                                            now: Date(), calendar: cal)
            XCTAssertEqual(buckets.count, 1)
            XCTAssertEqual(buckets[0].calls, 1, "the observation happened; only its clamped total is zero")
            XCTAssertEqual(buckets[0].tokens, 0)
        }
    }

    func testCoverageNoteLogicMirrorsSnapshotStates() {
        // Complete coverage: no note (the only "complete" signal).
        var snapshot = DashboardSnapshot()
        snapshot.activityCoverage = ActivityCoverage(observedEvents: 100, incompleteEvents: 0)
        XCTAssertFalse(snapshot.activityCoverage.isPartial == true)

        // Partial coverage with a usable count.
        snapshot.activityCoverage = ActivityCoverage(observedEvents: 100, incompleteEvents: 3)
        XCTAssertEqual(snapshot.activityCoverage.isPartial, true)

        // Failed coverage query: counters stay nil → unknown, never zero.
        snapshot.activityCoverage = ActivityCoverage()
        XCTAssertNil(snapshot.activityCoverage.isPartial)
        XCTAssertNil(snapshot.activityCoverage.incompleteEvents)
    }
}
