import Foundation

public enum DashboardPeriodKind: String, Codable, Sendable, CaseIterable {
    case today
    case week
    case days30 = "30d"
}

/// Explicit query boundaries and display resolution. Monday's week is still
/// a daily series, not Today's hourly series, even though both span one day.
public struct DashboardPeriod: Codable, Sendable, Equatable {
    public let kind: DashboardPeriodKind
    public let start: Date
    public let end: Date
    public let timeZoneIdentifier: String
    public let calendarIdentifier: String
    public let elapsedDays: Int
    public let displaySlots: Int
    public var isHourly: Bool { kind == .today }

    public init(kind: DashboardPeriodKind, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        self.kind = kind
        end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        switch kind {
        case .today:
            start = today
            displaySlots = 24
        case .week:
            let daysSinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
            start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
            displaySlots = 7
        case .days30:
            start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            displaySlots = 30
        }
        elapsedDays = max(1, (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1)
        timeZoneIdentifier = calendar.timeZone.identifier
        calendarIdentifier = String(describing: calendar.identifier)
    }
}
