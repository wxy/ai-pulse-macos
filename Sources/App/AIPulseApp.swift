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

        // Reset per-session demo suppression on each launch
        DemoData.isSuppressed = false

        // One-time libgit2 init (replaces per-call init/shutdown)
        GitRepo.setup()

        // Resolve security-scoped bookmarks for sandbox file access
        securityScopedURLs = BookmarkManager.resolveAll()
        Logger.debug("A: bookmarks resolved=\(self.securityScopedURLs.count)")

        do { try AppDatabase.shared.setup(); AppHealthMonitor.shared.clearDBError() }
        catch {
            Logger.error("DB setup failed: \(error)")
            AppHealthMonitor.shared.reportDBError("Database setup: \(error.localizedDescription)")
        }

        // Build shared menu (stats refreshed every 30s, used by Dock right-click)
        menuBarController = MenuBarController()
        menuBarController?.start()

        // Auto-enable integrations that are detected on first launch
        migrateIntegrationDefaults()
        // Onboarding: show welcome page if first launch or no integrations enabled
        showOnboardingIfNeeded()
        // Start all enabled, detected integrations via the registry
        IntegrationRegistry.startAllEnabled()
        // Sync active CostSources to database for StatsService queries
        CostSource.syncToDatabase(IntegrationRegistry.activeCostSources())
        Logger.debug("integrations started, costSources synced")
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
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }

        // Centralized data refresh coordinator (replaces scattered timers).
        // Manages three ingestion phases — Ingest (30s), Git (5min), Balance (1h) —
        // with change detection, 500ms debounce, and unified .dataDidChange notification.
        DataRefreshCoordinator.shared.start()

        // Startup chime — lets the user know the app is alive, bypasses throttle.
        CoinSound.playForDataChange(bypassThrottle: true)

        // Check for anomalies periodically (separate from data refresh — longer cycle)
        Timer.scheduledTimer(withTimeInterval: 3660, repeats: true) { _ in
            Task { await AnomalyDetector.shared.check() }
        }

        // Build main menu bar (App, File, Window) — required for App Store compliance
        buildMainMenu()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChange),
            name: I18n.didChangeLanguage, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onDemoModeChange),
            name: .demoModeDidChange, object: nil
        )
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
            copy.representedObject = item.representedObject
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

    @MainActor
    private func openDashboard(initialTimeRange: TimeRange = .today) {
        DashboardWindowManager.shared.openOrBringToFront(initialTimeRange: initialTimeRange)
    }

    @MainActor
    @objc private func openPreferences() {
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

    // MARK: - Main Menu

    /// Build the full main menu bar (App, File, Window).
    /// Required for App Store compliance — Guideline 4.
    @MainActor
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // --- App Menu ---
        let appMenuItem = NSMenuItem()
        let appSubmenu = NSMenu()
        appMenuItem.submenu = appSubmenu

        let aboutTitle = "\(I18n.t("settings.about")) \(I18n.t("about.title"))"
        let aboutItem = NSMenuItem(title: aboutTitle, action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appSubmenu.addItem(aboutItem)

        let prefsItem = NSMenuItem(title: I18n.t("menu.preferences"), action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        appSubmenu.addItem(prefsItem)

        appSubmenu.addItem(.separator())

        // Enable Services submenu (AppKit auto-inserts it)
        if NSApp.servicesMenu == nil { NSApp.servicesMenu = NSMenu() }

        let quitItem = NSMenuItem(title: I18n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appSubmenu.addItem(quitItem)

        mainMenu.addItem(appMenuItem)

        // --- File Menu ---
        let fileMenuItem = NSMenuItem()
        let fileSubmenu = NSMenu(title: "File")
        let closeItem = NSMenuItem(title: I18n.t("menu.close_window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileSubmenu.addItem(closeItem)
        fileMenuItem.submenu = fileSubmenu
        mainMenu.addItem(fileMenuItem)

        // --- Window Menu ---
        let windowMenuItem = NSMenuItem()
        let windowSubmenu = NSMenu(title: "Window")

        let timeRanges: [(TimeRange, String)] = [
            (.today, I18n.t("dashboard.today")),
            (.thisWeek, I18n.t("dashboard.this_week")),
            (.days30, I18n.t("dashboard.days_30")),
        ]
        for (tr, label) in timeRanges {
            let item = NSMenuItem(title: "\(I18n.t("menu.dashboard_label")) — \(label)", action: #selector(openDashboardFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tr
            windowSubmenu.addItem(item)
        }

        windowSubmenu.addItem(.separator())

        let welcomeItem = NSMenuItem(title: I18n.t("general.rerun_welcome"), action: #selector(showOnboardingFromMenu), keyEquivalent: "")
        welcomeItem.target = self
        windowSubmenu.addItem(welcomeItem)

        windowSubmenu.addItem(.separator())

        let demoToggleItem = NSMenuItem(title: demoModeMenuItemTitle, action: #selector(toggleDemoMode), keyEquivalent: "")
        demoToggleItem.target = self
        demoToggleItem.tag = 999  // marker to find and update later
        windowSubmenu.addItem(demoToggleItem)

        windowMenuItem.submenu = windowSubmenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @MainActor @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @MainActor @objc private func openDashboardFromMenu(_ sender: NSMenuItem) {
        let tr = sender.representedObject as? TimeRange ?? .today
        DashboardWindowManager.shared.openOrBringToFront(initialTimeRange: tr)
    }

    @MainActor @objc private func showOnboardingFromMenu() {
        UserDefaults.standard.removeObject(forKey: "onboarding_completed")
        openOnboarding()
    }

    private var demoModeMenuItemTitle: String {
        DemoData.isActive ? I18n.t("demo.exit") : I18n.t("demo.enter")
    }

    @MainActor @objc private func toggleDemoMode() {
        if DemoData.isActive {
            DemoData.isManual = false
            DemoData.isSuppressed = true
            openPreferences()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .showIntegrationsTab, object: nil)
            }
        } else {
            DemoData.isSuppressed = false
            DemoData.isManual = true
        }
        NotificationCenter.default.post(name: .demoModeDidChange, object: nil)
        NotificationCenter.default.post(name: .dataDidChange, object: nil)
    }

    /// Update the demo menu item title when demo mode changes.
    @MainActor @objc private func onDemoModeChange() {
        buildMainMenu()
        // Refresh Dashboard if it's open
        NotificationCenter.default.post(name: .dashboardRefresh, object: nil)
    }

    @MainActor @objc private func onLanguageChange() {
        buildMainMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DataRefreshCoordinator.shared.stop()
        IntegrationRegistry.stopAll()
        DockManager.shared.stop()
        BookmarkManager.stopAll(securityScopedURLs)
        GitRepo.teardown()
    }

    // MARK: - Onboarding

    @MainActor
    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "onboarding_completed") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.openOnboarding()
        }
    }

    @MainActor
    private func openOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = I18n.t("onboarding.window_title")
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
