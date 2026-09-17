import XCTest
@testable import AIPulse
import AIPulseShared

final class SnapshotSanitizeTests: XCTestCase {
    func testSanitizesNonFiniteAndNegativeValues() {
        var snap = DashboardSnapshot()
        snap.todayCalls = -5
        snap.todayTokens = 100
        snap.observedSpend = [ObservedSpendItem(
            providerId: "p", amount: .nan, currency: "CNY",
            convertedUSD: -1, conversionRateToUSD: -.infinity,
            conversionSource: "test", observedAt: .infinity)]
        snap.convertedObservedSpendUSD = .nan
        snap.declaredMonthlyCostUSD = 20
        snap.providerBreakdown = [ProviderItem(providerId: "p", name: "P", cost: .nan)]
        snap.toolBreakdown = [ToolActivityItem(toolId: "t", name: "t")]
        snap.topRepos = [RepoItem(repoPath: "/r", name: "r", added: -1, deleted: 2, commits: -4)]
        snap.dailyStats = [
            TrendPoint(ts: .nan, value: -8, calls: -1, tokens: 2, netLines: 3)
        ]
        snap.codeChanges = [
            TrendPoint(ts: 1, value: 2, calls: 0, tokens: 0, netLines: 1,
                       added: 2, deleted: 1, commits: -3)
        ]
        snap.balanceDaily = [
            TrendPoint(ts: 5, value: .infinity, calls: 0, tokens: 0, netLines: 0)
        ]
        snap.remainingBalances = [
            RemainingBalanceItem(providerId: "x", displayName: "X", balance: -.infinity, currency: "USD")
        ]
        snap.quotaStatus = [
            QuotaStatusItem(toolId: "c", windowId: "5h", utilization: -1,
                            limitStatus: "", resetAt: .nan, windowSeconds: 3600,
                            updatedAt: .nan)
        ]
        snap.periodSessions = -10

        let clean = snap.sanitized()

        XCTAssertEqual(clean.todayCalls, 0)
        XCTAssertEqual(clean.periodSessions, 0)
        XCTAssertEqual(clean.todayTokens, 100)
        XCTAssertEqual(clean.observedSpend?[0].amount, 0)
        XCTAssertEqual(clean.observedSpend?[0].convertedUSD, 0)
        XCTAssertEqual(clean.observedSpend?[0].conversionRateToUSD, 0)
        XCTAssertEqual(clean.observedSpend?[0].conversionSource, "test")
        XCTAssertEqual(clean.observedSpend?[0].observedAt, 0)
        XCTAssertEqual(clean.convertedObservedSpendUSD, 0)
        XCTAssertEqual(clean.declaredMonthlyCostUSD, 20)
        XCTAssertEqual(clean.providerBreakdown[0].cost, 0)
        XCTAssertEqual(clean.topRepos[0].added, 0)
        XCTAssertEqual(clean.topRepos[0].deleted, 2)
        XCTAssertEqual(clean.topRepos[0].commits, 0)
        XCTAssertEqual(clean.dailyStats[0].ts, 0)
        XCTAssertEqual(clean.dailyStats[0].value, 0)
        XCTAssertEqual(clean.dailyStats[0].calls, 0)
        XCTAssertEqual(clean.dailyStats[0].tokens, 2)
        XCTAssertEqual(clean.dailyStats[0].netLines, 3)
        XCTAssertEqual(clean.codeChanges[0].commits, 0)
        XCTAssertEqual(clean.balanceDaily[0].value, 0)
        XCTAssertEqual(clean.remainingBalances[0].balance, 0)
        XCTAssertEqual(clean.quotaStatus[0].utilization, 0)
        XCTAssertEqual(clean.quotaStatus[0].resetAt, 0)
        XCTAssertEqual(clean.quotaStatus[0].windowSeconds, 3600)
        XCTAssertEqual(clean.quotaStatus[0].windowId, "5h")
        XCTAssertEqual(clean.quotaStatus[0].updatedAt, 0)
    }

    func testSanitizesNewTrustedDataFields() {
        var snap = DashboardSnapshot()
        snap.modelBreakdown = [ModelActivityItem(
            model: "deepseek-v4-pro", providerId: "deepseek",
            tokens: -5, calls: -2)]
        snap.toolBreakdown = [ToolActivityItem(toolId: "chatgpt", name: "ChatGPT", tokens: -7)]
        snap.topRepos = [RepoItem(repoPath: "/r", name: "r", added: 1, deleted: 1, tokens: -3)]
        snap.providerBreakdown = [ProviderItem(
            providerId: "deepseek", name: "DeepSeek", cost: 1, sourceKind: "balance")]

        let clean = snap.sanitized()

        XCTAssertEqual(clean.modelBreakdown[0].tokens, 0)
        XCTAssertEqual(clean.modelBreakdown[0].calls, 0)
        XCTAssertEqual(clean.toolBreakdown[0].tokens, 0)
        XCTAssertEqual(clean.topRepos[0].tokens, 0)
        XCTAssertEqual(clean.providerBreakdown[0].sourceKind, "balance")
    }
}
