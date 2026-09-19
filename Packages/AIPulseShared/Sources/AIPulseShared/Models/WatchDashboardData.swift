import Foundation

public enum WatchDashboardData {
    public static let summaryFreshnessInterval: TimeInterval = 15 * 60

    public static func isSummaryFresh(_ snapshot: DashboardSnapshot?, now: Date = Date()) -> Bool {
        guard let snapshot else { return false }
        let age = now.timeIntervalSince(snapshot.updatedAt)
        return age.isFinite && age >= -60 && age <= summaryFreshnessInterval
    }

    /// Estimate from observed active days only: absent days are not confirmed zeros.
    public static func baseline(_ snapshot: DashboardSnapshot?, tokens: Bool, now: Date = Date()) -> Double? {
        guard let snapshot, PhoneDashboardData.accepts(snapshot, range: "30d"),
              !snapshot.readFailures.contains(tokens ? "dashboardUsageStats" : "dashboardCodeChanges") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: snapshot.period.timeZoneIdentifier) ?? .gmt
        let end = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -28, to: end) else { return nil }
        var days: [Date: Double] = [:]
        for point in tokens ? snapshot.dailyStats : snapshot.codeChanges {
            guard point.ts.isFinite else { continue }
            let date = Date(timeIntervalSince1970: point.ts)
            guard date >= start, date < end, date >= snapshot.period.start, date < snapshot.period.end else { continue }
            let value = tokens ? Double(point.tokens) : Double(point.added) + Double(point.deleted)
            guard value.isFinite, value > 0 else { continue }
            days[calendar.startOfDay(for: date), default: 0] += value
        }
        let values = days.values.sorted()
        guard values.count >= 7 else { return nil }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? values[middle - 1] / 2 + values[middle] / 2 : values[middle]
    }

    public static func ratio(value: Double?, baseline: Double?) -> Double? {
        guard let value, let baseline, value.isFinite, value >= 0,
              baseline.isFinite, baseline > 0 else { return nil }
        let result = value / baseline
        return result.isFinite ? result : nil
    }

    public static func intensity(_ pulse: PulseSnapshot?, now: Date = Date()) -> Double? {
        guard let pulse, pulse.isCurrent(asOf: now), let signal = pulse.activity,
              signal.freshness != .stale, signal.freshness != .unavailable,
              signal.normalized.isFinite, signal.normalized >= 0 else { return nil }
        // PulseEngine's intense tier starts at score 3; this is not a usage quota.
        return min(1, signal.normalized / 3)
    }

    public static func timelineTransitionDates(
        todaySnapshot: DashboardSnapshot?,
        pulse: PulseSnapshot?,
        now: Date,
        nextRefresh: Date
    ) -> [Date] {
        guard nextRefresh > now else { return [] }
        var dates: [Date] = []
        if let pulse { dates.append(pulse.validUntil) }
        if let snapshot = todaySnapshot {
            dates.append(snapshot.updatedAt.addingTimeInterval(summaryFreshnessInterval + 1))
            dates.append(snapshot.period.end)
        }
        return Set(dates).filter { $0 > now && $0 < nextRefresh }.sorted()
    }

    public static func remainingArc(_ ratio: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 0 }
        return ratio >= 1 ? ratio.truncatingRemainder(dividingBy: 1) : ratio
    }
}
