import XCTest
import AIPulseShared

final class DashboardPeriodTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    func testMondayWeekRemainsDailyWithSevenSlots() {
        let cal = calendar()
        let monday = cal.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12))!
        let week = DashboardPeriod(kind: .week, now: monday, calendar: cal)
        let today = DashboardPeriod(kind: .today, now: monday, calendar: cal)
        XCTAssertEqual(week.start, today.start)
        XCTAssertEqual(week.elapsedDays, 1)
        XCTAssertEqual(week.displaySlots, 7)
        XCTAssertFalse(week.isHourly)
        XCTAssertTrue(today.isHourly)
    }

    func testSundayWeekStartsMondayNotRollingSevenDays() {
        let cal = calendar()
        let sunday = cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 23))!
        let week = DashboardPeriod(kind: .week, now: sunday, calendar: cal)
        XCTAssertEqual(week.start, cal.date(from: DateComponents(year: 2026, month: 9, day: 14)))
        XCTAssertEqual(week.end, cal.date(from: DateComponents(year: 2026, month: 9, day: 21)))
        XCTAssertEqual(week.elapsedDays, 7)
    }

    func testThirtyDaysCrossMonthAndDST() {
        let cal = calendar("America/Los_Angeles")
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 15))!
        let period = DashboardPeriod(kind: .days30, now: now, calendar: cal)
        XCTAssertEqual(period.elapsedDays, 30)
        XCTAssertEqual(period.displaySlots, 30)
        XCTAssertEqual(cal.dateComponents([.day], from: period.start, to: period.end).day, 30)
        XCTAssertNotEqual(period.end.timeIntervalSince(period.start), 30 * 86400)
    }

    func testPeriodRoundTripAndRejectsOldDerivedSnapshot() throws {
        let snapshot = DashboardSnapshot()
        let decoded = try JSONDecoder().decode(DashboardSnapshot.self, from: Data(snapshot.jsonString().utf8))
        XCTAssertEqual(decoded.period, snapshot.period)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshot.jsonString().utf8)) as? [String: Any])
        json.removeValue(forKey: "period")
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(DashboardSnapshot.self, from: old))
    }
}
