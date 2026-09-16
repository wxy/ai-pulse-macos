import XCTest
import GRDB
@testable import AIPulse

final class BurnRateEngineTests: XCTestCase {

    // MARK: - Tier thresholds (WI-1: <0.5 cold · 0.5–1.5 normal · 1.5–3 hot · >3 blaze)

    func testTierThresholds() {
        XCTAssertEqual(BurnRateEngine.tier(ratio: nil), .normal, "no baseline → normal (§3.1)")
        XCTAssertEqual(BurnRateEngine.tier(ratio: 0.2), .cold)
        XCTAssertEqual(BurnRateEngine.tier(ratio: 0.49), .cold)
        XCTAssertEqual(BurnRateEngine.tier(ratio: 0.5), .normal)
        XCTAssertEqual(BurnRateEngine.tier(ratio: 1.5), .normal)
        XCTAssertEqual(BurnRateEngine.tier(ratio: 1.51), .hot)
        XCTAssertEqual(BurnRateEngine.tier(ratio: 3.0), .hot)
        XCTAssertEqual(BurnRateEngine.tier(ratio: 3.01), .blaze)
    }

    // MARK: - buildSnapshot: denomination fallback chain (§3.1)

    private func makeHours(_ costs: [Double], tokens: [Int64]? = nil) -> [HourlyBaseline.HourlySpend] {
        (0..<costs.count).map { i in
            HourlyBaseline.HourlySpend(hour: Int64(i),
                                       cost: costs[i],
                                       tokens: tokens?[i] ?? 0)
        }
    }

    func testRollingWindowWithMoneyDrivesTierAndEstimatedConfidence() {
        let snap = BurnRateEngine.buildSnapshot(
            rolling: .init(cost: 2.0, tokens: 1_000, exactCount: 0, costCount: 2),
            rollingBalanceSpend: 0, todayHours: [], todayBalanceSpend: 0, baseline: 1.0)

        XCTAssertEqual(snap.usdPerHour ?? 0, 2.0, accuracy: 1e-9)
        XCTAssertEqual(snap.tokensPerHour, 1_000.0)
        XCTAssertEqual(snap.tier, .hot, "2.0 / 1.0 baseline = 2× → hot")
        XCTAssertEqual(snap.confidence, .estimated, "token-priced A-grade money is estimated")
    }

    func testBalanceOnlyWindowIsExact() {
        let snap = BurnRateEngine.buildSnapshot(
            rolling: .init(cost: 0, tokens: 0, exactCount: 0, costCount: 0),
            rollingBalanceSpend: 2.0, todayHours: [], todayBalanceSpend: 0, baseline: 1.0)

        XCTAssertEqual(snap.usdPerHour ?? 0, 2.0, accuracy: 1e-9)
        XCTAssertEqual(snap.confidence, .exact, "balance diffs are the exact money shape")
        XCTAssertEqual(snap.usdPerHourDisplay, "$2.00/h", "exact readings carry no tilde")
    }

    func testMixedAPlusBMoneyIsEstimated() {
        let snap = BurnRateEngine.buildSnapshot(
            rolling: .init(cost: 1.0, tokens: 0, exactCount: 0, costCount: 1),
            rollingBalanceSpend: 2.0, todayHours: [], todayBalanceSpend: 0, baseline: 1.0)

        XCTAssertEqual(snap.usdPerHour ?? 0, 3.0, accuracy: 1e-9, "A and B money sum, providers disjoint")
        XCTAssertEqual(snap.confidence, .estimated, "any A-grade presence makes the reading estimated")
    }

    func testEstimatedReadingsCarryTilde() {
        let snap = BurnRateEngine.buildSnapshot(
            rolling: .init(cost: 1.234, tokens: 0, exactCount: 0, costCount: 1),
            rollingBalanceSpend: 0, todayHours: [], todayBalanceSpend: 0, baseline: 0)
        XCTAssertEqual(snap.usdPerHourDisplay, "~$1.23/h")
        XCTAssertNil(snap.tokensPerHour, "token shape stays nil when window has only zero-token cost")
    }

    func testEmptyWindowFallsBackToTodayActiveHourMean() {
        let snap = BurnRateEngine.buildSnapshot(
            rolling: .init(cost: 0, tokens: 0, exactCount: 0, costCount: 0),
            rollingBalanceSpend: 0,
            todayHours: makeHours([2.0, 4.0], tokens: [100, 300]),
            todayBalanceSpend: 0, baseline: 2.0)

        XCTAssertEqual(snap.usdPerHour ?? 0, 3.0, accuracy: 1e-9, "active-hour mean, not zero-hour mean")
        XCTAssertEqual(snap.tokensPerHour, 200.0)
        XCTAssertEqual(snap.confidence, .estimated)
    }

    func testTodayBalanceSpendSpreadsAcrossActiveHours() {
        let snap = BurnRateEngine.buildSnapshot(
            rolling: .init(cost: 0, tokens: 0, exactCount: 0, costCount: 0),
            rollingBalanceSpend: 0,
            todayHours: makeHours([2.0, 4.0]),
            todayBalanceSpend: 1.0, baseline: 0)

        XCTAssertEqual(snap.usdPerHour ?? 0, 3.5, accuracy: 1e-9, "(3.0 A-mean) + (1.0 / 2 active hours)")
        XCTAssertEqual(snap.confidence, .estimated)
    }

    func testNoDataAtAllIsHonestSilence() {
        let snap = BurnRateEngine.buildSnapshot(
            rolling: .init(cost: 0, tokens: 0, exactCount: 0, costCount: 0),
            rollingBalanceSpend: 0, todayHours: [], todayBalanceSpend: 0, baseline: 0)

        XCTAssertNil(snap.usdPerHour)
        XCTAssertNil(snap.tokensPerHour)
        XCTAssertEqual(snap.tier, .cold)
        XCTAssertEqual(snap.confidence, .incomplete)
    }

    func testTokensOnlyWindowReadsNormalWithoutMoneyBaseline() {
        let snap = BurnRateEngine.buildSnapshot(
            rolling: .init(cost: 0, tokens: 5_000, exactCount: 0, costCount: 0),
            rollingBalanceSpend: 0, todayHours: [], todayBalanceSpend: 0, baseline: 0)

        XCTAssertNil(snap.usdPerHour, "money and tokens are never fabricated from each other")
        XCTAssertEqual(snap.tokensPerHour, 5_000.0)
        XCTAssertEqual(snap.tier, .normal)
    }

    func testBaselineBelowFloorNeverDrivesTier() {
        let snap = BurnRateEngine.buildSnapshot(
            rolling: .init(cost: 10.0, tokens: 0, exactCount: 1, costCount: 1),
            rollingBalanceSpend: 0, todayHours: [], todayBalanceSpend: 0, baseline: 0.001)
        XCTAssertEqual(snap.tier, .normal, "0.001 baseline is noise, not a reference point")
    }

    // MARK: - Database access against a real (in-memory) schema

    private func makeDB() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
        }
        return dbQueue
    }

    private func insertUsage(_ db: Database, ts: Int64, provider: String?,
                             cost: Double?, tokens: Int,
                             model: String? = "glm-5.3-flash", dedupe: String) throws {
        try db.execute(sql: """
            INSERT INTO usage_event
              (ts, source, provider_id, model, in_tokens, out_tokens, cache_tokens,
               cost_usd, dedupe_key, cost_source_id, cost_confidence)
            VALUES (?, 'claude-code', ?, ?, ?, 0, 0, ?, ?, 'unattributed', 'estimated')
            """, arguments: [ts, provider as String?, model as String?, tokens, cost, dedupe as String?])
    }

    private func insertBalance(_ db: Database, ts: Int64, provider: String,
                               balance: Double, currency: String = "USD") throws {
        try db.execute(sql: """
            INSERT INTO balance_snapshot (provider_id, ts, balance, currency)
            VALUES (?, ?, ?, ?)
            """, arguments: [provider, ts, balance, currency])
    }

    func testFetchRollingSumsAndConfidenceCounts() throws {
        let dbQueue = try makeDB()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try dbQueue.write { db in
            try insertUsage(db, ts: now - 1_000, provider: "deepseek", cost: 3.0, tokens: 30, dedupe: "r1")
            try insertUsage(db, ts: now - 2_000, provider: "deepseek", cost: 1.5, tokens: 3, dedupe: "r2")
            try insertUsage(db, ts: now - 3_000, provider: nil, cost: 99.0, tokens: 0,
                            model: "<synthetic>", dedupe: "r3")
        }

        let window = try dbQueue.read { db in
            try BurnRateEngine.fetchRolling(in: db, windowStartMs: 0)
        }

        XCTAssertEqual(window.cost, 4.5, accuracy: 1e-9, "synthetic row excluded")
        XCTAssertEqual(window.tokens, 33)
        XCTAssertEqual(window.costCount, 2)
    }

    func testFetchRollingExcludesBalanceTrackedProviders() throws {
        let dbQueue = try makeDB()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try dbQueue.write { db in
            // deepseek is balance-tracked → its A-grade rows must be excluded
            try insertUsage(db, ts: now - 1_000, provider: "deepseek", cost: 3.0, tokens: 30, dedupe: "d1")
            // unknown provider → kept (A-grade money)
            try insertUsage(db, ts: now - 2_000, provider: nil, cost: 2.0, tokens: 10, dedupe: "u1")
            // balance snapshots: 100 → 95 within window → $5 spend
            try insertBalance(db, ts: now - 3_600_000, provider: "deepseek", balance: 100)
            try insertBalance(db, ts: now - 60_000, provider: "deepseek", balance: 95)
            // an increase is not spend
            try insertBalance(db, ts: now - 30_000, provider: "deepseek", balance: 97)
        }

        let window = try dbQueue.read { db in
            try BurnRateEngine.fetchRolling(in: db, windowStartMs: now - 3_600_000,
                                            excludedProviderIds: ["deepseek"])
        }

        XCTAssertEqual(window.cost, 2.0, accuracy: 1e-9, "balance-tracked provider excluded from A money")
        let deltas = try dbQueue.read { db in
            try BurnRateEngine.fetchBalanceDeltas(in: db, sinceMs: now - 3_600_000)
        }
        XCTAssertEqual(deltas.count, 1, "balance increase is not spend")
        XCTAssertEqual(deltas[0].spend, 5.0, accuracy: 1e-9)
        XCTAssertEqual(deltas[0].ts, now - 60_000)
    }

    func testBalanceDeltaUsesSnapshotBeforeWindowAsBaseline() throws {
        let dbQueue = try makeDB()
        let windowStart: Int64 = 10_000
        try dbQueue.write { db in
            try insertBalance(db, ts: windowStart - 1, provider: "deepseek", balance: 100)
            try insertBalance(db, ts: windowStart + 1, provider: "deepseek", balance: 96)
        }

        let deltas = try dbQueue.read { db in
            try BurnRateEngine.fetchBalanceDeltas(in: db, sinceMs: windowStart)
        }

        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas[0].spend, 4, accuracy: 1e-9)
        XCTAssertEqual(deltas[0].ts, windowStart + 1)
    }

    func testCumulativeUsageSnapshotsProducePositiveSpend() throws {
        let dbQueue = try makeDB()
        let windowStart: Int64 = 20_000
        try dbQueue.write { db in
            // Usage-type providers are persisted as negative cumulative values,
            // so growth from 10 to 14 is represented as -10 -> -14.
            try insertBalance(db, ts: windowStart - 1, provider: "openai", balance: -10)
            try insertBalance(db, ts: windowStart + 1, provider: "openai", balance: -14)
        }

        let deltas = try dbQueue.read { db in
            try BurnRateEngine.fetchBalanceDeltas(in: db, sinceMs: windowStart)
        }

        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas[0].nativeAmount, 4, accuracy: 1e-9)
        XCTAssertEqual(deltas[0].spend, 4, accuracy: 1e-9)
    }
}

// MARK: - WI-5: attributed code-change churn

extension BurnRateEngineTests {

    func testAttributedLinesLandInRollingWindow() throws {
        let dbQueue = try makeDB()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try dbQueue.write { db in
            // attributed rows count
            try db.execute(sql: """
                INSERT INTO code_change (commit_hash, ts, repo_path, added, deleted, is_merge, attributed_tool, attribution)
                VALUES ('a1', ?, '/repo', 30, 10, 0, 'Claude', 'exact')
                """, arguments: [now - 1_000])
            try db.execute(sql: """
                INSERT INTO code_change (commit_hash, ts, repo_path, added, deleted, is_merge, attributed_tool, attribution)
                VALUES ('a2', ?, '/repo', 5, 5, 0, 'Cursor', 'uncertain')
                """, arguments: [now - 2_000])
            // unattributed rows never count (归因不到 = 不计量)
            try db.execute(sql: """
                INSERT INTO code_change (commit_hash, ts, repo_path, added, deleted, is_merge)
                VALUES ('u1', ?, '/repo', 500, 500, 0)
                """, arguments: [now - 3_000])
            // old attributed row outside the window
            try db.execute(sql: """
                INSERT INTO code_change (commit_hash, ts, repo_path, added, deleted, is_merge, attributed_tool, attribution)
                VALUES ('old', ?, '/repo', 9_000, 0, 0, 'Claude', 'exact')
                """, arguments: [now - 7_200_000])
        }

        let window = try dbQueue.read { db in
            try BurnRateEngine.fetchRolling(in: db, windowStartMs: now - 3_600_000)
        }
        XCTAssertEqual(window.attributedLines, 50, "30+10 churn from a1, 5+5 from a2; unattributed and stale rows excluded")

        let snap = BurnRateEngine.buildSnapshot(
            rolling: window, rollingBalanceSpend: 0,
            todayHours: [], todayBalanceSpend: 0, baseline: 0)
        XCTAssertEqual(snap.attributedLinesPerHour, 50.0)
    }

    func testBuildSnapshotDefaultsAttributedLinesToNil() {
        let snap = BurnRateEngine.buildSnapshot(
            rolling: .init(cost: 0, tokens: 0, exactCount: 0, costCount: 0),
            rollingBalanceSpend: 0, todayHours: [], todayBalanceSpend: 0, baseline: 0)
        XCTAssertNil(snap.attributedLinesPerHour)
    }
}
