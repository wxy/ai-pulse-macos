import CloudKit
import UserNotifications
import AVFoundation
import os

/// Manages CloudKit subscription push + local notifications.
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    private let database = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase
    private static let log = Logger(subsystem: "com.wxy.aipulse", category: "Notify")
    private static var audioPlayer: AVAudioPlayer?
    private static var lastSoundTime: Date = .distantPast

    /// Whether the user has notification sounds enabled in iOS Settings.
    static var notificationSoundEnabled = true

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Sound playback

    /// Play coin sound scaled to the spend delta. Respects notification setting + 60s throttle.
    /// - Parameter delta: absolute cost change since last known value.
    static func playCoinSound(for delta: Double) {
        guard notificationSoundEnabled else {
            log.debug("playCoinSound: skipped — notification sound disabled in Settings")
            return
        }
        guard delta > 0.01 else {
            log.debug("playCoinSound: skipped — delta \(String(format: "%.3f", delta)) too small")
            return
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSoundTime)
        guard elapsed >= 60 else {
            log.debug("playCoinSound: throttled — last was \(String(format: "%.0f", elapsed))s ago")
            return
        }
        lastSoundTime = now

        let name = delta >= 1.00 ? "coins" : "coin"
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            log.error("playCoinSound: \(name).mp3 not found in bundle")
            return
        }
        log.debug("playCoinSound: loading \(url.lastPathComponent) (delta: \(String(format: "%.2f", delta)))")
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            log.error("playCoinSound: AVAudioPlayer init failed for \(name).mp3")
            return
        }
        audioPlayer = player
        player.play()
        log.info("playCoinSound: playing \(name).mp3 (duration: \(String(format: "%.2f", player.duration))s)")
    }

    /// Refresh the cached notification sound setting.
    static func refreshSoundSetting() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let enabled = settings.soundSetting == .enabled
        if enabled != notificationSoundEnabled {
            log.info("refreshSoundSetting: sound \(enabled ? "enabled" : "disabled")")
        }
        notificationSoundEnabled = enabled
    }

    // MARK: - Setup

    /// Request notification permission and register CloudKit subscription.
    /// Called once, serially, before any other CloudKit call at launch —
    /// see `CloudKitGate` for why bursts of concurrent CK/APNs traffic at
    /// launch must be avoided on some devices (e.g. iPhone SE 2nd gen).
    func setup() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                await registerSubscription()
                await registerSpendAlertSubscription()
            }
        } catch {
            print("[Notify] permission error: \(error)")
        }
        await NotificationService.refreshSoundSetting()
    }

    // MARK: - Push handling

    private var lastKnownCost: Double = 0

    /// Handle remote push: fetch updated data without changing the user's
    /// currently-displayed time-range tab. Previously fetchSnapshot() defaulted
    /// to "today", which would overwrite whatever tab the user was viewing.
    func didReceiveRemoteNotification() {
        Self.log.info("didReceiveRemoteNotification: push arrived")
        let oldCost = CloudDataService.shared.snapshot?.todayCost ?? lastKnownCost
        let currentRange = CloudDataService.shared.currentRange
        Task {
            // Fetch today only (fast) for cost comparison + sound.
            // Do NOT switch the displayed tab — just update the cache.
            await CloudDataService.shared.fetchAndStore(range: "today")
            // Reload the current range so the UI reflects any changes
            // without switching to a different tab.
            CloudDataService.shared.loadSnapshot(for: currentRange)
            let newCost = CloudDataService.shared.snapshot?.todayCost ?? 0
            let delta = abs(newCost - oldCost)

            if delta > 0.01 {
                NotificationService.playCoinSound(for: delta)
            }

            if newCost > 0.001, delta > 0.01 {
                lastKnownCost = newCost

                let content = UNMutableNotificationContent()
                content.title = I18n.t("notify.title")
                content.body = String(format: I18n.t("notify.body"), newCost)
                content.sound = nil       // silent — coin sound already played above
                content.badge = 1
                content.interruptionLevel = .timeSensitive
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "cost-update", content: content, trigger: nil))
            }

            await checkSpendAlert()
        }
    }

    // MARK: - Private

    /// Cached locally once confirmed registered so subsequent launches skip
    /// the CloudKit round trip entirely — previously this ran on *every*
    /// launch (an `allSubscriptions()` fetch, plus occasionally a save),
    /// adding an extra network op to the launch burst forever.
    private static let subscriptionRegisteredKey = "ck_subscription_registered_v1"

    private func registerSubscription() async {
        if UserDefaults.standard.bool(forKey: Self.subscriptionRegisteredKey) { return }
        do {
            try await CloudKitGate.shared.run("ck-subscription-register") {
                let subs = try await self.database.allSubscriptions()
                if subs.contains(where: { $0.subscriptionID == CKSchema.Subscription.dashboardChanges }) {
                    UserDefaults.standard.set(true, forKey: Self.subscriptionRegisteredKey)
                    return
                }

                let predicate = NSPredicate(value: true)
                let subscription = CKQuerySubscription(
                    recordType: CKSchema.recordType,
                    predicate: predicate,
                    subscriptionID: CKSchema.Subscription.dashboardChanges,
                    options: [.firesOnRecordCreation, .firesOnRecordUpdate]
                )
                let notification = CKSubscription.NotificationInfo()
                notification.shouldSendContentAvailable = true  // silent push — triggers background refresh
                subscription.notificationInfo = notification

                _ = try await self.database.save(subscription)
                UserDefaults.standard.set(true, forKey: Self.subscriptionRegisteredKey)
                print("[Notify] subscription registered")
            }
        } catch {
            print("[Notify] subscription failed: \(error)")
        }
    }

    // MARK: - Spend alerts

    private static let spendAlertSubscriptionRegisteredKey = "ck_spend_alert_subscription_registered_v1"
    private static let lastAlertEventIdKey = "ck_spend_alert_last_event_id"

    private func registerSpendAlertSubscription() async {
        if UserDefaults.standard.bool(forKey: Self.spendAlertSubscriptionRegisteredKey) { return }
        do {
            try await CloudKitGate.shared.run("ck-spend-alert-subscription-register") {
                let subs = try await self.database.allSubscriptions()
                if subs.contains(where: { $0.subscriptionID == CKSchema.SpendAlert.Subscription.changes }) {
                    UserDefaults.standard.set(true, forKey: Self.spendAlertSubscriptionRegisteredKey)
                    return
                }

                let subscription = CKQuerySubscription(
                    recordType: CKSchema.SpendAlert.recordType,
                    predicate: NSPredicate(value: true),
                    subscriptionID: CKSchema.SpendAlert.Subscription.changes,
                    options: [.firesOnRecordCreation, .firesOnRecordUpdate]
                )
                let notification = CKSubscription.NotificationInfo()
                notification.shouldSendContentAvailable = true
                subscription.notificationInfo = notification

                _ = try await self.database.save(subscription)
                UserDefaults.standard.set(true, forKey: Self.spendAlertSubscriptionRegisteredKey)
                print("[Notify] spend-alert subscription registered")
            }
        } catch {
            print("[Notify] spend-alert subscription failed: \(error)")
        }
    }

    private func checkSpendAlert() async {
        do {
            let recordID = CKRecord.ID(recordName: CKSchema.SpendAlert.recordName)
            let record = try await database.record(for: recordID)
            guard let json = record[CKSchema.SpendAlert.Field.json] as? String,
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(SpendAlertPayload.self, from: data)
            else { return }

            let lastEventId = UserDefaults.standard.string(forKey: Self.lastAlertEventIdKey)
            guard payload.eventId != lastEventId else { return }
            UserDefaults.standard.set(payload.eventId, forKey: Self.lastAlertEventIdKey)

            let content = UNMutableNotificationContent()
            content.title = I18n.t("alert.l\(payload.level).title")
            content.body = alertBody(payload)
            content.sound = .default
            content.interruptionLevel = .timeSensitive

            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "spend-alert-\(payload.eventId)",
                    content: content,
                    trigger: nil))
        } catch {
            Self.log.warning("checkSpendAlert failed: \(error.localizedDescription)")
        }
    }

    private func alertBody(_ payload: SpendAlertPayload) -> String {
        let amount = String(format: "$%.2f", payload.amountUsd)
        if let baseline = payload.baselineUsd {
            return String(format: I18n.t("alert.spend_rate.body"),
                          amount, String(format: "$%.2f", baseline))
        }
        return String(format: I18n.t("alert.balance_drop.body"), amount)
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
