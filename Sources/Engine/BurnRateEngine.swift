import Foundation
import GRDB

/// Consumption intensity tier — shared by sound (CoinSound) and visual
/// (menu bar status item) so the whole perception layer speaks one language.
enum BurnTier: String, Equatable {
    case cold    // < 0.5× baseline
    case normal  // 0.5–1.5×  (also: data present but no baseline yet)
    case hot     // 1.5–3×
    case blaze   // > 3×
}

/// One burn-rate reading: consumption intensity per hour with the
/// denomination fallback chain from 设计文档 §3.1 — money first (USD/h),
/// tokens as the log-only fallback. The two shapes are never mixed.
struct BurnRateSnapshot: Equatable {
    let usdPerHour: Double?
    let tokensPerHour: Double?
    var attributedLinesPerHour: Double?  // P1 WI-5; always nil until attribution lands
    let confidence: CostConfidence
    let tier: BurnTier
    let asOf: Date

    /// `~` prefix for estimated readings (§3.1 诚实标注).
    var usdPerHourDisplay: String? {
        guard let usdPerHour else { return nil }
        let prefix = confidence == .exact ? "" : "~"
        return prefix + String(format: "$%.2f/h", usdPerHour)
    }
}

/// Legacy money-first calculation retained for compatibility tests and balance
/// delta derivation. Runtime perception consumers use `PulseEngine`; this type
/// must not regain responsibility for sound or visual state.
///
/// Money attribution (§4.2, mirrors the ledger's no-double-count rule):
/// - Providers with a balance API (B 级): money = balance_snapshot diffs → `exact`.
/// - Everything else (A 级 logs): money = token-priced `cost_usd` → `estimated`.
/// The rolling window excludes A-grade rows belonging to balance-tracked
/// providers so the same dollar is never counted twice.
///
/// Ground rules (产品设计 §3.1/§4):
/// - Money and tokens are never summed across denominations.
/// - Subscription amortization never burns (excluded via the repo-wide
///   `<synthetic>` convention).
/// - Reads go through `HourlyBaseline` so alerts and burn share one baseline.
/// - No new timers: cached snapshot with TTL, invalidated on `.dataDidChange`.
final class BurnRateEngine: @unchecked Sendable {
    static let shared = BurnRateEngine()
    private init() {}

    // MARK: - Tunables (WI-1 计算口径)

    static let windowSeconds: Int64 = 3600          // rolling window: 1 hour
    static let baselineDays: Int = 7                // baseline lookback
    static let balanceLookbackMs: Int64 = 86_400_000 // snapshot base before window start
    static let minBaseline: Double = 0.005          // below this: no meaningful baseline
    static let cacheTTL: TimeInterval = 30          // snapshot freshness window

    static let coldRatio: Double = 0.5
    static let hotRatio: Double = 1.5
    static let blazeRatio: Double = 3.0

    private var cached: BurnRateSnapshot?
    private var cachedAt = Date.distantPast

    // MARK: - Public API

    /// Current snapshot (cached ≤ 30s). Returns nil only if computation threw.
    func snapshot() async -> BurnRateSnapshot? {
        if let cached, Date().timeIntervalSince(cachedAt) < Self.cacheTTL {
            return cached
        }
        guard let fresh = try? await compute() else { return cached }
        cached = fresh
        cachedAt = Date()
        return fresh
    }

    /// Drop the cache — called by DataRefreshCoordinator on data changes.
    func invalidate() {
        cached = nil
        cachedAt = .distantPast
    }

    /// Fetch + build. Thin: all math lives in `buildSnapshot` (unit-tested).
    func compute(now: Date = Date()) async throws -> BurnRateSnapshot {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dayStartMs = Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000)
        let windowStartMs = nowMs - Self.windowSeconds * 1000

        let excludedPids = ProviderRegistry.all.filter { $0.canFetchBalance }.map { $0.id }
        let rolling = try await AppDatabase.shared.read { db in
            try Self.fetchRolling(in: db, windowStartMs: windowStartMs,
                                  excludedProviderIds: excludedPids)
        }
        // One B-grade pass covers both the rolling window and today's fallback:
        // day start is always ≤ window start.
        let balanceDeltas = try await AppDatabase.shared.read { db in
            try Self.fetchBalanceDeltas(in: db, sinceMs: dayStartMs)
        }
        let rollingBalanceSpend = balanceDeltas
            .filter { $0.ts >= windowStartMs }
            .reduce(0.0) { $0 + $1.spend }
        let todayBalanceSpend = balanceDeltas.reduce(0.0) { $0 + $1.spend }

        let todayHours = try await HourlyBaseline.fetchHourly(sinceMs: dayStartMs)
        let baselineHours = try await HourlyBaseline.fetchHourly(
            sinceMs: nowMs - Int64(Self.baselineDays) * 86_400_000)
        let baseline = HourlyBaseline.baselineExcludingLatest(baselineHours)

        return Self.buildSnapshot(rolling: rolling,
                                  rollingBalanceSpend: rollingBalanceSpend,
                                  todayHours: todayHours,
                                  todayBalanceSpend: todayBalanceSpend,
                                  baseline: baseline, now: now)
    }

    // MARK: - Pure math (unit-tested without a database)

    struct RollingWindow: Equatable {
        let cost: Double            // A-grade token-priced money (excl. balance-tracked providers)
        let tokens: Int64
        let exactCount: Int64       // rows with cost > 0 and confidence = exact
        let costCount: Int64        // rows with cost > 0
        var attributedLines: Int64 = 0  // AI-attributed code-change churn (WI-5)
    }

    /// Denomination fallback chain (§3.1):
    /// 1. rolling 1h window → USD/h (A + B money) + tok/h
    /// 2. empty window → today's active-hour mean
    /// 3. nothing at all → honest silence (nils, .cold)
    static func buildSnapshot(rolling: RollingWindow,
                              rollingBalanceSpend: Double,
                              todayHours: [HourlyBaseline.HourlySpend],
                              todayBalanceSpend: Double,
                              baseline: Double,
                              now: Date = Date()) -> BurnRateSnapshot {
        var usd: Double?
        var tokens: Int64? = rolling.tokens > 0 ? rolling.tokens : nil
        var confidence: CostConfidence

        let rollingMoney = rolling.cost + rollingBalanceSpend
        if rollingMoney > 0 {
            usd = rollingMoney
            // Money is exact only when it comes solely from balance diffs;
            // any token-priced A-grade row makes the whole reading estimated.
            confidence = (rolling.costCount == 0 && rollingBalanceSpend > 0) ? .exact : .estimated
        } else if tokens != nil {
            confidence = .estimated
        } else {
            confidence = .uncertain
        }

        // Attributed code-change churn is the third denomination (§4.2): a
        // window with only attributed lines still surfaces a reading — that is
        // exactly the blind-tool case (log-less, key-less plans).
        let hasLines = rolling.attributedLines > 0

        if usd == nil && tokens == nil {
            let active = todayHours.filter { $0.cost > 0 || $0.tokens > 0 }
            if !active.isEmpty {
                var meanCost = active.map(\.cost).reduce(0, +) / Double(active.count)
                if todayBalanceSpend > 0 {
                    meanCost += todayBalanceSpend / Double(active.count)
                }
                let meanTokens = active.map(\.tokens).reduce(0, +) / Int64(active.count)
                if meanCost > 0 { usd = meanCost }
                if meanTokens > 0 { tokens = meanTokens }
                if confidence == .uncertain { confidence = .estimated }
            }
        }

        guard usd != nil || tokens != nil || hasLines else {
            return BurnRateSnapshot(usdPerHour: nil, tokensPerHour: nil,
                                    attributedLinesPerHour: nil,
                                    confidence: .incomplete, tier: .cold, asOf: now)
        }

        // Tier is driven by the money shape; tokens-only or lines-only windows
        // read as normal (no money baseline exists for them yet).
        let ratio = (usd != nil && baseline > minBaseline) ? usd! / baseline : nil
        let tier = Self.tier(ratio: ratio)
        return BurnRateSnapshot(usdPerHour: usd, tokensPerHour: tokens.map(Double.init),
                                attributedLinesPerHour: rolling.attributedLines > 0
                                    ? Double(rolling.attributedLines) : nil,
                                confidence: confidence, tier: tier, asOf: now)
    }

    /// ratio nil (no baseline / tokens-only) → `.normal` per §3.1.
    static func tier(ratio: Double?) -> BurnTier {
        guard let r = ratio else { return .normal }
        if r < coldRatio { return .cold }
        if r <= hotRatio { return .normal }
        if r <= blazeRatio { return .hot }
        return .blaze
    }

    // MARK: - Database access

    /// A-grade money/tokens in the window, excluding balance-tracked providers
    /// (their money arrives via balance diffs — never double-count).
    static func fetchRolling(in db: Database, windowStartMs: Int64,
                             excludedProviderIds: [String] = []) throws -> RollingWindow {
        let exclusion = excludedProviderIds.isEmpty
            ? ""
            : "AND (provider_id IS NULL OR provider_id NOT IN (\(excludedProviderIds.map { _ in "?" }.joined(separator: ","))))"
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(cost_usd), 0) AS c,
                   COALESCE(SUM(\(TokenAccounting.observedTotalSQL)), 0) AS t,
                   CAST(SUM(CASE WHEN cost_usd > 0 AND cost_confidence = 'exact'
                                 THEN 1 ELSE 0 END) AS INTEGER) AS ec,
                   CAST(SUM(CASE WHEN cost_usd > 0 THEN 1 ELSE 0 END) AS INTEGER) AS cc
            FROM usage_event
            WHERE ts >= ? \(exclusion)
              AND (model IS NULL OR model != '<synthetic>')
            """, arguments: StatementArguments([windowStartMs] + excludedProviderIds))!
        // WI-5: AI-attributed code-change churn in the same window. Unattributed
        // rows never count (归因不到 = 不计量); churn = added + deleted.
        let lines = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(added + deleted), 0) AS l
            FROM code_change
            WHERE attribution IS NOT NULL AND ts >= ?
            """, arguments: [windowStartMs])!
        return RollingWindow(cost: row["c"] as Double? ?? 0,
                             tokens: row["t"] as Int64? ?? 0,
                             exactCount: row["ec"] as Int64? ?? 0,
                             costCount: row["cc"] as Int64? ?? 0,
                             attributedLines: lines["l"] as Int64? ?? 0)
    }

    /// B-grade money: positive balance drops (interval net spend) since
    /// `sinceMs`, stamped with the later snapshot's ts and converted to USD.
    /// Includes the latest snapshot before the boundary as the baseline so the
    /// first in-range delta is not silently lost.
    /// Same derivation as `StatsService.balanceDailySpend`, at event granularity.
    static func fetchBalanceDeltas(in db: Database, sinceMs: Int64) throws
        -> [(providerId: String, ts: Int64, nativeAmount: Double, currency: String, spend: Double)] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT provider_id, ts, balance, currency FROM balance_snapshot
            WHERE ts >= ?
            UNION ALL
            SELECT boundary.provider_id, boundary.ts, boundary.balance, boundary.currency
            FROM balance_snapshot AS boundary
            WHERE boundary.id = (
                SELECT candidate.id
                FROM balance_snapshot AS candidate
                WHERE candidate.provider_id = boundary.provider_id
                  AND candidate.ts < ?
                ORDER BY candidate.ts DESC, candidate.id DESC
                LIMIT 1
            )
            ORDER BY provider_id, ts
            """, arguments: [sinceMs, sinceMs])

        var deltas: [(providerId: String, ts: Int64, nativeAmount: Double, currency: String, spend: Double)] = []
        var currentPid: String?
        var prevBalance: Double?
        for r in rows {
            let pid: String = r["provider_id"] ?? ""
            let ts: Int64 = r["ts"] ?? 0
            let balance: Double = r["balance"] ?? 0
            let currency: String = r["currency"] ?? "USD"
            if pid == currentPid, let prev = prevBalance, ts >= sinceMs, balance < prev {
                let nativeAmount = prev - balance
                deltas.append((providerId: pid, ts: ts, nativeAmount: nativeAmount,
                               currency: currency,
                               spend: nativeAmount * StatsService.toUSD(currency: currency)))
            }
            currentPid = pid
            prevBalance = balance
        }
        return deltas
    }
}
