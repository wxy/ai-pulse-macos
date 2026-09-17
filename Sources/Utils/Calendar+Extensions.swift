import Foundation

extension Calendar {
    /// Stable local-day identity shared by usage and Git activity buckets.
    nonisolated func localDayTimestamp(milliseconds: Int64) -> Int64 {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        return Int64(startOfDay(for: date).timeIntervalSince1970 * 1_000)
    }

    /// Monday of the ISO week containing `date` (defaults to today).
    /// nonisolated: callable from any queue, including Task.detached(priority: .background)
    /// in DataRefreshCoordinator.runPhase4.
    static nonisolated func mondayOfWeek(for date: Date = Date()) -> Date {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }
}
