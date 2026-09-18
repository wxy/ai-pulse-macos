import AppKit
import SwiftUI
import AIPulseShared

/// The menu bar is the perception headline: state first, explanation second,
/// and provider-observed money only when that fact actually exists.
///
/// Data changes refresh immediately; `.pulseDidChange` also refreshes the tint
/// and explanation as time decay lowers the pulse without a new event.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var contextMenu: NSMenu?
    private var headlineCache = ""
    private var detailCache = ""
    private let refreshGeneration = RefreshGeneration()
    private var currentTier: PulseTier?
    private var currentCooling = false
    private var latestTodayCommits: Int?

    /// Decision #4: status item ships enabled by default.
    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "status_item_enabled") as? Bool ?? true
    }

    func start() {
        contextMenu = buildMenu()
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
        apply(snapshot: PulseFeedbackController.shared.snapshot, observedSpend: nil,
              todayCommits: latestTodayCommits, updateContext: false)
        refresh()
    }

    @objc private func onLanguageChanged() {
        headlineCache = ""
        detailCache = ""
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
        let request = refreshGeneration.begin()
        Task { @MainActor in
            let snapshot = PulseFeedbackController.shared.snapshot
            let observedAt = snapshot?.asOf ?? Date()
            let todayStartMs = Int64(Calendar.current.startOfDay(for: observedAt).timeIntervalSince1970 * 1000)
            let spend = await StatsService.observedSpendForMenu(sinceMs: todayStartMs)
            let output = try? await StatsService.authorizedCodeOutput(
                sinceMs: todayStartMs, beforeMs: Int64(observedAt.timeIntervalSince1970 * 1000) + 1)
            let quotaFailures = ObservationFailures()
            let quotas = await StatsService.$observationFailures.withValue(quotaFailures) {
                await StatsService.latestQuotaStatus()
            }
            let quotaFailed = !(await quotaFailures.snapshot()).isEmpty
            guard refreshGeneration.isCurrent(request) else { return }
            updateQuota(items: quotaFailed ? nil : quotas)
            let latestPulse = PulseFeedbackController.shared.snapshot
            let sameDay = Calendar.current.isDate(observedAt, inSameDayAs: latestPulse?.asOf ?? Date())
            apply(snapshot: latestPulse, observedSpend: sameDay ? spend : nil,
                  todayCommits: sameDay ? output?.commits : nil)
        }
    }

    /// Testable seam: UI state derived from data.
    func apply(snapshot: PulseSnapshot?, observedSpend: [ObservedSpendItem]?, todayCommits: Int? = nil,
               updateContext: Bool = true) {
        guard let item = statusItem, let button = item.button else { return }
        latestTodayCommits = todayCommits
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
        let headline = availability.canReportCurrentActivity ? Self.headline(snapshot: validSnapshot) : SetupCopy.activity(availability.activity)
        let detail = Self.detail(snapshot: validSnapshot)
        if let menu = contextMenu {
            menu.items.first { ($0.representedObject as? String) == "pulse-recent-facts" }?.title =
                PulseCopy.recentFacts(validSnapshot?.activityFacts)
            menu.items.first { ($0.representedObject as? String) == "pulse-today-facts" }?.title =
                PulseCopy.todayFacts(validSnapshot?.activityFacts, commits: todayCommits)
            if headline != headlineCache,
               let row = menu.items.first(where: { ($0.representedObject as? String) == "pulse-headline" }) {
                row.title = headline
                headlineCache = headline
            }
            if detail != detailCache,
               let row = menu.items.first(where: { ($0.representedObject as? String) == "pulse-detail" }) {
                row.title = detail
                detailCache = detail
            }
            if updateContext, let row = menu.items.first(where: { ($0.representedObject as? String) == "observed-spend" }) {
                if let money = Self.observedSpendLine(observedSpend) {
                    row.title = money
                    row.isHidden = false
                } else {
                    row.isHidden = true
                }
            }
            if let row = menu.items.first(where: { ($0.representedObject as? String) == "closing-summary" }) {
                if let summary = ClosingBell.lastSummary() {
                    row.title = "\(I18n.t("pulse.closing_summary")) \(summary)"
                    row.isHidden = false
                } else {
                    row.isHidden = true
                }
            }
        }
    }

    private func updateQuota(items: [QuotaStatusItem]?) {
        guard let row = contextMenu?.items.first(where: { ($0.representedObject as? String) == "quota-context" }) else { return }
        let text = Self.quotaContext(items: items)
        row.title = text ?? ""
        row.isHidden = text == nil
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

        let headline = NSMenuItem(title: Self.headline(snapshot: nil), action: nil, keyEquivalent: "")
        headline.representedObject = "pulse-headline"
        headline.isEnabled = false
        menu.addItem(headline)
        let detail = NSMenuItem(title: Self.detail(snapshot: nil), action: nil, keyEquivalent: "")
        detail.representedObject = "pulse-detail"
        detail.isEnabled = false
        menu.addItem(detail)
        for identifier in ["pulse-recent-facts", "pulse-today-facts", "quota-context"] {
            let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            row.representedObject = identifier
            row.isEnabled = false
            row.isHidden = identifier == "quota-context"
            menu.addItem(row)
        }
        let observed = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        observed.representedObject = "observed-spend"
        observed.isEnabled = false
        observed.isHidden = true
        menu.addItem(observed)
        let closing = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        closing.representedObject = "closing-summary"
        closing.isEnabled = false
        closing.isHidden = true
        menu.addItem(closing)

        menu.addItem(.separator())
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
