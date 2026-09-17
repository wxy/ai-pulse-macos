import XCTest
@testable import AIPulse

final class CalendarTests: XCTestCase {
    func testLocalDayDoesNotUseUTCMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16))!
        let earlyMorning = midnight.addingTimeInterval(3 * 3600)
        XCTAssertEqual(calendar.localDayTimestamp(milliseconds: Int64(earlyMorning.timeIntervalSince1970 * 1000)),
                       Int64(midnight.timeIntervalSince1970 * 1000))
    }

    func testDayBucketsRespectShortAndLongDSTDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let start = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            XCTAssertEqual(end.timeIntervalSince(start), Double(hours * 3600))
            XCTAssertEqual(calendar.localDayTimestamp(milliseconds: Int64(end.addingTimeInterval(-1).timeIntervalSince1970 * 1000)),
                           Int64(start.timeIntervalSince1970 * 1000))
            XCTAssertEqual(calendar.localDayTimestamp(milliseconds: Int64(end.timeIntervalSince1970 * 1000)),
                           Int64(end.timeIntervalSince1970 * 1000))
        }
    }

    private var cal: Calendar {
        var c = Calendar.current
        // ISO 8601 weekday ordering: Monday = 1 … Sunday = 7
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func weekday(of d: Date) -> Int {
        cal.component(.weekday, from: d)  // 1 = Sunday … 7 = Saturday (Gregorian)
    }

    func testMondayReturnsItself() {
        // 2026-08-03 is a Monday
        let monday = date(2026, 8, 3)
        XCTAssertEqual(weekday(of: monday), 2)
        XCTAssertEqual(Calendar.mondayOfWeek(for: monday), monday)
    }

    func testSundayReturnsPreviousMonday() {
        // 2026-08-09 is a Sunday → belongs to the week of 2026-08-03
        let sunday = date(2026, 8, 9)
        XCTAssertEqual(weekday(of: sunday), 1)
        let expectedMonday = date(2026, 8, 3)
        XCTAssertEqual(Calendar.mondayOfWeek(for: sunday), expectedMonday)
    }

    func testMidWeekDateMapsToItsMonday() {
        // 2026-08-06 (Thursday) → Monday 2026-08-03
        let thursday = date(2026, 8, 6)
        XCTAssertEqual(Calendar.mondayOfWeek(for: thursday), date(2026, 8, 3))
    }

    func testFirstMondayOfMonth() {
        // 2026-09-01 is a Tuesday → Monday is 2026-08-31
        let first = date(2026, 9, 1)
        XCTAssertEqual(Calendar.mondayOfWeek(for: first), date(2026, 8, 31))
    }

    func testCrossYearISOWeeks() {
        // 2026-01-01 (Thursday) belongs to ISO week of 2025-12-29 (Monday)
        let newYear = date(2026, 1, 1)
        XCTAssertEqual(Calendar.mondayOfWeek(for: newYear), date(2025, 12, 29))
    }

    func testMondayOfWeekNeverCrashesOnExtremeDates() {
        let dates: [Date] = [.distantPast, .distantFuture, Date(timeIntervalSince1970: 0)]
        for d in dates {
            let monday = Calendar.mondayOfWeek(for: d)
            XCTAssertTrue(monday.timeIntervalSince1970.isFinite)
        }
    }
}
