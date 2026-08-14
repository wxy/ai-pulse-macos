import Foundation

/// App-level master switch for all system notifications. This is independent
/// from the macOS system permission: even when notifications are authorized,
/// turning this off stops AI Pulse from posting local notifications.
enum SystemNotifications {
    static let enabledKey = "system_notifications_enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}
