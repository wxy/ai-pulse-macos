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
    private static var lastCoinSoundTime: Date = .distantPast

    /// Whether the user has notification sounds enabled in iOS Settings.
    /// Defaults to true so we play the coin sound until we know the real setting.
    static var notificationSoundEnabled = true

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Play coin sound when app is in foreground and new data arrives.
    /// Throttled to once per minute. Respects the iOS notification sound setting.
    static func playCoinSound() {
        guard notificationSoundEnabled else {
            log.debug("playCoinSound: skipped — notification sound disabled in Settings")
            return
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastCoinSoundTime)
        guard elapsed >= 60 else {
            log.debug("playCoinSound: throttled — last was \(String(format: "%.0f", elapsed))s ago")
            return
        }
        lastCoinSoundTime = now

        guard let url = Bundle.main.url(forResource: "coin", withExtension: "mp3") else {
            log.error("playCoinSound: coin.mp3 not found in bundle")
            return
        }
        log.debug("playCoinSound: loading \(url.lastPathComponent)")
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            log.error("playCoinSound: AVAudioPlayer init failed")
            return
        }
        audioPlayer = player
        player.play()
        log.info("playCoinSound: playing (duration: \(String(format: "%.2f", player.duration))s)")
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

    /// Request notification permission and register CloudKit subscription.
    func setup() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                await registerSubscription()
            }
        } catch {
            print("[Notify] permission error: \(error)")
        }
        await NotificationService.refreshSoundSetting()
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
        Self.log.info("didReceiveRemoteNotification: push arrived, playing coin sound")
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
        // Show banner even when app is in foreground (no system sound — we play coin.mp3)
        [.banner]
    }
}
