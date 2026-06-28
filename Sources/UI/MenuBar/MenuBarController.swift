import AppKit
import SwiftUI
import GRDB

final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    var window: NSWindow?
}

final class DashboardWindowManager {
    static let shared = DashboardWindowManager()
    var window: NSWindow?
}

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var menu: NSMenu!

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let icon = loadAppIcon()
            let resized = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                icon.draw(in: rect)
                return true
            }
            resized.isTemplate = true  // adapts to light/dark menu bar
            button.image = resized
        }

        menu = NSMenu()
        statusItem.menu = menu

        // Observe language changes so we can rebuild the menu + window title
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChange),
            name: I18n.didChangeLanguage, object: nil
        )

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshStats() }
        refreshStats()
    }

    @objc private func onLanguageChange() {
        refreshStats()
        SettingsWindowManager.shared.window?.title = I18n.t("settings.title")
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
                let bs = IntegrationRegistry.enabledBGrade()
                let hasProviderItems = bs.contains { provider in
                    if let cached = ApiPoller.shared.cachedBalance(for: provider.id),
                       let bal = cached.balances.first, bal.totalBalance > 0 { return true }
                    return false
                }
                let hasSubmenus = !stats.repos.isEmpty || hasProviderItems
                if hasSubmenus { self.menu.addItem(.separator()) }

                // Provider submenu — B-grade balance data from ApiPoller
                if !bs.isEmpty {
                    let m = NSMenuItem(title: I18n.t("menu.by_provider"), action: nil, keyEquivalent: "")
                    let s = NSMenu()
                    for b in bs {
                        if let cached = ApiPoller.shared.cachedBalance(for: b.id),
                           let bal = cached.balances.first {
                            s.addItem(NSMenuItem(
                                title: "\(b.displayName) · \(bal.currency) \(String(format: "%.2f", bal.totalBalance))",
                                action: nil, keyEquivalent: ""
                            ))
                        }
                    }
                    if s.numberOfItems > 0 {
                        m.submenu = s; self.menu.addItem(m)
                    }
                }
                if !stats.repos.isEmpty {
                    let m = NSMenuItem(title: I18n.t("menu.by_repo"), action: #selector(self.openDashboard), keyEquivalent: "")
                    m.target = self
                    let s = NSMenu()
                    for r in stats.repos { s.addItem(NSMenuItem(title: "\(r.name) · \(r.summary)", action: nil, keyEquivalent: "")) }
                    m.submenu = s; self.menu.addItem(m)
                }

                // Preferences + Quit
                self.menu.addItem(.separator())
                let prefsItem = NSMenuItem(title: I18n.t("menu.preferences"), action: #selector(self.openPreferences), keyEquivalent: ",")
                prefsItem.target = self; self.menu.addItem(prefsItem)
                let quitItem = NSMenuItem(title: I18n.t("menu.quit"), action: #selector(self.quit), keyEquivalent: "q")
                quitItem.target = self; self.menu.addItem(quitItem)

                // Tint: accent color when activity, secondary when idle
                if let button = self.statusItem.button {
                    button.contentTintColor = stats.hasActivity ? .controlAccentColor : .secondaryLabelColor
                }
            }
        }
    }

    private func loadAppIcon() -> NSImage {
        if let bundleImg = NSImage(contentsOf: Bundle.main.resourceURL?
            .appendingPathComponent("AIPulse.png") ?? URL(fileURLWithPath: "")) {
            return bundleImg
        }
        let binaryDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for depth in 1...4 {
            let url = binaryDir.appendingPathComponent(
                (0..<depth).map { _ in ".." }.joined(separator: "/") + "/Resources/AIPulse.png")
            if let img = NSImage(contentsOf: url) { return img }
        }
        return NSImage(systemSymbolName: "fuelpump.fill", accessibilityDescription: nil)!
    }

    // MARK: - Data

    private struct RepoStat { let name: String; let added: Int; let deleted: Int; let cost: Double
        var summary: String { "$\(String(format: "%.2f", cost)) · +\(added)/-\(deleted) \(I18n.t("menu.lines"))" } }
    private struct Stats { let todaySummary: String?; let weekSummary: String?; let repos: [RepoStat]; let hasActivity: Bool }

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
            let todayCst: Double? = try await AppDatabase.shared.read { db in
                try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [todayStart])
            }
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
            let weekCst: Double? = try await AppDatabase.shared.read { db in
                try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [weekStart])
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

            // Repo cost per repo
            var cbr: [String: Double] = [:]
            let rcRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT repo_path AS p, COALESCE(SUM(cost_usd),0) AS c FROM usage_event WHERE repo_path IS NOT NULL AND ts >= ? GROUP BY repo_path", arguments: [weekStart])
            }
            for r in rcRows { if let p: String = r["p"], !p.isEmpty { cbr[p] = r["c"] ?? 0 } }

            var repos: [RepoStat] = []
            for (path, cost) in cbr {
                let (a, d) = repoAddDel[path] ?? (0, 0)
                guard a > 0 || d > 0, cost > 0 else { continue }
                repos.append(RepoStat(name: URL(fileURLWithPath: path).lastPathComponent, added: a, deleted: d, cost: cost))
            }

            // --- Helper to format a stats line ---
            func makeSummary(cnt: Int, cost: Double, added: Int, deleted: Int, label: String) -> String? {
                guard cnt > 0 || added > 0 || deleted > 0 else { return nil }
                let cS = cost > 0.0001 ? "$\(String(format: "%.2f", cost))" : "~$0"
                let linesStr = "+\(added)/-\(deleted) \(I18n.t("menu.lines"))"
                return "\(label) · \(cS) · \(linesStr)"
            }

            let todaySum = makeSummary(cnt: todayCnt, cost: todayCst ?? 0, added: todayAdded, deleted: todayDeleted, label: I18n.t("menu.today"))
            let weekSum  = makeSummary(cnt: weekCnt,  cost: weekCst ?? 0,  added: weekAdded,  deleted: weekDeleted,  label: I18n.t("menu.this_week"))

            let hasActivity = weekCnt > 0 || !repos.isEmpty || weekAdded > 0 || weekDeleted > 0
            if !hasActivity {
                return Stats(todaySummary: nil, weekSummary: nil, repos: [], hasActivity: false)
            }
            return Stats(todaySummary: todaySum, weekSummary: weekSum, repos: repos, hasActivity: true)
        } catch {
            return Stats(todaySummary: I18n.t("menu.unavailable"), weekSummary: nil, repos: [], hasActivity: false)
        }
    }

    @objc private func openDashboard() {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = I18n.t("dashboard.title"); w.contentView = NSHostingView(rootView: DashboardView()); w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
        DashboardWindowManager.shared.window = w
    }

    @objc private func openPreferences() {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = I18n.t("settings.title"); w.contentView = NSHostingView(rootView: SettingsView()); w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
        SettingsWindowManager.shared.window = w
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
