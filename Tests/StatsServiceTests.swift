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

    func testModelBreakdownSanitizesRows() {
        let rows = [
            (model: "deepseek-v4-pro", providerId: "deepseek", toolId: "claude-code", tokens: Int64(860_000), calls: 92, cost: 1.2),
            (model: "bad", providerId: "deepseek", toolId: "claude-code", tokens: Int64(-1), calls: -2, cost: .nan),
        ]

        let items = StatsService.modelBreakdown(rows: rows)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].tokens, 860_000)
        XCTAssertEqual(items[0].calls, 92)
        XCTAssertEqual(items[0].cost ?? -1, 1.2)
        XCTAssertEqual(items[1].tokens, 0)
        XCTAssertEqual(items[1].calls, 0)
        XCTAssertNil(items[1].cost)
    }

    func testExclusiveProvidersOnlyWhenSingleTool() {
        let usage: [String: Set<String>] = [
            "claude-code": ["deepseek"],
            "chatgpt": ["openai"],
            "api": ["deepseek"],
        ]

        XCTAssertEqual(StatsService.exclusiveProviders(usageByTool: usage), ["openai"])
    }

    func testRepoTokenByNameMergesDuplicateBasenames() {
        let rows = [
            (path: "/a/new-chat", tokens: Int64(100)),
            (path: "/b/new-chat", tokens: Int64(200)),
            (path: "/c/ai-pulse", tokens: Int64(50)),
        ]

        let map = StatsService.repoTokenByName(rows)

        XCTAssertEqual(map["new-chat"], 300)
        XCTAssertEqual(map["ai-pulse"], 50)
    }

    func testRepositoryVisibilityIncludesUsageOnlyFacts() {
        XCTAssertTrue(DashboardView.shouldShowRepository(totalChanges: 0, tokens: 1))
        XCTAssertTrue(DashboardView.shouldShowRepository(totalChanges: 12, tokens: 0))
        XCTAssertFalse(DashboardView.shouldShowRepository(totalChanges: 0, tokens: 0))
    }

    func testSubscriptionProgress() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -15, to: today)!

        let p = StatsService.subscriptionProgress(start: start, periodDays: 30, now: Date())

        XCTAssertEqual(p.elapsedDays, 15)
        XCTAssertEqual(p.totalDays, 30)
        XCTAssertNotNil(p.nextReset)
        XCTAssertEqual(cal.dateComponents([.day], from: start, to: p.nextReset!).day, 30)
    }

    func testSubscriptionProgressClampsToPeriod() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -45, to: today)!

        let p = StatsService.subscriptionProgress(start: start, periodDays: 30, now: Date())

        XCTAssertEqual(p.elapsedDays, 30)
        XCTAssertEqual(p.totalDays, 30)
    }
}
