import XCTest
import GRDB
import AIPulseShared
@testable import AIPulse

final class ObservationBoundsTests: XCTestCase {
    func testIncludesCurrentMillisecondButNotNextOrPeriodEnd() {
        let now = Date(timeIntervalSince1970: 100.1234)
        XCTAssertEqual(ObservationBounds.upperExclusive(now: now, periodEnd: now.addingTimeInterval(10)), 100124)
        XCTAssertEqual(ObservationBounds.upperExclusive(now: now, periodEnd: Date(timeIntervalSince1970: 99)), 99000)
    }

    func testCalendarSlotsRemainFullAcrossDSTWhileObservationsStopAtNow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        for kind in [DashboardPeriodKind.today, .week, .days30] {
            let period = DashboardPeriod(kind: kind, now: now, calendar: cal)
            XCTAssertGreaterThan(period.end, now)
            XCTAssertEqual(ObservationBounds.upperExclusive(now: now, periodEnd: period.end),
                           Int64(now.timeIntervalSince1970 * 1_000) + 1)
        }
        let dayStart = cal.startOfDay(for: now)
        XCTAssertEqual(cal.date(byAdding: .day, value: 1, to: dayStart)!.timeIntervalSince(dayStart), 23 * 3600)
    }

    func testRepositoryAndModelQueriesBothExcludeFutureFacts() throws {
        let queue = try DatabaseQueue()
        let now = Date(timeIntervalSince1970: 100)
        let upper = ObservationBounds.upperExclusive(now: now, periodEnd: now.addingTimeInterval(3600))
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            for ts in [99999, 100000, 100001, 101000] {
                let event = UsageEvent(ts: ts, source: "aider", model: "m", inTokens: 10,
                                       outTokens: 2, cacheTokens: 0, repoPath: "/dev/repo",
                                       sessionId: nil, dedupeKey: "future-\(ts)")
                _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "deepseek")], nowMs: 100000)
            }
            let models = try StatsService.modelActivity(in: db, sinceMs: 99000, beforeMs: upper)
            let repos = try StatsService.repositoryTokenActivity(in: db, sinceMs: 99000, beforeMs: upper)
            XCTAssertEqual(models.reduce(0) { $0 + $1.tokens }, 24)
            XCTAssertEqual(models.reduce(0) { $0 + $1.calls }, 2)
            XCTAssertEqual(repos.reduce(0) { $0 + $1.tokens }, 24)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event"), 4,
                           "Future raw facts are retained, not deleted or rewritten")
        }
    }
}
