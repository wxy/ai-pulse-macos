import AppKit
import UserNotifications

// Menu-bar-only app. main.swift sets .accessory BEFORE NSApp.run() and
// calls activate() after a short delay to prevent the race where the
// system ignores the status item.

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try AppDatabase.shared.setup() }
        catch { print("DB setup failed: \(error)") }

        menuBarController = MenuBarController()
        menuBarController?.start()

        // Auto-enable integrations that are detected on first launch
        migrateIntegrationDefaults()
        // Start all enabled, detected integrations via the registry
        IntegrationRegistry.startAllEnabled()

        // Request notification permission (only works in .app bundle, not bare binary)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        // Check for anomalies after each poll cycle
        Timer.scheduledTimer(withTimeInterval: 3660, repeats: true) { _ in
            Task { await AnomalyDetector.shared.check() }
        }

        // Extra activation after menu bar setup (belt-and-suspenders with main.swift)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        IntegrationRegistry.stopAll()
    }

    /// On first launch, auto-enable integrations that have data detected.
    /// This provides backward compatibility for users who already have logs/keys.
    private func migrateIntegrationDefaults() {
        let migratedKey = "integration_defaults_migrated"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        UserDefaults.standard.set(true, forKey: migratedKey)

        for i in IntegrationRegistry.all {
            // Enable A-grade if detected (logs exist); B-grade if key configured
            if i.detect().found {
                var cfg = IntegrationRegistry.config(for: i.id)
                cfg.enabled = true
                IntegrationRegistry.setConfig(for: i.id, cfg)
            }
        }
    }
}
