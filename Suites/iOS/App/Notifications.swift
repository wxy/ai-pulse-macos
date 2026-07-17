import CloudKit
import UserNotifications

/// Manages CloudKit subscription push + local notifications.
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    private let database = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
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

    /// Handle remote push notification — refresh data + show local notification.
    func didReceiveRemoteNotification() {
        Task {
            try? await CloudDataService.shared.fetchSnapshot()
            await sendLocalNotification()
        }
    }

    private func sendLocalNotification() async {
        let snap = CloudDataService.shared.snapshot
        guard snap != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = I18n.t("notify.title")
        content.body = String(format: I18n.t("notify.body"), snap!.todayCost)
        content.badge = NSNumber(value: Int(snap!.todayCost * 100))
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)  // deliver immediately
        try? await UNUserNotificationCenter.current().add(request)
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
