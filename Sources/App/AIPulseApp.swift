import AppKit
import SwiftUI
import UserNotifications

/// Dock app. Shows Dashboard as the primary window. No menu bar icon.

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var securityScopedURLs: [URL] = []
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance: if another copy (same bundle id) is already running,
        // activate it and quit this one.
        if let bid = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0 != NSRunningApplication.current }
            if let other = others.first {
                other.activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
                return
            }
        }

        // Register defaults (fresh install values)
        UserDefaults.standard.register(defaults: ["coin_sound_enabled": true])

        // One-time libgit2 init (replaces per-call init/shutdown)
        GitRepo.setup()

        // Resolve security-scoped bookmarks for sandbox file access
        securityScopedURLs = BookmarkManager.resolveAll()
        Logger.debug("A: bookmarks resolved=\(self.securityScopedURLs.count)")

        do { try AppDatabase.shared.setup() }
        catch { Logger.error("DB setup failed: \(error)") }

        // Build shared menu (stats refreshed every 30s, used by Dock right-click)
        menuBarController = MenuBarController()
        menuBarController?.start()

        // Auto-enable integrations that are detected on first launch
        migrateIntegrationDefaults()
        // Onboarding: show welcome page if first launch or no integrations enabled
        showOnboardingIfNeeded()
        // Start all enabled, detected integrations via the registry
        IntegrationRegistry.startAllEnabled()
        Logger.debug("integrations started, A-grade=\(IntegrationRegistry.enabledAGrade().count) B-grade=\(IntegrationRegistry.enabledBGrade().count) C-grade=\(IntegrationRegistry.enabledCGrade().count)")
        // Git/repo + Claude log monitoring is independent of which integrations are
        // enabled: it must run whenever the user has authorized repo directories or
        // ~/.claude. LogWatcher.start() is safe to call again (idempotent scans).
        LogWatcher.shared.start()
        Logger.debug("LogWatcher started")
        // P3: Dock fuel gauge
        DockManager.shared.start()

        // Dashboard opens on Dock click or Cmd+Tab — not auto-launched

        // Request notification permission (only works in .app bundle, not bare binary)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        // Centralized data refresh coordinator (replaces scattered timers).
        // Manages three ingestion phases — Ingest (30s), Git (5min), Balance (1h) —
        // with change detection, 500ms debounce, and unified .dataDidChange notification.
        DataRefreshCoordinator.shared.start()

        // Check for anomalies periodically (separate from data refresh — longer cycle)
        Timer.scheduledTimer(withTimeInterval: 3660, repeats: true) { _ in
            Task { await AnomalyDetector.shared.check() }
        }
    }

    /// Re-open handler: Dock click or Cmd+Tab → show Dashboard
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openDashboard()
        return true
    }

    // MARK: - Dock menu

    /// Dock right-click shares the full stats menu (minus Quit, which Dock provides).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let src = menuBarController?.menu else { return nil }
        let dock = NSMenu()
        for item in src.items {
            if item.keyEquivalent == "q" { continue }
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

    // MARK: - Windows

    private func openDashboard() {
        if let w = DashboardWindowManager.shared.window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = I18n.t("dashboard.title")
        w.contentView = NSHostingView(rootView: DashboardView())
        w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
        DashboardWindowManager.shared.window = w
    }

    private func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = SettingsWindowManager.shared.window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = I18n.t("settings.title")
        w.contentView = NSHostingView(rootView: SettingsView())
        w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
        SettingsWindowManager.shared.window = w
    }

    func applicationWillTerminate(_ notification: Notification) {
        DataRefreshCoordinator.shared.stop()
        IntegrationRegistry.stopAll()
        DockManager.shared.stop()
        BookmarkManager.stopAll(securityScopedURLs)
        GitRepo.teardown()
    }

    // MARK: - Onboarding

    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "onboarding_completed") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.openOnboarding()
        }
    }

    private func openOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "AI Pulse — Welcome"
        w.contentView = NSHostingView(rootView: OnboardingView())
        w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
        OnboardingWindowManager.shared.window = w
    }

    /// On first launch, auto-enable integrations that have data detected.
    private func migrateIntegrationDefaults() {
        let migratedKey = "integration_defaults_migrated"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        UserDefaults.standard.set(true, forKey: migratedKey)

        for i in IntegrationRegistry.all {
            if i.detect().found {
                var cfg = IntegrationRegistry.config(for: i.id)
                cfg.enabled = true
                IntegrationRegistry.setConfig(for: i.id, cfg)
            }
        }
    }
}
