import AppKit
import SwiftUI
import UserNotifications

/// Dock app. Shows Dashboard as the primary window. No menu bar icon.

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var securityScopedURLs: [URL] = []
    var menuBarController: MenuBarController?
    private var windowSubmenu: NSMenu?

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
        // Cache the App Store storefront once at launch for region-based gating.
        Task { await IntegrationRegistry.refreshStorefrontRegion() }
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
            Task { await SpendAlertService.shared.check() }
        }

        // Build main menu bar (App, File, Window) — required for App Store compliance
        buildMainMenu()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChange),
            name: I18n.didChangeLanguage, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshWindowMenuStats),
            name: .dataDidChange, object: nil
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

    /// Open (or focus) the Settings window on the given tab.
    @MainActor
    private func openSettings(tab: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = SettingsWindowManager.shared.window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .settingsSwitchTab, object: nil, userInfo: ["tab": tab])
        } else {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = I18n.t("settings.title")
            w.contentView = NSHostingView(rootView: SettingsView(initialTab: tab))
            w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
            SettingsWindowManager.shared.window = w
        }
    }

    @MainActor
    @objc private func openPreferences() {
        openSettings(tab: "General")
    }

    @MainActor @objc private func showAbout() {
        openSettings(tab: "About")
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

        // macOS rewrites the Cmd+, item's title to the system-localized "设置…"
        // regardless of the keyEquivalent, so keep the shortcut for the user.
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

        let welcomeItem = NSMenuItem(title: I18n.t("general.rerun_welcome"), action: #selector(showOnboardingFromMenu), keyEquivalent: "")
        welcomeItem.target = self
        fileSubmenu.addItem(welcomeItem)

        let demoToggleItem = NSMenuItem(title: demoModeMenuItemTitle, action: #selector(toggleDemoMode), keyEquivalent: "")
        demoToggleItem.target = self
        demoToggleItem.tag = 999  // marker to find and update later
        fileSubmenu.addItem(demoToggleItem)

        fileSubmenu.addItem(.separator())

        let closeItem = NSMenuItem(title: I18n.t("menu.close_window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileSubmenu.addItem(closeItem)

        fileMenuItem.submenu = fileSubmenu
        mainMenu.addItem(fileMenuItem)

        // --- Window Menu ---
        // Contents are the shared dynamic stats menu (today/week lines + submenus),
        // built from MenuBarController.statsMenuItems() and refreshed on .dataDidChange
        // so the Window and Dock menus stay identical.
        let windowMenuItem = NSMenuItem()
        let windowSubmenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowSubmenu
        mainMenu.addItem(windowMenuItem)
        self.windowSubmenu = windowSubmenu

        NSApp.mainMenu = mainMenu

        refreshWindowMenuStats()
    }

    /// Rebuild the Window menu from the shared stats source (same items as the Dock
    /// right-click menu). Called on launch, language change, and every .dataDidChange.
    @MainActor @objc
    private func refreshWindowMenuStats() {
        guard let sub = windowSubmenu else { return }
        sub.removeAllItems()
        Task {
            let items = await menuBarController?.statsMenuItems() ?? []
            await MainActor.run {
                guard let sub = windowSubmenu else { return }
                sub.removeAllItems()
                for item in items { sub.addItem(item) }
            }
        }
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
        // Intentionally skip GitRepo.teardown() (git_libgit2_shutdown). GitMonitor
        // can have a libgit2 op in flight on its utility-qos queue at quit; shutdown
        // waits on it and hangs the app on exit. The OS reclaims libgit2 memory when
        // the process exits, so quitting stays instant and non-blocking.
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
