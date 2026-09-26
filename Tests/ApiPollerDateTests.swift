import XCTest
@testable import AIPulse

/// The OpenAI usage `date` parameter must be a POSIX, UTC-calendar date:
/// a non-Gregorian locale or a local time zone around UTC midnight would
/// request the wrong day (or an unparseable string, silently skipped).
final class ApiPollerDateTests: XCTestCase {
    func testFormatterEmitsGregorianUTCDate() throws {
        let fmt = ApiPoller.openAIUsageDateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: 2026, month: 9, day: 24, hour: 0, minute: 30)
        let date = try XCTUnwrap(calendar.date(from: components))
        XCTAssertEqual(fmt.string(from: date), "2026-09-24")
    }

    func testFormatterIsLocaleIndependent() throws {
        // "2026-09-24" in a Buddhist-calendar locale would render as 2569-…
        // without the POSIX pin.
        let fmt = ApiPoller.openAIUsageDateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        XCTAssertEqual(fmt.string(from: date), "2026-01-01")
        XCTAssertEqual(fmt.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(fmt.timeZone.identifier, "GMT") // TimeZone(identifier: "UTC") normalizes to GMT
    }
}
