import Foundation
import GRDB
import AIPulseShared

/// A unit-free token-activity tier, not an amount of money or remaining quota.
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

/// Only observed token activity drives the naturally decaying pulse.
/// Money, quota and local Git output are independent context, not heartbeats.
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
    static let referenceHourlyTokens: Double = 20_000
    static let cacheTTL: TimeInterval = 15
    static let minimumBaselineHours = 8
    static let minimumBaselineDays = 3

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

        let usageData = try await AppDatabase.shared.read { db in
            let samples = try Self.usageSamples(in: db, sinceMs: historyStartMs, beforeMs: nowMs)
            let missingCreation = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM usage_event
                  WHERE \(TokenAccounting.missingComponentsSQL)
                    AND ts >= ? AND ts <= ? AND (model IS NULL OR model != '<synthetic>'))
                """, arguments: [nowMs - Int64(Self.currentWindow * 1_000), nowMs]) ?? false
            let facts = try Self.activityFacts(in: db, now: now)
            return (samples: samples, missingCreation: missingCreation, facts: facts)
        }

        let activity = Self.rateSignal(
            kind: .activity, samples: usageData.samples, unit: "tokens/h",
            completeness: usageData.missingCreation ? .partial : .complete, now: now,
            ratioReason: "token_rate", fallbackReason: "recent_token_activity")

        var result = Self.buildSnapshot(signals: [activity], now: now)
        result.activityFacts = usageData.facts
        return result
    }

    static func buildSnapshot(signals: [PulseSignal], now: Date = Date()) -> PulseSnapshot {
        let eligible = signals.filter {
            $0.kind == .activity && $0.freshness != .stale && $0.freshness != .unavailable &&
                $0.normalized.isFinite && $0.normalized > 0 &&
                ($0.observedAt.map { $0 <= now } ?? true)
        }
        let primary = eligible.max { lhs, rhs in lhs.normalized < rhs.normalized }
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
        // Normalize the exponential kernel: a constant 20K/h flow gives 20K/h,
        // not an arbitrary 6x amplification. Still a smoothed index, not a bill.
        let effectiveSeconds = halfLife / log(2) * (1 - pow(0.5, currentWindow / halfLife))
        let scale = 3_600 / effectiveSeconds
        return samples.reduce(0) { total, sample in
            let age = now.timeIntervalSince(sample.timestamp)
            guard age >= 0, age <= currentWindow, sample.value.isFinite, sample.value > 0 else {
                return total
            }
            return total + sample.value * pow(0.5, age / halfLife) * scale
        }
    }

    /// Median historical active hour, with at least eight hours on three UTC
    /// days. Entire hours overlapping the live window are excluded.
    static func recentBaseline(samples: [PulseSample], now: Date) -> Double? {
        let historyCutoff = now.addingTimeInterval(-currentWindow)
        let cutoffHour = Int64(historyCutoff.timeIntervalSince1970 / 3_600)
        var buckets: [Int64: Double] = [:]
        for sample in samples where sample.value.isFinite && sample.value > 0 {
            let hour = Int64(sample.timestamp.timeIntervalSince1970 / 3_600)
            guard hour < cutoffHour,
                  sample.timestamp >= now.addingTimeInterval(-Double(baselineDays) * 86_400) else { continue }
            buckets[hour, default: 0] += sample.value
        }
        let sorted = buckets.values.filter { $0 > 0 }.sorted()
        let days = Set(buckets.keys.map { $0 / 24 })
        guard sorted.count >= minimumBaselineHours, days.count >= minimumBaselineDays else { return nil }
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
        let latest = samples.filter { $0.timestamp <= now && $0.value.isFinite && $0.value > 0 }.map(\.timestamp).max()
        let freshness = freshness(observedAt: latest, now: now, maxAge: currentWindow)
        let rate = decayedHourlyRate(samples: samples, now: now)
        let baseline = recentBaseline(samples: samples, now: now)
        let score: Double
        let reason: String
        if rate <= 0 || freshness == .stale || freshness == .unavailable {
            score = 0
            reason = "no_recent_\(kind.rawValue)"
        } else if let baseline, baseline > 0 {
            let ratio = rate / baseline
            let age = latest.map { now.timeIntervalSince($0) } ?? currentWindow
            let recentBeat = 0.5 * pow(0.5, max(age, 0) / halfLife)
            score = min(max(min(ratio, 8), recentBeat), 8 * pow(0.5, max(age, 0) / halfLife))
            reason = ratio >= recentBeat ? "\(ratioReason)_\(ratioText(ratio))x" : fallbackReason
        } else {
            let age = latest.map { now.timeIntervalSince($0) } ?? currentWindow
            let recency = pow(0.5, max(age, 0) / halfLife)
            let coldRatio = min(rate / referenceHourlyTokens, 8)
            // Any fresh activity produces a modest beat, while a genuinely
            // large cold-start session can still become intense without a
            // pricing catalog or accumulated personal history.
            score = min(max(0.5 * recency, coldRatio), 8 * recency)
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

    static func freshness(observedAt: Date?, now: Date, maxAge: TimeInterval) -> PulseFreshness {
        guard let observedAt else { return .unavailable }
        let age = now.timeIntervalSince(observedAt)
        guard age >= 0 else { return .unavailable }
        if age <= min(freshAge, maxAge) { return .fresh }
        if age <= maxAge { return .aging }
        return .stale
    }

    private static func ratioText(_ ratio: Double) -> String {
        String(format: "%.1f", ratio).replacingOccurrences(of: ".", with: "_")
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

    static func activityFacts(in db: Database, now: Date, calendar: Calendar = .current) throws -> PulseActivityFacts {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let todayMs = Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1_000)
        let recentMs = nowMs - 600_000
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(CASE WHEN ts >= ? THEN \(TokenAccounting.observedTotalSQL) ELSE 0 END), 0) AS recent,
                   COALESCE(SUM(CASE WHEN ts >= ? THEN \(TokenAccounting.observedTotalSQL) ELSE 0 END), 0) AS today,
                   COALESCE(MAX(CASE WHEN \(TokenAccounting.missingComponentsSQL) THEN 1 ELSE 0 END), 0) AS partial
            FROM usage_event WHERE ts >= ? AND ts <= ?
              AND (model IS NULL OR model != '<synthetic>')
            """, arguments: [recentMs, todayMs, min(recentMs, todayMs), nowMs])
        return PulseActivityFacts(recentTokens: row?["recent"] ?? 0,
                                  todayTokens: row?["today"] ?? 0,
                                  isPartial: (row?["partial"] as Int? ?? 0) != 0)
    }
}
