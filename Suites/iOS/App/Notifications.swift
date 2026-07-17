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

    // MARK: - Push handling

    private var lastKnownCost: Double = 0

    /// Handle remote push: fetch → compare cost delta → play sound if changed → notify.
    func didReceiveRemoteNotification() {
        Self.log.info("didReceiveRemoteNotification: push arrived")
        let oldCost = CloudDataService.shared.snapshot?.todayCost ?? lastKnownCost
        Task {
            try? await CloudDataService.shared.fetchSnapshot()
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
        }
    }

    // MARK: - Private

    private func registerSubscription() async {
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
        [.banner]
    }
}
