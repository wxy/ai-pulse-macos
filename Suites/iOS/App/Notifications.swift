import CloudKit
import UserNotifications
import AudioToolbox

/// Manages CloudKit subscription push + local notifications.
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    private let database = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Play coin sound when app is in foreground and new data arrives.
    static func playCoinSound() {
        AudioServicesPlaySystemSound(1004)  // system coin-like sound
    }

    /// Request notification permission and register CloudKit subscription.
    func setup() async {
        // Request notification permission
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge])
            if granted {
                await registerSubscription()
            }
        } catch {
            print("[Notify] permission error: \(error)")
        }
    }

    private var lastNotifiedCost: Double = 0

    /// Send local notification only when today's cost actually changes.
    private func maybeNotify() {
        guard let today = CloudDataService.shared.snapshot?.todayCost,
              today > 0.001,
              abs(today - lastNotifiedCost) > 0.01 else { return }
        lastNotifiedCost = today

        let content = UNMutableNotificationContent()
        content.title = I18n.t("notify.title")
        content.body = String(format: I18n.t("notify.body"), today)
        content.badge = 1
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "cost-update", content: content, trigger: nil))
    }

    /// Handle remote push notification — refresh + coin sound + notify if changed.
    func didReceiveRemoteNotification() {
        NotificationService.playCoinSound()
        Task {
            try? await CloudDataService.shared.fetchSnapshot()
            maybeNotify()
        }
    }

    // MARK: - Private

    private func registerSubscription() async {
        // Check if already registered
        let subs = try? await database.allSubscriptions()
        if subs?.contains(where: { $0.subscriptionID == "dashboard-changes" }) == true { return }

        let predicate = NSPredicate(value: true)
        let subscription = CKQuerySubscription(
            recordType: "DashboardCache_v1",
            predicate: predicate,
            subscriptionID: "dashboard-changes",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let notification = CKSubscription.NotificationInfo()
        notification.shouldSendContentAvailable = true  // silent push — triggers background refresh
        subscription.notificationInfo = notification

        do {
            _ = try await database.save(subscription)
            print("[Notify] subscription registered")
        } catch {
            print("[Notify] subscription failed: \(error)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Show banner + sound even when app is in foreground
        [.banner]
    }
}
