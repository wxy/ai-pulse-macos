import AppKit
import SwiftUI
import AIPulseShared

/// The menu-bar robot conveys current activity; its context menu contains actions only.
///
/// Data changes refresh immediately; `.pulseDidChange` also refreshes the tint
/// and explanation as time decay lowers the pulse without a new event.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var contextMenu: NSMenu?
    private var currentTier: PulseTier?
    private var currentCooling = false

    /// Decision #4: status item ships enabled by default.
    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "status_item_enabled") as? Bool ?? true
    }

    func start() {
        guard isEnabled, statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = PulseAppearance(tier: nil).image()
            button.imagePosition = .imageOnly
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        }
        contextMenu = buildMenu()
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        DashboardWindowManager.shared.anchorButton = item.button
        statusItem = item
        refresh()

        NotificationCenter.default.addObserver(self, selector: #selector(onDataChanged),
                                               name: .dataDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onDataChanged), name: BookmarkManager.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onPulseChanged),
                                               name: .pulseAppearanceDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onBeatChanged),
                                               name: .pulseBeatDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onBeatChanged),
                                               name: .appHealthDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onLanguageChanged),
                                               name: I18n.didChangeLanguage, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onSoundMuteChanged),
                                               name: .soundMuteDidChange, object: nil)
    }

    @objc private func statusClicked() {
        DiagnosticJournal.log("dashboard_status_click", ["right": .bool(NSApp.currentEvent?.type == .rightMouseDown)])
        if NSApp.currentEvent?.type == .rightMouseDown, let contextMenu, let button = statusItem?.button {
            contextMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else {
            DashboardWindowManager.shared.toggle()
        }
    }

    // MARK: - Refresh

    @objc private func onDataChanged() {
        refresh()
    }

    @objc private func onBeatChanged() {
        renderMark()
    }

    @objc private func onPulseChanged() {
        refresh()
    }

    @objc private func onLanguageChanged() {
        contextMenu = buildMenu()
        onPulseChanged()
    }

    @objc private func onSoundMuteChanged() {
        guard let row = contextMenu?.items.first(where: {
            ($0.representedObject as? String) == "sound-mute"
        }) else { return }
        row.state = AppSoundControl.isMuted() ? .on : .off
    }

    func refresh() {
        apply(snapshot: PulseFeedbackController.shared.snapshot)
    }

    /// UI state derived from the current, authorized activity snapshot.
    func apply(snapshot: PulseSnapshot?) {
        guard let button = statusItem?.button else { return }
        let availability = LocalDataStatus.current(hasActivity: (snapshot?.activityFacts?.todayTokens ?? 0) > 0)
        let validSnapshot = snapshot?.isCurrent() == true && availability.canReportCurrentActivity ? snapshot : nil

        currentTier = validSnapshot?.tier
        currentCooling = validSnapshot?.activity?.freshness == .aging
        renderMark()
        button.title = ""
        button.setAccessibilityLabel(availability.canReportCurrentActivity ? Self.headline(snapshot: validSnapshot) : SetupCopy.activity(availability.activity))
        button.toolTip = [Self.detail(snapshot: validSnapshot), PulseCopy.recentFacts(validSnapshot?.activityFacts),
                          I18n.t("pulse.activity.legend")].joined(separator: "\n")

        if !availability.canReportCurrentActivity { button.toolTip = SetupCopy.activity(availability.activity) }
    }

    nonisolated static func quotaContext(items: [QuotaStatusItem]?, now: Date = Date()) -> String? {
        guard let items else { return I18n.t("pulse.activity.quota_unavailable") }
        guard !items.isEmpty else { return nil }
        let fresh = items.filter { !$0.isStale(asOf: now) && $0.utilization.isFinite && (0...100).contains($0.utilization) }
        guard !fresh.isEmpty else { return I18n.t("pulse.activity.quota_stale") }
        // Independent windows; never call the highest utilization a current beat.
        let values = fresh.map {
            "\(IntegrationRegistry.toolDisplayName(for: $0.toolId)) · \($0.windowId ?? "—") · \(String(format: "%.1f", $0.utilization))%"
        }
        return I18n.t("pulse.activity.quota_context") + " " + values.joined(separator: " / ")
            + (fresh.count < items.count ? " · " + I18n.t("pulse.activity.quota_stale") : "")
    }

    nonisolated static func tintColor(for tier: PulseTier?) -> NSColor {
        PulseAppearance(tier: tier).color
    }

    private func renderMark() {
        let beat = PulseFeedbackController.shared.isBeating &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion &&
            AppHealthMonitor.shared.current.severity < .critical
        statusItem?.button?.image = PulseAppearance(tier: currentTier, cooling: currentCooling).image(beat: beat)
    }

    nonisolated static func tierLabel(_ tier: PulseTier?) -> String {
        PulseAppearance(tier: tier).label
    }

    nonisolated static func headline(snapshot: PulseSnapshot?) -> String {
        "●  " + PulseAppearance(tier: snapshot?.tier, cooling: snapshot?.activity?.freshness == .aging).label
    }

    nonisolated static func detail(snapshot: PulseSnapshot?) -> String {
        guard let snapshot else { return I18n.t("pulse.reason.unavailable") }
        return PulseCopy.localizedReason(snapshot.reason, primarySignal: snapshot.primarySignal)
    }

    nonisolated static func observedSpendLine(_ items: [ObservedSpendItem]?) -> String? {
        guard let items else {
            return "\(I18n.t("pulse.observed_today")) · \(I18n.t("menu.unavailable"))"
        }
        let facts = items.filter { $0.amount.isFinite && $0.amount > 0 }
        guard !facts.isEmpty else { return nil }
        let values = facts.map { "\($0.currency.uppercased()) \(String(format: "%.1f", $0.amount))" }
        return "\(I18n.t("pulse.observed_today")) " + values.joined(separator: " + ")
    }

    // MARK: - Tier-colored robot

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(Self.menuItem(I18n.t("menu.dashboard_label") + "…", action: #selector(openDashboard)))
        menu.addItem(Self.menuItem(I18n.t("menu.preferences"), action: #selector(openPreferences)))
        menu.addItem(.separator())
        let mute = Self.menuItem(I18n.t("perception.mute_all"), action: #selector(toggleMute))
        mute.representedObject = "sound-mute"
        mute.state = AppSoundControl.isMuted() ? .on : .off
        menu.addItem(mute)
        menu.addItem(.separator())
        let quitItem = Self.menuItem(I18n.t("menu.quit"), action: #selector(quit))
        quitItem.representedObject = "quit"
        menu.addItem(quitItem)
        return menu
    }

    func makeDockMenu() -> NSMenu {
        let menu = (contextMenu?.copy() as? NSMenu) ?? buildMenu()
        if let quitItem = menu.items.first(where: { ($0.representedObject as? String) == "quit" }) {
            menu.removeItem(quitItem)
        }
        if menu.items.last?.isSeparatorItem == true, let last = menu.items.last {
            menu.removeItem(last)
        }
        return menu
    }

    private static func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = StatusItemController.shared
        return item
    }

    @objc private func openDashboard() {
        DashboardWindowManager.shared.openOrBringToFront()
    }

    @objc private func openPreferences() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = SettingsWindowManager.shared.window {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = I18n.t("settings.title")
        w.contentView = NSHostingView(rootView: SettingsView())
        w.center()
        w.makeKeyAndOrderFront(nil)
        w.isReleasedWhenClosed = false
        SettingsWindowManager.shared.window = w
    }

    @objc private func toggleMute() {
        AppSoundControl.toggle()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
