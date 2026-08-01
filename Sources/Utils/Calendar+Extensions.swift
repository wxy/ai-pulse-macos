import Foundation

extension Calendar {
    /// Monday of the ISO week containing `date` (defaults to today).
    /// nonisolated: callable from any queue, including Task.detached(priority: .background)
    /// in DataRefreshCoordinator.runPhase4.
    static nonisolated func mondayOfWeek(for date: Date = Date()) -> Date {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                  from: date))!
    }
}
