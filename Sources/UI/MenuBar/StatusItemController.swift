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
    private var headlineCache = ""
    private var detailCache = ""
    private let refreshGeneration = RefreshGeneration()

    /// Decision #4: status item ships enabled by default.
    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "status_item_enabled") as? Bool ?? true
    }

    func start() {
        guard isEnabled, statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = flameImage(for: nil)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        }
        item.menu = buildMenu()
        statusItem = item
        refresh()

        NotificationCenter.default.addObserver(self, selector: #selector(onDataChanged),
                                               name: .dataDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onPulseChanged),
                                               name: .pulseDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onConsumptionObserved),
                                               name: .consumptionDidOccur, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onSoundMuteChanged),
                                               name: .soundMuteDidChange, object: nil)
    }

    // MARK: - Refresh

    @objc private func onDataChanged() {
        refresh()
    }

    @objc private func onConsumptionObserved() {
        animatePulseIfAllowed()
    }

    @objc private func onPulseChanged() {
        refresh()
    }

    @objc private func onSoundMuteChanged() {
        guard let row = statusItem?.menu?.items.first(where: {
            ($0.representedObject as? String) == "sound-mute"
        }) else { return }
        row.state = AppSoundControl.isMuted() ? .on : .off
    }

    func refresh() {
        let request = refreshGeneration.begin()
        Task { @MainActor in
            let snapshot = await PulseEngine.shared.snapshot()
            let todayStartMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
            let spend = await StatsService.observedSpendForMenu(sinceMs: todayStartMs)
            guard refreshGeneration.isCurrent(request) else { return }
            apply(snapshot: snapshot, observedSpend: spend)
        }
    }

    /// Testable seam: UI state derived from data.
    func apply(snapshot: PulseSnapshot?, observedSpend: [ObservedSpendItem]?) {
        guard let item = statusItem, let button = item.button else { return }

        // Real tinted rendering (WI-6 反馈修正): template images are always
        // monochrome in the menu bar and contentTintColor does not apply —
        // bake the tier color into a non-template bitmap instead.
        button.image = flameImage(for: snapshot?.tier)

        button.title = " " + Self.tierLabel(snapshot?.tier)
        button.setAccessibilityLabel(Self.headline(snapshot: snapshot))

        let headline = Self.headline(snapshot: snapshot)
        let detail = Self.detail(snapshot: snapshot)
        if let menu = item.menu {
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
            if let row = menu.items.first(where: { ($0.representedObject as? String) == "observed-spend" }) {
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

    nonisolated static func tintColor(for tier: PulseTier?) -> NSColor {
        switch tier {
        case .intense: return .systemRed
        case .elevated: return .systemOrange
        case .active: return .systemYellow
        case .resting, .none: return .systemGray
        }
    }

    private func animatePulseIfAllowed() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let button = statusItem?.button else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            button.animator().alphaValue = 0.45
        } completionHandler: {
            Task { @MainActor in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    button.animator().alphaValue = 1
                }
            }
        }
    }

    nonisolated static func tierLabel(_ tier: PulseTier?) -> String {
        I18n.t("pulse.tier.\(tier?.rawValue ?? "unknown")")
    }

    nonisolated static func headline(snapshot: PulseSnapshot?) -> String {
        "●  \(tierLabel(snapshot?.tier))"
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

    // MARK: - Tier-colored flame

    @MainActor private var flameCache: [PulseTier?: NSImage] = [:]

    /// Render the flame symbol with the tier color baked in. Template images
    /// are monochrome in the menu bar and `contentTintColor` does not reach
    /// them — so we draw the symbol and tint its opaque pixels (sourceAtop).
    /// System colors adapt to light/dark menu bars; mid-tones stay legible.
    @MainActor private func flameImage(for tier: PulseTier?) -> NSImage {
        if let cached = flameCache[tier] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let base = NSImage(systemSymbolName: "flame.fill",
                           accessibilityDescription: "AI Pulse")!
            .withSymbolConfiguration(config)!
        let color = Self.tintColor(for: tier)
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        tinted.accessibilityDescription = "AI Pulse"
        flameCache[tier] = tinted
        return tinted
    }

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
        menu.addItem(Self.menuItem(I18n.t("menu.dashboard") + "…", action: #selector(openDashboard)))
        menu.addItem(Self.menuItem(I18n.t("menu.preferences") + "…", action: #selector(openPreferences)))
        let mute = Self.menuItem(I18n.t("perception.mute_all"), action: #selector(toggleMute))
        mute.representedObject = "sound-mute"
        mute.state = AppSoundControl.isMuted() ? .on : .off
        menu.addItem(mute)
        menu.addItem(.separator())
        menu.addItem(Self.menuItem(I18n.t("menu.quit"), action: #selector(quit)))
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
