import Foundation

/// Validation and chart projection shared by the phone's network and cache paths.
public enum PhoneDashboardData {
    public static func accepts(_ snapshot: DashboardSnapshot, range: String) -> Bool {
        snapshot.version == 2 && snapshot.payloadVersion == CKSchema.payloadVersion
            && snapshot.period.kind.rawValue == range
    }

    public static func rhythm(_ points: [TrendPoint], period: DashboardPeriod, tokens: Bool) -> [Double] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: period.timeZoneIdentifier) ?? .gmt
        var slots = Array(repeating: 0.0, count: period.displaySlots)
        for point in points {
            let date = Date(timeIntervalSince1970: point.ts)
            guard date >= period.start, date < period.end else { continue }
            let slot = period.isHourly ? calendar.component(.hour, from: date)
                : calendar.dateComponents([.day], from: period.start, to: calendar.startOfDay(for: date)).day ?? -1
            guard slots.indices.contains(slot) else { continue }
            slots[slot] += max(0, tokens ? Double(point.tokens) : Double(point.added + point.deleted))
        }
        return period.kind == .week ? Array(repeating: -1, count: 7) + slots + Array(repeating: -1, count: 7) : slots
    }

    /// Preserve proportions while keeping very small token components visible.
    public static func noseWidths(_ values: [Int64]) -> [Double] {
        let roots = values.map { Double(max(0, $0)) }
        let total = roots.reduce(0, +)
        guard total > 0 else { return values.map { _ in 1 / Double(max(1, values.count)) } }
        let floor = min(0.15, 1 / Double(max(1, values.count)))
        return roots.map { floor + (1 - floor * Double(values.count)) * $0 / total }
    }
}
