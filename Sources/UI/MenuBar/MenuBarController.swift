import AppKit
import SwiftUI
import GRDB
import AIPulseShared

final class SettingsWindowManager: @unchecked Sendable {
    static let shared = SettingsWindowManager()
    var window: NSWindow?
}

private final class RobotDashboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class TransparentDashboardHostingView: NSHostingView<DashboardView> {
    override var isOpaque: Bool { false }
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

    func toggle() {
        if window?.isVisible == true { close() } else { openOrBringToFront() }
    }

    func close() {
        let wasVisible = window?.isVisible == true
        window?.orderOut(nil)
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
        if window == nil {
            let panel = RobotDashboardPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
            panel.title = I18n.t("menu.dashboard_label")
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.contentView = TransparentDashboardHostingView(rootView: DashboardView(initialTimeRange: initialTimeRange ?? .today))
            window = panel
        } else if let initialTimeRange {
            NotificationCenter.default.post(name: .dashboardSwitchTab, object: nil,
                                            userInfo: ["timeRange": initialTimeRange])
        }
        guard let window else { return }
        if !window.isVisible {
            let screen = anchorButton?.window?.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
            let anchor = anchorButton.flatMap { button in
                button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            }
            let centerX = anchor?.midX ?? visible.midX
            let top = anchor?.minY ?? visible.maxY
            window.setFrameOrigin(NSPoint(x: max(visible.minX, min(centerX - 280, visible.maxX - 560)),
                                          y: max(visible.minY, min(top - 648, visible.maxY - 640))))
            startDismissalMonitoring()
        }
        openedAt = ProcessInfo.processInfo.systemUptime
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .dashboardDidOpen, object: Date())
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

