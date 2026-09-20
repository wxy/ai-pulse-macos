import XCTest
import AIPulseShared
@testable import AIPulse

final class DashboardOpenRefreshTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testMissingSnapshotRefreshesWhenDashboardOpens() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(DashboardView.shouldRefreshOnOpen(
            lastUpdated: nil,
            loadedPeriod: nil,
            range: .today,
            now: now,
            calendar: calendar
        ))
    }

    func testPreviousDaySnapshotRefreshesEvenWhenRecentlyUpdated() {
        let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 0, minute: 1))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertTrue(DashboardView.shouldRefreshOnOpen(
            lastUpdated: now.addingTimeInterval(-10),
            loadedPeriod: DashboardPeriod(kind: .today, now: yesterday, calendar: calendar),
            range: .today,
            now: now,
            calendar: calendar
        ))
    }

    func testStaleSameDaySnapshotRefreshes() {
        let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 12))!
        XCTAssertTrue(DashboardView.shouldRefreshOnOpen(
            lastUpdated: now.addingTimeInterval(-TimeRange.today.cacheMaxAge),
            loadedPeriod: DashboardPeriod(kind: .today, now: now, calendar: calendar),
            range: .today,
            now: now,
            calendar: calendar
        ))
    }

    func testFreshSamePeriodSnapshotDoesNotRefresh() {
        let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 12))!
        XCTAssertFalse(DashboardView.shouldRefreshOnOpen(
            lastUpdated: now.addingTimeInterval(-60),
            loadedPeriod: DashboardPeriod(kind: .today, now: now, calendar: calendar),
            range: .today,
            now: now,
            calendar: calendar
        ))
    }
}
