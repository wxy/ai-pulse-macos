import XCTest
import AIPulseShared

final class PhoneDashboardDataTests: XCTestCase {
    func testRejectsLegacyAndWrongRangeCache() {
        var snapshot = DashboardSnapshot(payloadVersion: CKSchema.payloadVersion)
        XCTAssertTrue(PhoneDashboardData.accepts(snapshot, range: "today"))
        XCTAssertFalse(PhoneDashboardData.accepts(snapshot, range: "week"))
        snapshot.payloadVersion = "1.0.0"
        XCTAssertFalse(PhoneDashboardData.accepts(snapshot, range: "today"))
        snapshot.payloadVersion = nil
        XCTAssertFalse(PhoneDashboardData.accepts(snapshot, range: "today"))
    }
    func testNoseRespondsToDataAndKeeps99PercentCacheVisible() {
        let widths = PhoneDashboardData.noseWidths([10, 9900, 90])
        XCTAssertEqual(widths.reduce(0, +), 1, accuracy: 0.000001)
        XCTAssertGreaterThan(widths[0], 0.15)
        XCTAssertGreaterThan(widths[1], widths[2])
        XCTAssertGreaterThan(widths[2], widths[0])
        XCTAssertNotEqual(widths, PhoneDashboardData.noseWidths([1000, 1000, 1000]))
    }
    func testHourlyRhythmUsesSourceTimeZoneAndExcludesOutsidePeriod() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let period = DashboardPeriod(kind: .today, now: Date(timeIntervalSince1970: 1_000_000), calendar: cal)
        let point = TrendPoint(ts: period.start.addingTimeInterval(3 * 3600).timeIntervalSince1970, value: 0, calls: 0, tokens: 25, netLines: -2, added: 3, deleted: 5)
        let outside = TrendPoint(ts: period.end.timeIntervalSince1970, value: 0, calls: 0, tokens: 100, netLines: 0)
        let tokens = PhoneDashboardData.rhythm([point, outside], period: period, tokens: true)
        XCTAssertEqual(tokens.count, 24)
        XCTAssertEqual(tokens[3], 25)
        XCTAssertEqual(tokens.reduce(0, +), 25)
        XCTAssertEqual(PhoneDashboardData.rhythm([point], period: period, tokens: false)[3], 8)
    }
    func testWeekHasGrayNeighborSlotsWithoutFabricatedActivity() {
        let period = DashboardPeriod(kind: .week)
        let slots = PhoneDashboardData.rhythm([], period: period, tokens: true)
        XCTAssertEqual(slots.count, 21)
        XCTAssertEqual(Array(slots.prefix(7)), Array(repeating: -1, count: 7))
        XCTAssertEqual(Array(slots[7..<14]), Array(repeating: 0, count: 7))
        XCTAssertEqual(Array(slots.suffix(7)), Array(repeating: -1, count: 7))
    }
}
