import AppKit
import SwiftUI
import GRDB

final class SettingsWindowManager: @unchecked Sendable {
    static let shared = SettingsWindowManager()
    var window: NSWindow?
}

final class DashboardWindowManager: @unchecked Sendable {
    static let shared = DashboardWindowManager()
    var window: NSWindow?

    /// Open the Dashboard or bring the existing window to front.
    /// If the window already exists, posts `.dashboardSwitchTab` so the view
    /// switches to the requested tab instead of opening a duplicate window.
    @MainActor
    func openOrBringToFront(initialTimeRange: TimeRange = .thisWeek) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = window, w.contentView != nil {
            // Window already open — request tab switch and bring to front
            NotificationCenter.default.post(name: .dashboardSwitchTab, object: nil,
                                            userInfo: ["timeRange": initialTimeRange])
            w.makeKeyAndOrderFront(nil)
            return
        }
        // Create a new window
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = I18n.t("dashboard.title")
        w.contentView = NSHostingView(rootView: DashboardView(initialTimeRange: initialTimeRange))
        w.center()
        w.makeKeyAndOrderFront(nil)
        w.isReleasedWhenClosed = false
        // Clear the stored reference when the window is closed
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: w, queue: .main) { [weak self] _ in
            self?.window = nil
        }
        window = w
    }
}

final class MenuBarController: NSObject, @unchecked Sendable {
    private(set) var menu: NSMenu!

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
        refreshStats()
    }

    @MainActor @objc private func onLanguageChange() {
        refreshStats()
        SettingsWindowManager.shared.window?.title = I18n.t("settings.title")
    }

    @objc private func onDataChanged() {
        refreshStats()
    }

    /// Rebuild the entire menu from scratch each refresh.
    /// Sections appear only when they have content.
    private func refreshStats() {
        Task {
            let demoActive = DemoData.isActive
            let stats = demoActive ? Self.demoStats() : await fetchStats()
            DispatchQueue.main.async {
                self.menu.removeAllItems()

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

                // Today line — click opens Dashboard (Today tab)
                if let today = stats.todaySummary {
                    let item = NSMenuItem(title: today, action: #selector(self.openDashboard(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = TimeRange.today
                    self.menu.addItem(item)
                }
                // Week line — click opens Dashboard (This Week tab)
                if let week = stats.weekSummary {
                    let item = NSMenuItem(title: week, action: #selector(self.openDashboard(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = TimeRange.thisWeek
                    self.menu.addItem(item)
                }

                // Stats submenus — only shown if they have items
                let hasSubmenus = !stats.repos.isEmpty || !stats.providerCosts.isEmpty || !stats.toolCosts.isEmpty
                if hasSubmenus { self.menu.addItem(.separator()) }

                // Tool submenu — by dev tool
                if !stats.toolCosts.isEmpty {
                    let m = NSMenuItem(title: "\(I18n.t("menu.this_week"))\(I18n.t("menu.by_tool"))", action: #selector(self.openDashboard(_:)), keyEquivalent: "")
                    m.target = self
                    let s = NSMenu()
                    for tc in stats.toolCosts {
                        let item = NSMenuItem(
                            title: "\(tc.name) · $\(String(format: "%.2f", tc.cost))",
                            action: #selector(self.openDashboard(_:)), keyEquivalent: ""
                        )
                        item.target = self
                        s.addItem(item)
                    }
                    m.submenu = s; self.menu.addItem(m)
                }

                // Provider submenu — consumption from DB (USD)
                if !stats.providerCosts.isEmpty {
                    let m = NSMenuItem(title: "\(I18n.t("menu.this_week"))\(I18n.t("menu.by_provider"))", action: #selector(self.openDashboard(_:)), keyEquivalent: "")
                    m.target = self
                    let s = NSMenu()
                    for pc in stats.providerCosts {
                        let name = IntegrationRegistry.all.first(where: { $0.id == pc.providerId })?.displayName ?? pc.providerId
                        let item = NSMenuItem(
                            title: "\(name) · $\(String(format: "%.2f", pc.cost))",
                            action: #selector(self.openDashboard(_:)), keyEquivalent: ""
                        )
                        item.target = self
                        s.addItem(item)
                    }
                    m.submenu = s; self.menu.addItem(m)
                }
                if !stats.repos.isEmpty {
                    let m = NSMenuItem(title: "\(I18n.t("menu.this_week"))\(I18n.t("menu.by_repo"))", action: #selector(self.openDashboard(_:)), keyEquivalent: "")
                    m.target = self
                    let s = NSMenu()
                    for r in stats.repos {
                        let item = NSMenuItem(title: "\(r.name) · \(r.summary)", action: #selector(self.openDashboard(_:)), keyEquivalent: "")
                        item.target = self
                        s.addItem(item)
                    }
                    m.submenu = s; self.menu.addItem(m)
                }

                self.menu.addItem(.separator())
                let prefsItem = NSMenuItem(title: I18n.t("menu.preferences"), action: #selector(self.openPreferences), keyEquivalent: ",")
                prefsItem.target = self; self.menu.addItem(prefsItem)
            }
        }
    }

    // MARK: - Data

    private struct RepoStat { let name: String; let added: Int; let deleted: Int; let cost: Double
        var summary: String { "$\(String(format: "%.2f", cost)) · +\(added)/-\(deleted) \(I18n.t("menu.lines"))" } }
    private struct ToolCost { let name: String; let cost: Double }
    private struct Stats { let todaySummary: String?; let weekSummary: String?; let repos: [RepoStat]; let providerCosts: [(providerId: String, cost: Double)]; let toolCosts: [ToolCost]; let hasActivity: Bool }

    private func fetchStats() async -> Stats {
        do {
            let cal = Calendar.current
            var monCal = cal; monCal.firstWeekday = 2
            let weekStart = monCal.date(from: monCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!.timeIntervalSince1970 * 1000
            let todayStart = cal.startOfDay(for: Date()).timeIntervalSince1970 * 1000

            // --- Today ---
            let todayCnt: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [todayStart]) ?? 0
            }
            // Combined spend (API balance spend + subscription amortization) — matches Dashboard.
            let todayCst = await StatsService.combinedSpend(sinceMs: Int64(todayStart))
            let todayAdded: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(added),0) FROM code_change WHERE is_merge = 0 AND ts >= ?", arguments: [todayStart]) ?? 0
            }
            let todayDeleted: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(deleted),0) FROM code_change WHERE is_merge = 0 AND ts >= ?", arguments: [todayStart]) ?? 0
            }

            // --- This week ---
            let weekCnt: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [weekStart]) ?? 0
            }
            let weekAdded: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(added),0) FROM code_change WHERE is_merge = 0 AND ts >= ?", arguments: [weekStart]) ?? 0
            }
            let weekDeleted: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(deleted),0) FROM code_change WHERE is_merge = 0 AND ts >= ?", arguments: [weekStart]) ?? 0
            }

            // --- Submenu breakdowns (this week) ---
            // Repo added/deleted per repo
            let raRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT repo_path AS p, COALESCE(SUM(added),0) AS a, COALESCE(SUM(deleted),0) AS d FROM code_change WHERE is_merge = 0 AND ts >= ? GROUP BY repo_path", arguments: [weekStart])
            }
            var repoAddDel: [String: (Int, Int)] = [:]
            for r in raRows {
                let path: String = r["p"] ?? ""
                let a: Int64 = r["a"] ?? 0
                let d: Int64 = r["d"] ?? 0
                repoAddDel[path] = (Int(a), Int(d))
            }

            // Per-provider spend this week from balance snapshots
            var cal2 = Calendar.current; cal2.firstWeekday = 2
            let weekDays = cal2.dateComponents([.day], from: cal2.date(from: cal2.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!, to: cal2.startOfDay(for: Date())).day! + 1
            let rawSpend = (try? await StatsService.balanceDailySpend(days: weekDays, sinceMs: Int64(weekStart))) ?? []
            // --- Unified cost computation ---
            // API total: from balance deltas, filtered to active providers
            var spendByProvider: [String: Double] = [:]
            for s in rawSpend { spendByProvider[s.providerId, default: 0] += s.spend }
            let enabledB = Set(IntegrationRegistry.balanceTrackedCostSources().compactMap { cs in
                if case .apiKey(let pid) = cs.kind { return pid }; return nil
            })
            var providerCosts: [(providerId: String, cost: Double)] = []
            var apiSpend = 0.0
            for (pid, cost) in spendByProvider where cost > 0.001 {
                if enabledB.contains(pid) { providerCosts.append((pid, cost)); apiSpend += cost }
            }
            providerCosts.sort { $0.cost > $1.cost }
            let subAmortization = StatsService.subscriptionDailyAmortization()
            let weekSubTotal = subAmortization * Double(weekDays)
            let weekCst = apiSpend + weekSubTotal

            // --- Repo breakdown: scaled API + subscription ---
            var cbr: [String: Double] = [:]
            let rcRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT repo_path AS p, COALESCE(SUM(cost_usd),0) AS c FROM usage_event WHERE repo_path IS NOT NULL AND ts >= ? GROUP BY repo_path", arguments: [weekStart])
            }
            var logTotal: Double = 0
            for r in rcRows { if let p: String = r["p"], !p.isEmpty, let c: Double = r["c"] { cbr[p] = c; logTotal += c } }
            let apiScale = logTotal > 0 ? apiSpend / logTotal : 1.0
            let subScale = logTotal > 0 ? weekSubTotal / logTotal : 0.0

            var repos: [RepoStat] = []
            for (path, logCost) in cbr {
                let (a, d) = repoAddDel[path] ?? (0, 0)
                let cost = logCost * apiScale + logCost * subScale
                guard a > 0 || d > 0 || cost > 0.001 else { continue }
                repos.append(RepoStat(name: URL(fileURLWithPath: path).lastPathComponent, added: a, deleted: d, cost: cost))
            }

            // Per-tool cost: same unified scaling as repos (API + subscription from usage_event proportions)
            let toolRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT source AS s, COALESCE(SUM(cost_usd),0) AS c FROM usage_event WHERE ts >= ? GROUP BY s", arguments: [weekStart])
            }
            let toolAPITotal = toolRows.reduce(0.0) { $0 + ($1["c"] as Double? ?? 0) }
            let toolApiScale = toolAPITotal > 0 ? apiSpend / toolAPITotal : 1.0
            let toolSubScale = toolAPITotal > 0 ? weekSubTotal / toolAPITotal : 0.0

            var toolCostMap: [String: Double] = [:]
            for r in toolRows {
                if let s: String = r["s"], let c: Double = r["c"], c > 0 {
                    toolCostMap[s] = c * toolApiScale + c * toolSubScale
                }
            }
            var toolCosts: [ToolCost] = toolCostMap.compactMap { (key, cost) in
                guard cost > 0.001 else { return nil }
                let label: String
                switch key {
                case "claude-code": label = "Claude Code"
                case "aider":       label = "aider"
                case "cursor":      label = "Cursor"
                case "copilot":     label = "Copilot"
                case "windsurf":    label = "Windsurf"
                default:            label = key
                }
                return ToolCost(name: label, cost: cost)
            }
            toolCosts.sort { $0.cost > $1.cost }

            // --- Helper to format a stats line ---
            func makeSummary(cnt: Int, cost: Double, added: Int, deleted: Int, label: String, vsAvg: Double? = nil) -> String? {
                guard cnt > 0 || added > 0 || deleted > 0 || cost > 0.0001 else { return nil }
                let cS = cost > 0.0001 ? "$\(String(format: "%.2f", cost))" : I18n.t("menu.approx_zero")
                let linesStr = "+\(added)/-\(deleted) \(I18n.t("menu.lines"))"
                var result = "\(label) · \(cS) · \(linesStr)"
                if let avg = vsAvg, avg > 0.001, cost > 0.001 {
                    let pct = Int(round(cost / avg * 100))
                    result += " (\(pct)%)"
                }
                return result
            }

            // 7-day average for percentage comparison
            _ = cal.startOfDay(for: cal.date(byAdding: .day, value: -6, to: Date())!).timeIntervalSince1970 * 1000
            let weekAvgCst = (apiSpend + subAmortization * 7.0) / 7.0

            let todaySum = makeSummary(cnt: todayCnt, cost: todayCst, added: todayAdded, deleted: todayDeleted, label: I18n.t("menu.today"), vsAvg: weekAvgCst)
            let weekSum  = makeSummary(cnt: weekCnt,  cost: weekCst,  added: weekAdded,  deleted: weekDeleted,  label: I18n.t("menu.this_week"))

            let hasActivity = weekCnt > 0 || !repos.isEmpty || weekAdded > 0 || weekDeleted > 0 || weekCst > 0.0001
            if !hasActivity {
                return Stats(todaySummary: nil, weekSummary: nil, repos: [], providerCosts: [], toolCosts: [], hasActivity: false)
            }
            return Stats(todaySummary: todaySum, weekSummary: weekSum, repos: repos, providerCosts: providerCosts, toolCosts: toolCosts, hasActivity: true)
        } catch {
            return Stats(todaySummary: I18n.t("menu.unavailable"), weekSummary: nil, repos: [], providerCosts: [], toolCosts: [], hasActivity: false)
        }
    }

    /// Build demo-mode stats from DemoData so the Dock right-click menu
    /// shows realistic sample data when no integrations are configured.
    /// Uses the same single-source DemoData.data(for:) as the Dashboard.
    private static func demoStats() -> Stats {
        let todayData = DemoData.data(for: .today)
        let weekData = DemoData.data(for: .thisWeek)

        func makeSummary(cnt: Int, cost: Double, a: Int, d: Int, label: String) -> String? {
            guard cnt > 0 || a > 0 || d > 0 || cost > 0.0001 else { return nil }
            let cS = cost > 0.0001 ? "$\(String(format: "%.2f", cost))" : I18n.t("menu.approx_zero")
            return "\(label) · \(cS) · +\(a)/-\(d) \(I18n.t("menu.lines"))"
        }

        let todayCst = todayData.combinedSpend
        let todayCnt = todayData.todayCalls
        let todayAdded = todayData.codeChanges.reduce(0) { $0 + $1.added }
        let todayDeleted = todayData.codeChanges.reduce(0) { $0 + $1.deleted }

        let weekCst = weekData.combinedSpend
        let weekCnt = weekData.dailyStats.reduce(0) { $0 + $1.calls }
        let weekAdded = weekData.codeChanges.reduce(0) { $0 + $1.added }
        let weekDeleted = weekData.codeChanges.reduce(0) { $0 + $1.deleted }

        let todaySum = makeSummary(cnt: todayCnt, cost: todayCst, a: todayAdded, d: todayDeleted, label: I18n.t("menu.today"))
        let weekSum = makeSummary(cnt: weekCnt, cost: weekCst, a: weekAdded, d: weekDeleted, label: I18n.t("menu.this_week"))

        let repos: [RepoStat] = weekData.repos.map { r in
            RepoStat(name: URL(fileURLWithPath: "/\(r.repo)").lastPathComponent,
                     added: r.added, deleted: r.deleted, cost: r.cost)
        }

        let providerCosts: [(providerId: String, cost: Double)] = weekData.balanceSpend.map {
            ($0.providerId, $0.spend)
        }

        let toolCosts: [ToolCost] = weekData.toolCostBreakdown.map { ToolCost(name: $0.name, cost: $0.cost) }

        return Stats(todaySummary: todaySum, weekSummary: weekSum, repos: repos,
                     providerCosts: providerCosts, toolCosts: toolCosts, hasActivity: true)
    }

    @MainActor @objc private func openDashboard(_ sender: NSMenuItem) {
        let initialRange = sender.representedObject as? TimeRange ?? .thisWeek
        DashboardWindowManager.shared.openOrBringToFront(initialTimeRange: initialRange)
    }

    @MainActor @objc private func openPreferences() {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = I18n.t("settings.title"); w.contentView = NSHostingView(rootView: SettingsView()); w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
        SettingsWindowManager.shared.window = w
    }
    @MainActor @objc private func quit() { NSApplication.shared.terminate(nil) }
}
