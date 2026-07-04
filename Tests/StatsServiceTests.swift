import XCTest
@testable import AIPulse

final class StatsServiceTests: XCTestCase {

    // MARK: - combinedSpend

    func testCombinedSpendReturnsZeroWhenNoData() async {
        let spend = await StatsService.combinedSpend(
            sinceMs: Int64(Date().timeIntervalSince1970 * 1000))
        XCTAssertGreaterThanOrEqual(spend, 0, "Should return >= 0 even with no data")
    }

    // MARK: - dailyStats

    func testDailyStatsReturnsEmptyForNoData() async throws {
        let stats = try await StatsService.dailyStats(days: 7)
        XCTAssertEqual(stats.count, 0, "Should return empty array for fresh DB")
    }

    // MARK: - prediction

    func testPredictionReturnsZeroForNoData() async {
        let pred = await StatsService.prediction()
        XCTAssertEqual(pred.monthSoFar, 0, "Month so far should be 0 with no data")
        XCTAssertEqual(pred.dailyRate, 0, "Daily rate should be 0 with no data")
        XCTAssertGreaterThan(pred.daysRemaining, 0, "Should have remaining days in month")
    }

    // MARK: - repoBreakdown

    func testRepoBreakdownReturnsEmptyWhenNoData() async throws {
        let repos = try await StatsService.repoBreakdown(days: 7)
        XCTAssertEqual(repos.count, 0, "Should return empty array for fresh DB")
    }

    // MARK: - providerDailyCosts

    func testProviderDailyCostsReturnsEmptyWhenNoData() async throws {
        let costs = try await StatsService.providerDailyCosts(days: 7)
        XCTAssertEqual(costs.count, 0, "Should return empty array for fresh DB")
    }

    // MARK: - dailyCodeChanges

    func testDailyCodeChangesReturnsEmptyWhenNoData() async throws {
        let changes = try await StatsService.dailyCodeChanges(days: 7)
        XCTAssertEqual(changes.count, 0, "Should return empty array for fresh DB")
    }

    // MARK: - balanceDailySpend

    func testBalanceDailySpendReturnsEmptyWhenNoData() async throws {
        let spend = try await StatsService.balanceDailySpend(days: 7)
        XCTAssertEqual(spend.count, 0, "Should return empty array for fresh DB")
    }
}
