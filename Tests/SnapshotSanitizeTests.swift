import XCTest
@testable import AIPulse
import AIPulseShared

final class SnapshotSanitizeTests: XCTestCase {
    func testSanitizesNonFiniteAndNegativeValues() {
        var snap = DashboardSnapshot()
        snap.todayCost = .nan
        snap.weekCost = -.infinity
        snap.monthCost = 12.5
        snap.yesterdaySpend = .infinity
        snap.previousPeriodSpend = -3
        snap.subDaily = 0.7
        snap.todayCalls = -5
        snap.todayTokens = 100
        snap.providerBreakdown = [ProviderItem(providerId: "p", name: "P", cost: .nan)]
        snap.toolBreakdown = [NameCostItem(name: "t", cost: -.infinity)]
        snap.topRepos = [RepoItem(name: "r", cost: .nan, added: -1, deleted: 2, cpl: .infinity)]
        snap.prediction = PredictionItem(
            monthProjected: .nan, dailyRate: 3, daysRemaining: -2, monthSoFar: 4)
        snap.dailyStats = [
            TrendPoint(ts: .nan, value: -8, calls: -1, tokens: 2, netLines: 3)
        ]
        snap.balanceDaily = [
            TrendPoint(ts: 5, value: .infinity, calls: 0, tokens: 0, netLines: 0)
        ]
        snap.remainingBalances = [
            RemainingBalanceItem(providerId: "x", displayName: "X", balance: -.infinity, currency: "USD")
        ]
        snap.quotaStatus = [
            QuotaStatusItem(toolId: "c", utilization: -1, limitStatus: "", resetAt: .nan, windowSeconds: 3600)
        ]
        snap.toolDetails = [
            ToolDetailItem(
                source: "s",
                conclusion: ToolConclusionItem(
                    spend: .nan, deltaPct: .infinity, avgCostPerSession: -2, cpl: 3),
                sessions: [
                    ToolSessionItem(
                        sessionId: nil, title: nil, repo: nil,
                        firstTs: -1, lastTs: 2, cost: .nan,
                        windowTokens: -3, lastInput: 4, turnCount: -5,
                        avgOccupancy: .nan, avgCacheRatio: 0.5, compactionCount: 0)
                ])
        ]

        let clean = snap.sanitized()

        XCTAssertEqual(clean.todayCost, 0)
        XCTAssertEqual(clean.weekCost, 0)
        XCTAssertEqual(clean.monthCost, 12.5)
        XCTAssertEqual(clean.yesterdaySpend, 0)
        XCTAssertEqual(clean.previousPeriodSpend, 0)
        XCTAssertEqual(clean.subDaily, 0.7)
        XCTAssertEqual(clean.todayCalls, 0)
        XCTAssertEqual(clean.todayTokens, 100)
        XCTAssertEqual(clean.providerBreakdown[0].cost, 0)
        XCTAssertEqual(clean.toolBreakdown[0].cost, 0)
        XCTAssertEqual(clean.topRepos[0].cost, 0)
        XCTAssertEqual(clean.topRepos[0].added, 0)
        XCTAssertEqual(clean.topRepos[0].deleted, 2)
        XCTAssertEqual(clean.topRepos[0].cpl, 0)
        XCTAssertEqual(clean.prediction?.monthProjected ?? -1, 0)
        XCTAssertEqual(clean.prediction?.dailyRate ?? -1, 3)
        XCTAssertEqual(clean.prediction?.daysRemaining ?? -1, 0)
        XCTAssertEqual(clean.dailyStats[0].ts, 0)
        XCTAssertEqual(clean.dailyStats[0].value, 0)
        XCTAssertEqual(clean.dailyStats[0].calls, 0)
        XCTAssertEqual(clean.dailyStats[0].tokens, 2)
        XCTAssertEqual(clean.dailyStats[0].netLines, 3)
        XCTAssertEqual(clean.balanceDaily[0].value, 0)
        XCTAssertEqual(clean.remainingBalances[0].balance, 0)
        XCTAssertEqual(clean.quotaStatus[0].utilization, 0)
        XCTAssertEqual(clean.quotaStatus[0].resetAt, 0)
        XCTAssertEqual(clean.quotaStatus[0].windowSeconds, 3600)
        XCTAssertEqual(clean.toolDetails[0].conclusion.spend, 0)
        XCTAssertEqual(clean.toolDetails[0].conclusion.deltaPct, 0)
        XCTAssertEqual(clean.toolDetails[0].conclusion.avgCostPerSession, 0)
        XCTAssertEqual(clean.toolDetails[0].conclusion.cpl, 3)
        XCTAssertEqual(clean.toolDetails[0].sessions[0].firstTs, 0)
        XCTAssertEqual(clean.toolDetails[0].sessions[0].lastTs, 2)
        XCTAssertEqual(clean.toolDetails[0].sessions[0].cost, 0)
        XCTAssertEqual(clean.toolDetails[0].sessions[0].windowTokens ?? -1, 0)
        XCTAssertEqual(clean.toolDetails[0].sessions[0].lastInput, 4)
        XCTAssertEqual(clean.toolDetails[0].sessions[0].turnCount, 0)
        XCTAssertEqual(clean.toolDetails[0].sessions[0].avgOccupancy ?? -1, 0)
        XCTAssertEqual(clean.toolDetails[0].sessions[0].avgCacheRatio ?? -1, 0.5)
        XCTAssertEqual(clean.toolDetails[0].sessions[0].compactionCount, 0)
    }
}
