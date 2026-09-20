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
        window?.orderOut(nil)
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

@MainActor
final class MenuBarController: NSObject {
    private(set) var menu: NSMenu!
    private let refreshGeneration = RefreshGeneration()

    func start() {
        menu = NSMenu()

        // Observe language changes so we can rebuild the menu
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChange),
            name: I18n.didChangeLanguage, object: nil
        )

        // Observe data-change notifications from the centralized coordinator
        NotificationCenter.default.addObserver(
            self, selector: #selector(onDataChanged),
            name: .dataDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onPulseChanged),
            name: .pulseAppearanceDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onSoundMuteChanged),
            name: .soundMuteDidChange, object: nil
        )
        refreshStats()
    }

    @MainActor @objc private func onLanguageChange() {
        refreshStats()
        SettingsWindowManager.shared.window?.title = I18n.t("settings.title")
    }

    @objc private func onDataChanged() {
        refreshStats()
    }

    @objc private func onPulseChanged() {
        refreshStats()
    }

    @objc private func onSoundMuteChanged() {
        refreshStats()
    }

    /// Rebuild the entire menu from scratch each refresh.
    /// Sections appear only when they have content.
    private func refreshStats() {
        let request = refreshGeneration.begin()
        Task {
            let demoActive = DemoData.isActive
            let statsItems = await statsMenuItems()
            let todayStartMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
            let observedSpend = await StatsService.observedSpendForMenu(sinceMs: todayStartMs)

            DispatchQueue.main.async {
                guard self.refreshGeneration.isCurrent(request) else { return }
                let snapshot = PulseFeedbackController.shared.snapshot
                self.menu.removeAllItems()

                let headline = NSMenuItem(
                    title: StatusItemController.headline(snapshot: snapshot),
                    action: nil, keyEquivalent: "")
                headline.isEnabled = false
                self.menu.addItem(headline)
                let detail = NSMenuItem(
                    title: StatusItemController.detail(snapshot: snapshot),
                    action: nil, keyEquivalent: "")
                detail.isEnabled = false
                self.menu.addItem(detail)
                if let money = StatusItemController.observedSpendLine(observedSpend) {
                    let item = NSMenuItem(title: money, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    self.menu.addItem(item)
                }
                if let summary = ClosingBell.lastSummary() {
                    let item = NSMenuItem(
                        title: "\(I18n.t("pulse.closing_summary")) \(summary)",
                        action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    self.menu.addItem(item)
                }
                self.menu.addItem(.separator())

                // Demo mode indicator
                if demoActive {
                    let demoItem = NSMenuItem(title: I18n.t("demo.menu_label"), action: nil, keyEquivalent: "")
                    demoItem.isEnabled = false
                    self.menu.addItem(demoItem)
                    self.menu.addItem(.separator())
                }

                // Health status — only shown when not nominal
                let health = AppHealthMonitor.shared.current
                if health.severity >= .degraded {
                    let emoji = health.severity == .critical ? "🔴" :
                                health.severity == .impaired ? "🟠" : "🟡"
                    let text: String
                    switch health.severity {
                    case .critical: text = I18n.t("health.critical")
                    case .impaired: text = I18n.t("health.impaired")
                    default:        text = I18n.t("health.degraded")
                    }
                    let item = NSMenuItem(title: "\(emoji)  \(text)", action: #selector(self.openDashboard(_:)), keyEquivalent: "")
                    item.target = self
                    self.menu.addItem(item)
                    self.menu.addItem(.separator())
                }

                // Factual activity — today/week headlines plus repository output.
                for item in statsItems { self.menu.addItem(item) }

                self.menu.addItem(.separator())
                let prefsItem = NSMenuItem(title: I18n.t("menu.preferences"), action: #selector(self.openPreferences), keyEquivalent: ",")
                prefsItem.target = self; self.menu.addItem(prefsItem)
            }
        }
    }

    /// Build factual activity items shared by the Dock right-click menu and the
    /// main Pulse menu so the two never drift apart.
    func statsMenuItems() async -> [NSMenuItem] {
        let stats = DemoData.isActive ? Self.demoStats() : await fetchStats()
        var items: [NSMenuItem] = []

        // Today line — click opens Dashboard (Today tab)
        if let today = stats.todaySummary {
            let item = NSMenuItem(title: today, action: #selector(self.openDashboard(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TimeRange.today
            items.append(item)
        }
        // Week line — click opens Dashboard (This Week tab)
        if let week = stats.weekSummary {
            let item = NSMenuItem(title: week, action: #selector(self.openDashboard(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TimeRange.thisWeek
            items.append(item)
        }

        // Repository output is the only detailed breakdown kept in persistent
        // menus. Provider/tool money attribution belongs in the dashboard,
        // where provenance can be explained.
        if !stats.repos.isEmpty {
            items.append(.separator())
        }

        // Repo submenu
        if !stats.repos.isEmpty {
            let m = NSMenuItem(title: "\(I18n.t("menu.this_week"))\(I18n.t("menu.by_repo"))", action: #selector(self.openDashboard(_:)), keyEquivalent: "")
            m.target = self
            let s = NSMenu()
            for r in stats.repos {
                let item = NSMenuItem(title: "\(r.name) · \(r.summary)", action: #selector(self.openDashboard(_:)), keyEquivalent: "")
                item.target = self
                s.addItem(item)
            }
            m.submenu = s; items.append(m)
        }

        items.append(.separator())
        let mute = NSMenuItem(
            title: I18n.t("perception.mute_all"),
            action: #selector(self.toggleMute),
            keyEquivalent: "")
        mute.target = self
        mute.state = AppSoundControl.isMuted() ? .on : .off
        items.append(mute)

        return items
    }

    // MARK: - Data

    private struct RepoStat { let name: String; let added: Int; let deleted: Int; let commits: Int
        var summary: String {
            "+\(ChartMath.compactCount(Int64(added)))/-\(ChartMath.compactCount(Int64(deleted))) \(I18n.t("menu.lines")) · \(ChartMath.compactCount(Int64(commits))) \(I18n.t("menu.commits"))"
        } }
    private struct Stats { let todaySummary: String?; let weekSummary: String?; let repos: [RepoStat] }

    private func fetchStats() async -> Stats {
        do {
            let cal = Calendar.current
            let now = Date()
            let weekStart = Int64(DashboardPeriod(kind: .week, now: now, calendar: cal).start.timeIntervalSince1970 * 1000)
            let todayStart = Int64(cal.startOfDay(for: now).timeIntervalSince1970 * 1000)
            let end = ObservationBounds.upperExclusive(now: now, periodEnd: DashboardPeriod(kind: .today, now: now, calendar: cal).end)

            // --- Today ---
            let todayCnt: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (SELECT source, session_id FROM usage_event WHERE ts >= ? AND ts < ? AND NULLIF(session_id, '') IS NOT NULL AND (model IS NULL OR model != '<synthetic>') GROUP BY source, session_id)", arguments: [todayStart, end]) ?? 0
            }
            let todayTokens: Int64 = try await AppDatabase.shared.read { db in
                try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(\(TokenAccounting.observedTotalSQL)),0) FROM usage_event WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>')", arguments: [todayStart, end]) ?? 0
            }
            let todayCode = try await StatsService.authorizedCodeOutput(sinceMs: todayStart, beforeMs: end)

            // --- This week ---
            let weekCnt: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (SELECT source, session_id FROM usage_event WHERE ts >= ? AND ts < ? AND NULLIF(session_id, '') IS NOT NULL AND (model IS NULL OR model != '<synthetic>') GROUP BY source, session_id)", arguments: [weekStart, end]) ?? 0
            }
            let weekTokens: Int64 = try await AppDatabase.shared.read { db in
                try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(\(TokenAccounting.observedTotalSQL)),0) FROM usage_event WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>')", arguments: [weekStart, end]) ?? 0
            }
            let weekCode = try await StatsService.authorizedCodeOutput(sinceMs: weekStart, beforeMs: end)

            // --- Submenu breakdowns (this week) ---
            // Repo added/deleted per repo
            let repoAddDel = try await AppDatabase.shared.read { db -> [String: (Int, Int, Int)] in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT p, SUM(a) AS a, SUM(d) AS d, SUM(commits) AS commits FROM (
                      SELECT repo_path AS p, SUM(added) AS a, SUM(deleted) AS d, 0 AS commits
                      FROM code_change WHERE is_merge = 0 AND ts >= ? AND ts < ? GROUP BY repo_path
                      UNION ALL
                      SELECT repo_path AS p, 0 AS a, 0 AS d, COUNT(*) AS commits
                      FROM git_commit WHERE ts >= ? AND ts < ? GROUP BY repo_path
                    ) GROUP BY p
                    """, arguments: [weekStart, end, weekStart, end])
                let roots = RepositoryScope.configuredRoots()
                var result: [String: (Int, Int, Int)] = [:]
                for r in rows {
                    let path: String = r["p"] ?? ""
                    guard let repo = RepositoryScope.authorizedGitRoot(for: path, roots: roots) else { continue }
                    let a: Int64 = r["a"] ?? 0
                    let d: Int64 = r["d"] ?? 0
                    let commits: Int = r["commits"] ?? 0
                    let old = result[repo] ?? (0, 0, 0)
                    result[repo] = (old.0 + Int(a), old.1 + Int(d), old.2 + commits)
                }
                return result
            }

            let labels = RepositoryLabels.make(for: Array(repoAddDel.keys))
            let repos = repoAddDel.map { path, changes in
                RepoStat(name: labels[path] ?? path,
                         added: changes.0, deleted: changes.1, commits: changes.2)
            }.sorted { ($0.added + $0.deleted) > ($1.added + $1.deleted) }

            // --- Helper to format a stats line ---
            func makeSummary(tokens: Int64, cnt: Int, added: Int, deleted: Int, commits: Int, label: String) -> String? {
                guard tokens > 0 || cnt > 0 || added > 0 || deleted > 0 || commits > 0 else { return nil }
                let tokenLabel = I18n.t("dashboard.chart_tokens")
                let tokensStr = "\(ChartMath.compactCount(tokens)) \(tokenLabel)"
                let linesStr = "+\(ChartMath.compactCount(Int64(added)))/-\(ChartMath.compactCount(Int64(deleted))) \(I18n.t("menu.lines"))"
                return "\(label) · \(tokensStr) · \(linesStr) · \(ChartMath.compactCount(Int64(commits))) \(I18n.t("menu.commits"))"
            }

            let todaySum = makeSummary(tokens: todayTokens, cnt: todayCnt, added: todayCode.added, deleted: todayCode.deleted, commits: todayCode.commits, label: I18n.t("menu.today"))
            let weekSum  = makeSummary(tokens: weekTokens, cnt: weekCnt, added: weekCode.added, deleted: weekCode.deleted, commits: weekCode.commits, label: I18n.t("menu.this_week"))

            let hasActivity = weekTokens > 0 || weekCnt > 0 || !repos.isEmpty || weekCode.added > 0 || weekCode.deleted > 0 || weekCode.commits > 0
            AppHealthMonitor.shared.clearStatsError(source: "menu.activity")
            if !hasActivity {
                return Stats(todaySummary: nil, weekSummary: nil, repos: [])
            }
            // No estimated provider/tool allocations are presented anywhere.
            return Stats(todaySummary: todaySum, weekSummary: weekSum, repos: repos)
        } catch {
            AppHealthMonitor.shared.reportStatsError(error.localizedDescription, source: "menu.activity")
            return Stats(todaySummary: I18n.t("menu.unavailable"), weekSummary: nil, repos: [])
        }
    }

    /// Build demo-mode stats from DemoData so the Dock right-click menu
    /// shows realistic sample data when no integrations are configured.
    /// Uses the same single-source DemoData.data(for:) as the Dashboard.
    private static func demoStats() -> Stats {
        let todayData = DemoData.data(for: .today)
        let weekData = DemoData.data(for: .thisWeek)

        func makeSummary(tokens: Int64, cnt: Int, a: Int, d: Int, commits: Int, label: String) -> String? {
            guard tokens > 0 || cnt > 0 || a > 0 || d > 0 || commits > 0 else { return nil }
            return "\(label) · \(ChartMath.compactCount(tokens)) \(I18n.t("dashboard.chart_tokens")) · +\(ChartMath.compactCount(Int64(a)))/-\(ChartMath.compactCount(Int64(d))) \(I18n.t("menu.lines")) · \(ChartMath.compactCount(Int64(commits))) \(I18n.t("menu.commits"))"
        }

        let todayCnt = todayData.periodCalls
        let todayAdded = todayData.codeChanges.reduce(0) { $0 + $1.added }
        let todayDeleted = todayData.codeChanges.reduce(0) { $0 + $1.deleted }
        let todayCommits = todayData.codeChanges.reduce(0) { $0 + $1.commits }

        let weekCnt = weekData.dailyStats.reduce(0) { $0 + $1.calls }
        let weekAdded = weekData.codeChanges.reduce(0) { $0 + $1.added }
        let weekDeleted = weekData.codeChanges.reduce(0) { $0 + $1.deleted }
        let weekCommits = weekData.codeChanges.reduce(0) { $0 + $1.commits }

        let todaySum = makeSummary(tokens: Int64(todayData.periodTokens), cnt: todayCnt, a: todayAdded, d: todayDeleted, commits: todayCommits, label: I18n.t("menu.today"))
        let weekTokens = weekData.dailyStats.reduce(Int64(0)) { $0 + Int64($1.tokens) }
        let weekSum = makeSummary(tokens: weekTokens, cnt: weekCnt, a: weekAdded, d: weekDeleted, commits: weekCommits, label: I18n.t("menu.this_week"))

        let repos: [RepoStat] = weekData.repos.map { r in
            RepoStat(name: r.name,
                     added: r.added, deleted: r.deleted, commits: r.commits)
        }

        return Stats(todaySummary: todaySum, weekSummary: weekSum, repos: repos)
    }

    @MainActor @objc private func openDashboard(_ sender: NSMenuItem) {
        let initialRange = sender.representedObject as? TimeRange ?? .today
        DashboardWindowManager.shared.openOrBringToFront(initialTimeRange: initialRange)
    }

    @MainActor @objc private func openPreferences() {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = I18n.t("settings.title"); w.contentView = NSHostingView(rootView: SettingsView()); w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
        SettingsWindowManager.shared.window = w
    }
    @MainActor @objc private func toggleMute() {
        AppSoundControl.toggle()
    }
    @MainActor @objc private func quit() { NSApplication.shared.terminate(nil) }
}
