import AppKit
import SwiftUI
import UserNotifications

// Menu-bar-only app. main.swift sets .accessory BEFORE NSApp.run() and
// calls activate() after a short delay to prevent the race where the
// system ignores the status item.

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?
    private var securityScopedURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set Dock icon immediately — must happen before .activate()
        NSApp.applicationIconImage = AppIconLoader.load()

        // Resolve security-scoped bookmarks for sandbox file access
        securityScopedURLs = BookmarkManager.resolveAll()

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

        // Proxy: auto-start if previously enabled (Developer ID only)
        if UserDefaults.standard.bool(forKey: "proxy_enabled") {
            startProxy()
        }

        // Check for anomalies after each poll cycle
        Timer.scheduledTimer(withTimeInterval: 3660, repeats: true) { _ in
            Task { await AnomalyDetector.shared.check() }
        }

        // Extra activation after menu bar setup (belt-and-suspenders with main.swift)
        NSApp.activate(ignoringOtherApps: true)
    }

    func startProxy() {
        do {
            try ProxyServer.shared.start()
            ProxyServer.shared.onEvent = { event in
                let ts = Int64(event.timestamp.timeIntervalSince1970 * 1000)
                Task {
                    do {
                        try await AppDatabase.shared.write { db in
                            try db.execute(sql: """
                                INSERT INTO proxy_event (ts, hostname, bytes_sent, bytes_received)
                                VALUES (?, ?, ?, ?)
                                """, arguments: [ts, event.hostname, event.bytesSent, event.bytesReceived])
                        }
                    } catch {
                        print("Proxy event insert failed: \(error)")
                    }
                }
            }
            UserDefaults.standard.set(true, forKey: "proxy_enabled")
        } catch {
            print("Proxy start failed: \(error)")
        }
    }

    func stopProxy() {
        ProxyServer.shared.stop()
        UserDefaults.standard.set(false, forKey: "proxy_enabled")
    }

    // Dock right-click → shared menu minus Quit, submenus are text-only copies
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let src = menuBarController?.menu else { return nil }
        let dock = NSMenu()
        for item in src.items {
            if item.keyEquivalent == "q" { continue }  // skip Quit (Dock has its own)
            if item.isSeparatorItem { dock.addItem(.separator()); continue }
            let copy = NSMenuItem(title: item.title, action: item.action, keyEquivalent: item.keyEquivalent)
            copy.target = item.target
            if let sub = item.submenu {
                let subCopy = NSMenu()
                for si in sub.items {
                    if si.isSeparatorItem { subCopy.addItem(.separator()); continue }
                    let siCopy = NSMenuItem(title: si.title, action: si.action, keyEquivalent: si.keyEquivalent)
                    siCopy.target = si.target
                    subCopy.addItem(siCopy)
                }
                copy.submenu = subCopy
            }
            dock.addItem(copy)
        }
        return dock
    }

    func applicationWillTerminate(_ notification: Notification) {
        IntegrationRegistry.stopAll()
        DockManager.shared.stop()
        BookmarkManager.stopAll(securityScopedURLs)
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
