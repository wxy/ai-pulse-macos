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
            let stats = await fetchStats()
            DispatchQueue.main.async {
                self.menu.removeAllItems()

                // Today line — click opens Dashboard
                if let today = stats.todaySummary {
                    let item = NSMenuItem(title: today, action: #selector(self.openDashboard), keyEquivalent: "")
                    item.target = self; self.menu.addItem(item)
                }
                // Week line — click opens Dashboard
                if let week = stats.weekSummary {
                    let item = NSMenuItem(title: week, action: #selector(self.openDashboard), keyEquivalent: "")
                    item.target = self; self.menu.addItem(item)
                }

                // Stats submenus — only shown if they have items
                let hasSubmenus = !stats.repos.isEmpty || !stats.providerCosts.isEmpty
                if hasSubmenus { self.menu.addItem(.separator()) }

                // Provider submenu — consumption from DB (USD)
                if !stats.providerCosts.isEmpty {
                    let m = NSMenuItem(title: "\(I18n.t("menu.this_week"))\(I18n.t("menu.by_provider"))", action: #selector(self.openDashboard), keyEquivalent: "")
                    m.target = self
                    let s = NSMenu()
                    for pc in stats.providerCosts {
                        let name = IntegrationRegistry.all.first(where: { $0.id == pc.providerId })?.displayName ?? pc.providerId
                        let item = NSMenuItem(
                            title: "\(name) · $\(String(format: "%.2f", pc.cost))",
                            action: #selector(self.openDashboard), keyEquivalent: ""
                        )
                        item.target = self
                        s.addItem(item)
                    }
                    m.submenu = s; self.menu.addItem(m)
                }
                if !stats.repos.isEmpty {
                    let m = NSMenuItem(title: "\(I18n.t("menu.this_week"))\(I18n.t("menu.by_repo"))", action: #selector(self.openDashboard), keyEquivalent: "")
                    m.target = self
                    let s = NSMenu()
                    for r in stats.repos {
                        let item = NSMenuItem(title: "\(r.name) · \(r.summary)", action: #selector(self.openDashboard), keyEquivalent: "")
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
    private struct Stats { let todaySummary: String?; let weekSummary: String?; let repos: [RepoStat]; let providerCosts: [(providerId: String, cost: Double)]; let hasActivity: Bool }

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
            let weekCst = await StatsService.combinedSpend(sinceMs: Int64(weekStart))
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
            let cal2 = Calendar.current
            let weekDays = cal2.dateComponents([.day], from: cal2.date(from: cal2.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!, to: cal2.startOfDay(for: Date())).day! + 1
            let rawSpend = (try? await StatsService.balanceDailySpend(days: weekDays, sinceMs: Int64(weekStart))) ?? []
            var spendByProvider: [String: Double] = [:]
            for s in rawSpend { spendByProvider[s.providerId, default: 0] += s.spend }
            var providerCosts: [(providerId: String, cost: Double)] = []
            for (pid, cost) in spendByProvider where cost > 0.001 {
                let enabledB = Set(IntegrationRegistry.enabledBGrade().map { $0.id })
                if enabledB.contains(pid) { providerCosts.append((pid, cost)) }
            }
            providerCosts.sort { $0.cost > $1.cost }

            // Repo cost: attribute total balance spend to repos proportionally by usage_event cost.
            // Single-provider single-repo use case → same total as provider submenu.
            let totalBalanceCost = spendByProvider.values.reduce(0, +)
            var cbr: [String: Double] = [:]
            let rcRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT repo_path AS p, COALESCE(SUM(cost_usd),0) AS c FROM usage_event WHERE repo_path IS NOT NULL AND ts >= ? GROUP BY repo_path", arguments: [weekStart])
            }
            var logTotal: Double = 0
            for r in rcRows { if let p: String = r["p"], !p.isEmpty, let c: Double = r["c"] { cbr[p] = c; logTotal += c } }
            // Scale log costs to match balance total
            let scale = logTotal > 0 ? totalBalanceCost / logTotal : 1.0

            // Repos: scaled cost + code changes from git
            var repos: [RepoStat] = []
            for (path, logCost) in cbr {
                let (a, d) = repoAddDel[path] ?? (0, 0)
                let scaledCost = logCost * scale
                guard a > 0 || d > 0, scaledCost > 0.001 else { continue }
                repos.append(RepoStat(name: URL(fileURLWithPath: path).lastPathComponent, added: a, deleted: d, cost: scaledCost))
            }

            // --- Helper to format a stats line ---
            func makeSummary(cnt: Int, cost: Double, added: Int, deleted: Int, label: String) -> String? {
                guard cnt > 0 || added > 0 || deleted > 0 || cost > 0.0001 else { return nil }
                let cS = cost > 0.0001 ? "$\(String(format: "%.2f", cost))" : "~$0"
                let linesStr = "+\(added)/-\(deleted) \(I18n.t("menu.lines"))"
                return "\(label) · \(cS) · \(linesStr)"
            }

            let todaySum = makeSummary(cnt: todayCnt, cost: todayCst, added: todayAdded, deleted: todayDeleted, label: I18n.t("menu.today"))
            let weekSum  = makeSummary(cnt: weekCnt,  cost: weekCst,  added: weekAdded,  deleted: weekDeleted,  label: I18n.t("menu.this_week"))

            let hasActivity = weekCnt > 0 || !repos.isEmpty || weekAdded > 0 || weekDeleted > 0 || weekCst > 0.0001
            if !hasActivity {
                return Stats(todaySummary: nil, weekSummary: nil, repos: [], providerCosts: [], hasActivity: false)
            }
            return Stats(todaySummary: todaySum, weekSummary: weekSum, repos: repos, providerCosts: providerCosts, hasActivity: true)
        } catch {
            return Stats(todaySummary: I18n.t("menu.unavailable"), weekSummary: nil, repos: [], providerCosts: [], hasActivity: false)
        }
    }

    @MainActor @objc private func openDashboard() {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = I18n.t("dashboard.title"); w.contentView = NSHostingView(rootView: DashboardView()); w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
        DashboardWindowManager.shared.window = w
    }

    @MainActor @objc private func openPreferences() {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = I18n.t("settings.title"); w.contentView = NSHostingView(rootView: SettingsView()); w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
        SettingsWindowManager.shared.window = w
    }
    @MainActor @objc private func quit() { NSApplication.shared.terminate(nil) }
}
