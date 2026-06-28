import AppKit
import SwiftUI
import UserNotifications

// Menu-bar-only app. main.swift sets .accessory BEFORE NSApp.run() and
// calls activate() after a short delay to prevent the race where the
// system ignores the status item.

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set Dock icon immediately — must happen before .activate()
        NSApp.applicationIconImage = AppIconLoader.load()

        do { try AppDatabase.shared.setup() }
        catch { print("DB setup failed: \(error)") }

        menuBarController = MenuBarController()
        menuBarController?.start()

        // Auto-enable integrations that are detected on first launch
        migrateIntegrationDefaults()
        // Onboarding: show welcome page if first launch or no integrations enabled
        showOnboardingIfNeeded()
        // Start all enabled, detected integrations via the registry
        IntegrationRegistry.startAllEnabled()

        // P3: Dock fuel gauge
        DockManager.shared.start()

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
        DockManager.shared.stop()
    }

    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "onboarding_completed") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.openOnboarding()
        }
    }

    private func openOnboarding() {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "AI Pulse — Welcome"
        w.contentView = NSHostingView(rootView: OnboardingView())
        w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
        OnboardingWindowManager.shared.window = w
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
