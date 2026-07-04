import XCTest
@testable import AIPulse

final class StatsServiceTests: XCTestCase {

    // MARK: - Methods that work without DB setup

    func testPredictionReturnsZeroForNoData() async {
        let pred = await StatsService.prediction()
        XCTAssertEqual(pred.monthSoFar, 0, "Month so far should be 0 with no data")
        XCTAssertEqual(pred.dailyRate, 0, "Daily rate should be 0 with no data")
        XCTAssertGreaterThanOrEqual(pred.daysRemaining, 0, "Days remaining should be >= 0")
    }

    func testCombinedSpendReturnsZeroWhenNoData() async {
        let spend = await StatsService.combinedSpend(
            sinceMs: Int64(Date().timeIntervalSince1970 * 1000))
        XCTAssertGreaterThanOrEqual(spend, 0, "Should return >= 0 even with no data")
    }
}
