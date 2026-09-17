import Foundation
import GRDB
import AIPulseShared

/// A unit-free perception tier. Raw token, money, quota, and output values are
/// never added together; each channel is normalized first and the strongest
/// fresh signal becomes the explanation for the current pulse.
extension PulseTier {
    var rank: Int {
        switch self {
        case .resting: return 0
        case .active: return 1
        case .elevated: return 2
        case .intense: return 3
        }
    }

}

struct PulseSample: Equatable {
    let timestamp: Date
    let value: Double
}

/// Computes an explainable, naturally decaying AI-consumption pulse.
///
/// Activity, observed money, quota pressure, and attributed output keep their
/// own units and baselines. Only their dimensionless normalized scores are
/// compared, never summed. The strongest fresh signal drives the tier/reason.
actor PulseEngine {
    static let shared = PulseEngine()
    private let healthMonitor: AppHealthMonitor
    private let computeOverride: (@Sendable (Date) async throws -> PulseSnapshot)?

    init(healthMonitor: AppHealthMonitor = .shared,
         compute: (@Sendable (Date) async throws -> PulseSnapshot)? = nil) {
        self.healthMonitor = healthMonitor
        self.computeOverride = compute
    }

    private enum ObservationError: Error { case failedQueries([String]) }

    static let baselineDays = 7
    static let currentWindow: TimeInterval = 3_600
    static let halfLife: TimeInterval = 10 * 60
    static let freshAge: TimeInterval = 10 * 60
    static let quotaMaxAge: TimeInterval = 2 * 3_600
    static let cacheTTL: TimeInterval = 15

    private var cached: PulseSnapshot?
    private var cachedAt = Date.distantPast
    private var generation = 0
    private var inFlight: (generation: Int, task: Task<PulseSnapshot, Error>)?

    func snapshot(now: Date = Date()) async -> PulseSnapshot? {
        if let cached, cached.isCurrent(asOf: now), now.timeIntervalSince(cachedAt) >= 0,
           now.timeIntervalSince(cachedAt) < Self.cacheTTL {
            return cached
        }
        if let inFlight, inFlight.generation == generation {
            let result = (try? await inFlight.task.value) ?? cached
            guard generation == inFlight.generation else { return await snapshot(now: now) }
            return result?.isCurrent(asOf: now) == true ? result : nil
        }
        let startedGeneration = generation
        let task = Task {
            let failures = ObservationFailures()
            let result = try await StatsService.$observationFailures.withValue(failures) {
                if let computeOverride { return try await computeOverride(now) }
                return try await compute(now: now)
            }
            let failedQueries = await failures.snapshot()
            guard failedQueries.isEmpty else { throw ObservationError.failedQueries(failedQueries) }
            return result
        }
        inFlight = (startedGeneration, task)
        do {
            let fresh = try await task.value
            guard generation == startedGeneration else {
                return await snapshot(now: now)
            }
            cached = fresh
            cachedAt = now
            inFlight = nil
            healthMonitor.clearStatsError(source: "pulse.current")
            return fresh
        } catch {
            if inFlight?.generation == startedGeneration { inFlight = nil }
            if generation != startedGeneration { return await snapshot(now: now) }
            healthMonitor.reportStatsError(error.localizedDescription, source: "pulse.current")
            return cached?.isCurrent(asOf: now) == true ? cached : nil
        }
    }

    func invalidate() {
        generation &+= 1
        cached = nil
        cachedAt = .distantPast
        inFlight?.task.cancel()
        inFlight = nil
    }

    nonisolated func compute(now: Date = Date()) async throws -> PulseSnapshot {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let historyStartMs = nowMs - Int64(Self.baselineDays) * 86_400_000

        async let usageResult = AppDatabase.shared.read { db in
            let samples = try Self.usageSamples(in: db, sinceMs: historyStartMs, beforeMs: nowMs)
            let missingCreation = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM usage_event
                  WHERE \(TokenAccounting.missingComponentsSQL)
                    AND ts >= ? AND ts <= ? AND (model IS NULL OR model != '<synthetic>'))
                """, arguments: [nowMs - Int64(Self.currentWindow * 1_000), nowMs]) ?? false
            return (samples: samples, missingCreation: missingCreation)
        }
        async let outputResult = Self.authorizedOutputSamples(sinceMs: historyStartMs, beforeMs: nowMs)
        async let balanceResult = AppDatabase.shared.read { db in
            try BalanceObservation.fetchBalanceDeltas(in: db, sinceMs: historyStartMs, beforeMs: nowMs)
        }
        async let quotaResult = StatsService.latestQuotaStatus()

        let (usageData, outputSamples, balanceDeltas, quotaItems) = try await (
            usageResult, outputResult, balanceResult, quotaResult)

        let activity = Self.rateSignal(
            kind: .activity, samples: usageData.samples, unit: "tokens/h",
            completeness: usageData.missingCreation ? .partial : .complete, now: now,
            ratioReason: "token_rate", fallbackReason: "recent_token_activity")

        var moneySamples: [PulseSample] = []
        var sawUnconvertedMoney = false
        for delta in balanceDeltas {
            guard let conversion = StatsService.semanticUSDConversion(currency: delta.currency) else {
                sawUnconvertedMoney = true
                continue
            }
            moneySamples.append(PulseSample(
                timestamp: Date(timeIntervalSince1970: Double(delta.ts) / 1_000),
                value: delta.nativeAmount * conversion.rate))
        }
        let money = Self.rateSignal(
            kind: .observedSpend, samples: moneySamples, unit: "USD/h",
            completeness: sawUnconvertedMoney ? .partial : .intervalNet, now: now,
            ratioReason: "observed_spend", fallbackReason: "recent_observed_spend")

        let quota = Self.quotaSignal(items: quotaItems, now: now)
        let output = Self.rateSignal(
            kind: .attributedOutput, samples: outputSamples, unit: "lines/h",
            completeness: .partial, now: now,
            ratioReason: "attributed_output", fallbackReason: "recent_attributed_output")

        return Self.buildSnapshot(signals: [activity, money, quota, output], now: now)
    }

    static func buildSnapshot(signals: [PulseSignal], now: Date = Date()) -> PulseSnapshot {
        let eligible = signals.filter {
            $0.freshness != .stale && $0.freshness != .unavailable &&
                $0.normalized.isFinite && $0.normalized > 0 &&
                ($0.observedAt.map { $0 <= now } ?? true)
        }
        let direct = eligible.filter { $0.kind != .attributedOutput }
        // Output is a fallback for missing direct activity, not a competing
        // claim that a large commit implies more AI consumption.
        let primary = (direct.isEmpty ? eligible : direct).max { lhs, rhs in lhs.normalized < rhs.normalized }
        let score = primary?.normalized ?? 0
        return PulseSnapshot(
            tier: tier(score: score),
            primarySignal: primary?.kind,
            reason: primary?.reason ?? "no_recent_signal",
            signals: signals,
            asOf: now)
    }

    static func tier(score: Double) -> PulseTier {
        guard score.isFinite, score >= 0.15 else { return .resting }
        if score < 1.5 { return .active }
        if score < 3.0 { return .elevated }
        return .intense
    }

    /// Exponential weighting makes the signal move immediately and decay even
    /// when no new rows arrive. The coordinator's 30-second pulse tick causes
    /// consumers to re-evaluate this pure time-based value.
    static func decayedHourlyRate(samples: [PulseSample], now: Date) -> Double {
        let scale = 3_600 / halfLife
        return samples.reduce(0) { total, sample in
            let age = now.timeIntervalSince(sample.timestamp)
            guard age >= 0, age <= currentWindow, sample.value.isFinite, sample.value > 0 else {
                return total
            }
            return total + sample.value * pow(0.5, age / halfLife) * scale
        }
    }

    /// Median non-empty historical hour. The current hour is excluded so a
    /// spike cannot raise its own comparison baseline.
    static func recentBaseline(samples: [PulseSample], now: Date) -> Double? {
        let currentHour = Int64(now.timeIntervalSince1970 / 3_600)
        var buckets: [Int64: Double] = [:]
        for sample in samples where sample.value.isFinite && sample.value > 0 {
            let hour = Int64(sample.timestamp.timeIntervalSince1970 / 3_600)
            guard hour < currentHour else { continue }
            buckets[hour, default: 0] += sample.value
        }
        let sorted = buckets.values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    static func rateSignal(
        kind: PulseSignalKind,
        samples: [PulseSample],
        unit: String,
        completeness: PulseCompleteness,
        now: Date,
        ratioReason: String,
        fallbackReason: String
    ) -> PulseSignal {
        let latest = samples.filter { $0.timestamp <= now && $0.value > 0 }.map(\.timestamp).max()
        let freshness = freshness(observedAt: latest, now: now, maxAge: currentWindow)
        let rate = decayedHourlyRate(samples: samples, now: now)
        let baseline = recentBaseline(samples: samples, now: now)
        let score: Double
        let reason: String
        if rate <= 0 || freshness == .stale || freshness == .unavailable {
            score = 0
            reason = "no_recent_\(kind.rawValue)"
        } else if let baseline, baseline > 0 {
            score = min(rate / baseline, 8)
            reason = "\(ratioReason)_\(ratioText(score))x"
        } else {
            let age = latest.map { now.timeIntervalSince($0) } ?? currentWindow
            let recency = pow(0.5, max(age, 0) / halfLife)
            let coldRatio = min(rate / coldStartBaseline(for: kind), 8)
            // Any fresh activity produces a modest beat, while a genuinely
            // large cold-start session can still become intense without a
            // pricing catalog or accumulated personal history.
            score = max(0.5 * recency, coldRatio)
            reason = coldRatio >= 0.5 * recency
                ? "\(ratioReason)_cold_start_\(ratioText(coldRatio))x"
                : fallbackReason
        }
        return PulseSignal(
            kind: kind,
            rawValue: rate > 0 ? rate : nil,
            unit: unit,
            baseline: baseline,
            normalized: score,
            freshness: freshness,
            completeness: completeness,
            observedAt: latest,
            reason: reason)
    }

    static func quotaSignal(items: [QuotaStatusItem], now: Date) -> PulseSignal {
        let usable = items.filter { !$0.isStale(asOf: now, maxAge: quotaMaxAge) }
        guard let strongest = usable.max(by: { $0.utilization < $1.utilization }) else {
            return PulseSignal(
                kind: .quota, rawValue: nil, unit: "percent", baseline: 100,
                normalized: 0, freshness: items.isEmpty ? .unavailable : .stale,
                completeness: .providerWindow,
                observedAt: items.compactMap { $0.updatedAt }.max().map(Date.init(timeIntervalSince1970:)),
                reason: "quota_unavailable_or_stale")
        }
        let utilization = min(max(strongest.utilization, 0), 100)
        let score: Double
        if utilization >= 95 { score = 3.5 }
        else if utilization >= 80 { score = 2.0 }
        else { score = 0 }
        return PulseSignal(
            kind: .quota, rawValue: utilization, unit: "percent", baseline: 100,
            normalized: score,
            freshness: freshness(
                observedAt: strongest.updatedAt.map(Date.init(timeIntervalSince1970:)),
                now: now, maxAge: quotaMaxAge),
            completeness: .providerWindow,
            observedAt: strongest.updatedAt.map(Date.init(timeIntervalSince1970:)),
            reason: "quota_\(Int(utilization.rounded()))_percent")
    }

    static func freshness(observedAt: Date?, now: Date, maxAge: TimeInterval) -> PulseFreshness {
        guard let observedAt else { return .unavailable }
        let age = now.timeIntervalSince(observedAt)
        guard age >= 0 else { return .fresh }
        if age <= min(freshAge, maxAge) { return .fresh }
        if age <= maxAge { return .aging }
        return .stale
    }

    private static func ratioText(_ ratio: Double) -> String {
        String(format: "%.1f", ratio).replacingOccurrences(of: ".", with: "_")
    }

    private static func coldStartBaseline(for kind: PulseSignalKind) -> Double {
        switch kind {
        case .activity: return 20_000       // tokens/h
        case .observedSpend: return 1       // observed USD/h
        case .attributedOutput: return 200  // attributed changed lines/h
        case .quota: return 100             // provider capacity
        }
    }

    /// Only recognized commit trailers in authorized Git roots may act as an
    /// output fallback. Historical editor proximity is not AI authorship.
    private static func authorizedOutputSamples(sinceMs: Int64, beforeMs: Int64) async throws -> [PulseSample] {
        let rows = try await AppDatabase.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.ts, c.repo_path, c.added, c.deleted, g.attributed_tool
                FROM code_change c JOIN git_commit g
                  ON g.repo_path = c.repo_path AND g.commit_hash = c.commit_hash
                WHERE c.is_merge = 0 AND c.ts >= ? AND c.ts <= ?
                  AND g.attributed_tool IS NOT NULL
                """, arguments: [sinceMs, beforeMs]).map { row in
                (ts: row["ts"] as Int64? ?? 0, path: row["repo_path"] as String? ?? "",
                 added: row["added"] as Int? ?? 0, deleted: row["deleted"] as Int? ?? 0,
                 tool: row["attributed_tool"] as String? ?? "")
            }
        }
        let roots = RepositoryScope.configuredRoots()
        var buckets: [Int64: (ts: Int64, value: Double)] = [:]
        for row in rows {
            guard RepositoryScope.authorizedGitRoot(for: row.path, roots: roots) != nil,
                  GitMonitor.canonicalAttributedTool(row.tool) != nil else { continue }
            let key = row.ts / 300_000
            let previous = buckets[key] ?? (0, 0)
            buckets[key] = (max(previous.ts, row.ts), previous.value + Double(max(row.added, 0) + max(row.deleted, 0)))
        }
        return buckets.values.map { PulseSample(timestamp: Date(timeIntervalSince1970: Double($0.ts) / 1_000), value: $0.value) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    static func usageSamples(in db: Database, sinceMs: Int64, beforeMs: Int64) throws -> [PulseSample] {
        try Row.fetchAll(db, sql: """
            SELECT MAX(ts) AS observed_at,
                   COALESCE(SUM(\(TokenAccounting.observedTotalSQL)), 0) AS value
            FROM usage_event WHERE ts >= ? AND ts <= ?
              AND (model IS NULL OR model != '<synthetic>')
            GROUP BY CAST(ts / 300000 AS INTEGER) ORDER BY observed_at
            """, arguments: [sinceMs, beforeMs]).compactMap { row in
            let ts: Int64 = row["observed_at"] ?? 0
            let value: Double = row["value"] ?? 0
            guard ts > 0, value.isFinite, value > 0 else { return nil }
            return PulseSample(
                timestamp: Date(timeIntervalSince1970: Double(ts) / 1_000),
                value: value)
        }
    }
}
