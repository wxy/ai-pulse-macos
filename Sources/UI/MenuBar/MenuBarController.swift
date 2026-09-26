import AppKit
import SwiftUI
import Combine
import GRDB
import AIPulseShared

enum DashboardEntryMode: String {
    case menuBar
    case island

    static let defaultsKey = "dashboard_entry_mode"

    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .menuBar
    }
}

final class SettingsWindowManager: @unchecked Sendable {
    static let shared = SettingsWindowManager()
    var window: NSWindow?
}

private final class RobotDashboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .dashboardEscapeRequested, object: nil)
    }
}

private final class TransparentDashboardHostingView: NSHostingView<DashboardPanelContent> {
    override var isOpaque: Bool { false }
}

@MainActor
private final class DashboardPanelState: ObservableObject {
    @Published var mode: DashboardEntryMode = .menuBar
    @Published var isExpanded = false
    @Published var initialTimeRange: TimeRange = .today
    @Published var capsuleWidth: CGFloat = 152
    @Published var capsuleHeight: CGFloat = 30
    @Published var dashboardGap: CGFloat = 0
    @Published var hasCameraHousing = false
}

private struct DashboardPanelContent: View {
    @ObservedObject var state: DashboardPanelState
    @State private var pulseRevision = 0

    private var currentActivity: PulseSnapshot? {
        let snapshot = PulseFeedbackController.shared.snapshot
        let availability = LocalDataStatus.current(
            hasActivity: (snapshot?.activityFacts?.todayTokens ?? 0) > 0
        )
        return snapshot?.isCurrent() == true && availability.canReportCurrentActivity
            ? snapshot : nil
    }

    private var capsuleColor: Color {
        guard let currentActivity else { return Color.gray }
        return Color(nsColor: PulseAppearance(tier: currentActivity.tier,
                                              cooling: currentActivity.activity?.freshness == .aging).color)
    }

    var body: some View {
        Group {
            if state.mode == .island {
                VStack(spacing: 0) {
                    Button(action: { DashboardWindowManager.shared.toggle() }) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(capsuleColor)
                                .frame(width: 7, height: 7)
                                .id(pulseRevision)
                            if state.hasCameraHousing {
                                Spacer(minLength: 0)
                            } else {
                                Text("AI Pulse")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                            Image(systemName: state.isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.horizontal, state.hasCameraHousing ? 14 : 0)
                        .frame(width: state.capsuleWidth, height: state.capsuleHeight)
                        .background(Color.black, in: UnevenRoundedRectangle(
                            topLeadingRadius: 0, bottomLeadingRadius: 15,
                            bottomTrailingRadius: 15, topTrailingRadius: 0
                        ))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(state.isExpanded
                        ? SetupCopy.text("收起 AI Pulse 仪表盘", "Collapse AI Pulse dashboard")
                        : SetupCopy.text("展开 AI Pulse 仪表盘", "Expand AI Pulse dashboard"))
                    .help(currentActivity.map { StatusItemController.detail(snapshot: $0) }
                        ?? SetupCopy.text("当前活动不可用", "Current activity unavailable"))
                    .contextMenu {
                        Button(I18n.t("menu.preferences")) {
                            DashboardWindowManager.shared.openSettings()
                        }
                        Button(AppSoundControl.isMuted()
                            ? SetupCopy.text("开启声音", "Unmute sounds")
                            : I18n.t("perception.mute_all")) {
                            AppSoundControl.toggle()
                        }
                        Divider()
                        Button(I18n.t("menu.quit")) { NSApp.terminate(nil) }
                    }

                    if state.isExpanded {
                        Color.clear.frame(height: state.dashboardGap)
                        DashboardView(initialTimeRange: state.initialTimeRange)
                    }
                }
                .frame(width: state.isExpanded ? max(560, state.capsuleWidth) : state.capsuleWidth,
                       height: state.capsuleHeight + (state.isExpanded ? state.dashboardGap + 640 : 0),
                       alignment: .top)
            } else {
                DashboardView(initialTimeRange: state.initialTimeRange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulseAppearanceDidChange)) { _ in
            pulseRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataDidChange)) { _ in
            pulseRevision &+= 1
        }
    }
}

@MainActor
final class DashboardWindowManager: NSObject {
    static let shared = DashboardWindowManager()
    weak var anchorButton: NSStatusBarButton?
    private(set) var window: NSWindow?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var openedAt: TimeInterval = 0
    private var deactivateObserver: NSObjectProtocol?
    private let panelState = DashboardPanelState()
    private var screenObserver: NSObjectProtocol?

    private var isIsland: Bool { panelState.mode == .island }

    func start() {
        setEntryMode(DashboardEntryMode.current)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    func setEntryMode(_ mode: DashboardEntryMode) {
        let changed = panelState.mode != mode
        if changed { close() }
        panelState.mode = mode
        panelState.isExpanded = false
        StatusItemController.shared.setEntryMode(mode)
        if mode == .island {
            ensureWindow()
            reposition()
            window?.orderFrontRegardless()
        } else if changed {
            window?.orderOut(nil)
        }
    }

    func toggle() {
        if isIsland {
            if panelState.isExpanded { close() } else { openOrBringToFront() }
        } else if window?.isVisible == true { close() } else { openOrBringToFront() }
    }

    func close() {
        let wasVisible = isIsland ? panelState.isExpanded : window?.isVisible == true
        if isIsland {
            panelState.isExpanded = false
            resizeAndPosition(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            window?.orderFrontRegardless()
        } else {
            window?.orderOut(nil)
        }
        if wasVisible { NotificationCenter.default.post(name: .dashboardDidClose, object: nil) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        localClickMonitor = nil
        globalClickMonitor = nil
        deactivateObserver = nil
    }

    func openOrBringToFront(initialTimeRange: TimeRange? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let wasExpanded = panelState.isExpanded
        if let initialTimeRange {
            if isIsland && !wasExpanded { panelState.initialTimeRange = initialTimeRange }
            else { NotificationCenter.default.post(name: .dashboardSwitchTab, object: nil,
                                                    userInfo: ["timeRange": initialTimeRange]) }
        }
        ensureWindow()
        guard let window else { return }
        if isIsland {
            panelState.isExpanded = true
            resizeAndPosition(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            if !wasExpanded { startDismissalMonitoring() }
        } else if !window.isVisible {
            reposition()
            startDismissalMonitoring()
        }
        openedAt = ProcessInfo.processInfo.systemUptime
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .dashboardDidOpen, object: Date())
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let panel = RobotDashboardPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = I18n.t("menu.dashboard_label")
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.level = isIsland ? .statusBar : .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = TransparentDashboardHostingView(rootView: DashboardPanelContent(state: panelState))
        window = panel
    }

    private func reposition() {
        guard let window else { return }
        if isIsland {
            window.level = .statusBar
            resizeAndPosition(animated: false)
        } else {
            window.level = .floating
            let screen = anchorButton?.window?.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
            let anchor = anchorButton.flatMap { button in
                button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            }
            let centerX = anchor?.midX ?? visible.midX
            let top = anchor?.minY ?? visible.maxY
            window.setFrame(NSRect(x: max(visible.minX, min(centerX - 280, visible.maxX - 560)),
                                   y: max(visible.minY, min(top - 648, visible.maxY - 640)),
                                   width: 560, height: 640), display: true)
        }
    }

    private func resizeAndPosition(animated: Bool) {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let notchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, right.minX - left.maxX)
        } else {
            notchWidth = 0
        }
        let hasCameraHousing = screen.safeAreaInsets.top > 0 && notchWidth > 0
        let capsuleHeight = hasCameraHousing ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
        let capsuleWidth = hasCameraHousing ? max(152, notchWidth + 72) : 152
        let dashboardGap = max(0, screen.frame.maxY - capsuleHeight - screen.visibleFrame.maxY)
        panelState.hasCameraHousing = hasCameraHousing
        panelState.capsuleWidth = capsuleWidth
        panelState.capsuleHeight = capsuleHeight
        panelState.dashboardGap = dashboardGap
        let height = capsuleHeight + (panelState.isExpanded ? dashboardGap + 640 : 0)
        let width = panelState.isExpanded ? max(560, capsuleWidth) : capsuleWidth
        let top = screen.frame.maxY
        let frame = NSRect(x: screen.frame.midX - width / 2,
                           y: max(screen.visibleFrame.minY, top - height),
                           width: width, height: height)
        window.setFrame(frame, display: true, animate: animated)
    }

    private func startDismissalMonitoring() {
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The status button handles its own toggle after mouse-up.
                if event.window !== self.window && event.window !== self.anchorButton?.window { self.close() }
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let timestamp = event.timestamp
            Task { @MainActor in
                guard let self, timestamp >= self.openedAt else { return }
                if let button = self.anchorButton, let window = button.window,
                   window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation) { return }
                self.close()
            }
        }

    }

    func openSettings() {
        close()
        NSApp.activate(ignoringOtherApps: true)
        if let window = SettingsWindowManager.shared.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = I18n.t("settings.title")
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        SettingsWindowManager.shared.window = window
    }
}
