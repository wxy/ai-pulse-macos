import AppKit
import AIPulseShared
import SwiftUI
import UserNotifications

/// Dock and menu-bar app with a shared robot dashboard.

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private var securityScopedURLs: [URL] = []
    private var didFinishLaunching = false
    private var shouldOpenDashboardAfterLaunch = false
    private var widgetRefreshTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Present foreground notifications with sound; without a delegate macOS
        // may show the banner but silently drop the sound.
        UNUserNotificationCenter.current().delegate = self

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
        UserDefaults.standard.register(defaults: [
            "coin_sound_enabled": true,
            SystemNotifications.enabledKey: true,
        ])
        if RuntimeQA.isEnabled {
            UserDefaults.standard.register(defaults: [
                "demo_mode_manual": true,
                "onboarding_completed": true,
                "sound_muted": true,
                "closing_bell_enabled": false,
                SystemNotifications.enabledKey: false,
            ])
        }

        // Reset per-session demo suppression on each launch
        DemoData.isSuppressed = false

        // One-time libgit2 init (replaces per-call init/shutdown)
        GitRepo.setup()

        // Resolve security-scoped bookmarks for sandbox file access
        securityScopedURLs = RuntimeQA.isEnabled ? [] : BookmarkManager.resolveAll()
        Logger.debug("A: bookmarks resolved=\(self.securityScopedURLs.count)")

        do { try AppDatabase.shared.setup(); AppHealthMonitor.shared.clearDBError() }
        catch {
            Logger.error("DB setup failed: \(error)")
            AppHealthMonitor.shared.reportDBError("Database setup: \(error.localizedDescription)")
        }

        // Auto-enable integrations that are detected on first launch
        if !RuntimeQA.isEnabled { migrateIntegrationDefaults() }
        // Onboarding: show welcome page if first launch or no integrations enabled
        showOnboardingIfNeeded()
        // Start all enabled, detected integrations via the registry
        if !RuntimeQA.isEnabled { IntegrationRegistry.startAllEnabled() }
        // Cache the App Store storefront once at launch for region-based gating.
        if !RuntimeQA.isEnabled { Task { await IntegrationRegistry.refreshStorefrontRegion() } }
        // Sync active CostSources to database for StatsService queries
        let activeSources = RuntimeQA.isEnabled ? [] : IntegrationRegistry.activeCostSources()
        CostSource.syncToDatabase(activeSources)
        Logger.debug("integrations started, costSources synced")
        DiagnosticJournal.log("app_launch", [
            "integrations": .int(IntegrationRegistry.all.count),
            "active_cost_sources": .int(activeSources.count),
        ])
        // Git/repo + Claude log monitoring is independent of which integrations are
        // enabled: it must run whenever the user has authorized repo directories or
        // ~/.claude. LogWatcher.start() is safe to call again (idempotent scans).
        if !RuntimeQA.isEnabled { LogWatcher.shared.start() }
        Logger.debug("LogWatcher started")
        // One consumption-event clock for the menu bar and Dock.
        PulseFeedbackController.shared.start()
        DockManager.shared.start()

        // Dashboard opens on Dock click or Cmd+Tab — not auto-launched

        // Request notification permission (only works in .app bundle, not bare binary)
        if Bundle.main.bundleIdentifier != nil && !RuntimeQA.isEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }

        // Centralized data refresh coordinator (replaces scattered timers).
        // Manages three ingestion phases — Ingest (30s), Git (5min), Balance (1h) —
        // with change detection, 500ms debounce, and unified .dataDidChange notification.
        if !RuntimeQA.isEnabled { DataRefreshCoordinator.shared.start() }
        if RuntimeQA.consumeLocalGitProbe() { GitMonitor.shared.poll() }

        // v2 §3.3: menu bar flame — the perception headline (default on).
        StatusItemController.shared.start()

        // Startup feedback is default-OFF in v2 (启动 ≠ 花钱); the user can
        // enable a startup chime in Settings.
        CoinSound.playStartupChimeIfEnabled()

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
            self, selector: #selector(onDemoModeChange),
            name: .demoModeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onSoundMuteChange),
            name: .soundMuteDidChange, object: nil
        )
        didFinishLaunching = true
        if shouldOpenDashboardAfterLaunch {
            shouldOpenDashboardAfterLaunch = false
            openDashboardFromWidget()
        }
    }

    @MainActor @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: value),
              AIPulseDeepLink.opensDashboard(url) else { return }
        if didFinishLaunching {
            openDashboardFromWidget()
        } else {
            shouldOpenDashboardAfterLaunch = true
        }
    }

    @MainActor
    private func openDashboardFromWidget() {
        openDashboard()
        guard widgetRefreshTask == nil else { return }
        widgetRefreshTask = Task { @MainActor [weak self] in
            await DataRefreshCoordinator.shared.refreshFromMacWidget()
            self?.widgetRefreshTask = nil
        }
    }

    @MainActor @objc private func onSoundMuteChange() {
        if AppSoundControl.isMuted() { CoinSound.stopPlayback() }
        NSApp.mainMenu?.items.first?.submenu?.items.first(where: { ($0.representedObject as? String) == "sound-mute" })?.state = AppSoundControl.isMuted() ? .on : .off
    }

    @MainActor @objc private func toggleSoundMute() {
        AppSoundControl.toggle()
    }

    /// Re-open handler: Dock click or Cmd+Tab → show Dashboard
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openDashboard()
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        AppSoundControl.isMuted() ? [.banner] : [.banner, .sound]
    }

    // MARK: - Dock menu

    /// Both right-click entry points share actions; the Dock supplies its own Quit.
    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        StatusItemController.shared.makeDockMenu()
    }

    // MARK: - Windows

    @MainActor
    private func openDashboard(initialTimeRange: TimeRange? = nil) {
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
        let muteItem = NSMenuItem(title: I18n.t("perception.mute_all"), action: #selector(toggleSoundMute), keyEquivalent: "")
        muteItem.target = self
        muteItem.representedObject = "sound-mute"
        muteItem.state = AppSoundControl.isMuted() ? .on : .off
        appSubmenu.addItem(muteItem)

        appSubmenu.addItem(.separator())

        // Enable Services submenu (AppKit auto-inserts it)
        if NSApp.servicesMenu == nil { NSApp.servicesMenu = NSMenu() }

        let quitItem = NSMenuItem(title: I18n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appSubmenu.addItem(quitItem)

        mainMenu.addItem(appMenuItem)

        // --- File Menu ---
        let fileMenuItem = NSMenuItem()
        let fileSubmenu = NSMenu(title: I18n.t("menu.file"))

        let welcomeItem = NSMenuItem(title: I18n.t("general.rerun_welcome"), action: #selector(showOnboardingFromMenu), keyEquivalent: "")
        welcomeItem.target = self
        fileSubmenu.addItem(welcomeItem)

        let demoToggleItem = NSMenuItem(title: demoModeMenuItemTitle, action: #selector(toggleDemoMode), keyEquivalent: "")
        demoToggleItem.target = self
        demoToggleItem.tag = 999  // marker to find and update later
        if ProcessInfo.processInfo.arguments.contains("--show-demo-controls") {
            fileSubmenu.addItem(demoToggleItem)
        }

        fileSubmenu.addItem(.separator())

        let closeItem = NSMenuItem(title: I18n.t("menu.close_window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileSubmenu.addItem(closeItem)

        fileMenuItem.submenu = fileSubmenu
        mainMenu.addItem(fileMenuItem)

        // --- Window Menu ---
        // Keep this menu conventional and limited to window management.
        let windowMenuItem = NSMenuItem()
        let windowSubmenu = NSMenu(title: I18n.t("menu.window"))
        let dashboardItem = NSMenuItem(title: I18n.t("menu.dashboard_label"), action: #selector(openDashboardFromMenu), keyEquivalent: "1")
        dashboardItem.target = self
        windowSubmenu.addItem(dashboardItem)
        windowSubmenu.addItem(.separator())
        windowSubmenu.addItem(NSMenuItem(title: I18n.t("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenuItem.submenu = windowSubmenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowSubmenu

        NSApp.mainMenu = mainMenu

    }

    @MainActor @objc private func openDashboardFromMenu() {
        openDashboard()
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
    }

    @MainActor @objc private func onLanguageChange() {
        DashboardWindowManager.shared.window?.title = I18n.t("menu.dashboard_label")
        SettingsWindowManager.shared.window?.title = I18n.t("settings.title")
        buildMainMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DataRefreshCoordinator.shared.stop()
        IntegrationRegistry.stopAll()
        DockManager.shared.stop()
        PulseFeedbackController.shared.stop()
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
        guard !UserDefaults.standard.bool(forKey: migratedKey) else {
            prefillSubscriptionTiers()
            return
        }
        UserDefaults.standard.set(true, forKey: migratedKey)

        for i in IntegrationRegistry.all {
            if i.detect().found {
                var cfg = IntegrationRegistry.config(for: i.id)
                cfg.enabled = true
                IntegrationRegistry.setConfig(for: i.id, cfg)
            }
        }
        prefillSubscriptionTiers()
    }

    /// v2 §4.7 零配置: prefill the catalog's standard (first) plan for every
    /// installed subscription-grade tool that has no tier chosen — new installs
    /// and existing users who never picked one. The user can ignore, change,
    /// or clear it; the fee only ever feeds the ledger, never the burn rate.
    /// One-shot per install.
    private func prefillSubscriptionTiers() {
        let key = "subscription_tier_prefill_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        for i in IntegrationRegistry.all {
            guard i.id != "opencode", i.detect().found else { continue }
            var cfg = IntegrationRegistry.config(for: i.id)
            guard cfg.subscriptionTier.isEmpty,
                  let tool = SubscriptionRegistry.tool(forName: i.displayName),
                  let standard = tool.tiers.first else { continue }
            cfg.subscriptionTier = standard.label
            IntegrationRegistry.setConfig(for: i.id, cfg)
            Logger.info("Prefilled \(i.displayName) plan: \(standard.label)")
        }
    }
}
