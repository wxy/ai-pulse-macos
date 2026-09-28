import XCTest
@testable import AIPulse

/// The old quiet-hours fields were free-text: "9am" persisted verbatim and
/// CoinSound silently ignored it, disabling the window. The DatePicker writes
/// normalized "HH:mm" strings; these tests pin the migration behavior for
/// values stored by the old field.
final class QuietHoursFormattingTests: XCTestCase {
    private func minutes(_ date: Date) -> (hour: Int, minute: Int) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0, components.minute ?? 0)
    }

    func testValidStoredValueIsHonored() {
        let date = NotificationsTab.quietTime(defaultHour: 22, stored: "06:30")
        let parsed = minutes(date)
        XCTAssertEqual(parsed.hour, 6)
        XCTAssertEqual(parsed.minute, 30)
    }

    func testLegacyBadValueFallsBackToDefaultHour() {
        for bad in ["9am", "24:00", "", "abc"] {
            let date = NotificationsTab.quietTime(defaultHour: 22, stored: bad)
            XCTAssertEqual(minutes(date).hour, 22, "'\(bad)' must show the standard window")
            XCTAssertEqual(minutes(date).minute, 0)
        }
    }

    func testMissingStoredValueUsesDefaultHour() {
        let date = NotificationsTab.quietTime(defaultHour: 8, stored: nil)
        XCTAssertEqual(minutes(date).hour, 8)
        XCTAssertEqual(minutes(date).minute, 0)
    }

    func testPickerDateRoundTripsThroughStorageFormat() {
        for (hour, minute) in [(0, 0), (8, 5), (22, 0), (23, 59)] {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            components.hour = hour
            components.minute = minute
            let date = Calendar.current.date(from: components)!

            let stored = NotificationsTab.quietString(date)
            XCTAssertEqual(stored, String(format: "%02d:%02d", hour, minute))

            let reparsed = NotificationsTab.quietTime(defaultHour: 22, stored: stored)
            let parsed = minutes(reparsed)
            XCTAssertEqual(parsed.hour, hour)
            XCTAssertEqual(parsed.minute, minute)
        }
    }
}
