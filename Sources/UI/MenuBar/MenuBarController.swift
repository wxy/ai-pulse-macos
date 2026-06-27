import AppKit
import SwiftUI
import GRDB

final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    var window: NSWindow?
}

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var menu: NSMenu!

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button { button.title = "🤖" }

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

                // Today line (hidden if no data)
                if let today = stats.todaySummary {
                    self.menu.addItem(NSMenuItem(title: today, action: nil, keyEquivalent: ""))
                }
                // Week line (hidden if no data)
                if let week = stats.weekSummary {
                    self.menu.addItem(NSMenuItem(title: week, action: nil, keyEquivalent: ""))
                }

                // Stats submenus — only shown if they have items
                let hasSubmenus = !stats.models.isEmpty || !stats.repos.isEmpty
                if hasSubmenus { self.menu.addItem(.separator()) }

                if !stats.models.isEmpty {
                    let m = NSMenuItem(title: I18n.t("menu.by_model"), action: nil, keyEquivalent: "")
                    let s = NSMenu()
                    for x in stats.models {
                        let l = stats.netLines > 0 ? " · $\(String(format: "%.3f", x.cost / Double(stats.netLines)))\(I18n.t("menu.per_line"))" : ""
                        s.addItem(NSMenuItem(title: "\(x.name) · \(x.costStr)\(l)", action: nil, keyEquivalent: ""))
                    }
                    m.submenu = s; self.menu.addItem(m)
                }
                if !stats.repos.isEmpty {
                    let m = NSMenuItem(title: I18n.t("menu.by_repo"), action: nil, keyEquivalent: "")
                    let s = NSMenu()
                    for r in stats.repos { s.addItem(NSMenuItem(title: "\(r.name) · \(r.lines) \(I18n.t("menu.lines")) · \(r.cplStr)", action: nil, keyEquivalent: "")) }
                    m.submenu = s; self.menu.addItem(m)
                }

                // Fixed bottom items
                self.menu.addItem(.separator())
                let prefsItem = NSMenuItem(title: I18n.t("menu.preferences"), action: #selector(self.openPreferences), keyEquivalent: ",")
                prefsItem.target = self; self.menu.addItem(prefsItem)
                let quitItem = NSMenuItem(title: I18n.t("menu.quit"), action: #selector(self.quit), keyEquivalent: "q")
                quitItem.target = self; self.menu.addItem(quitItem)

                if let button = self.statusItem.button { button.title = stats.hasActivity ? "💬" : "🤖" }
            }
        }
    }

    // MARK: - Data

    private struct ModelStat { let name: String; let calls: Int; let tokens: Int; let cost: Double
        var costStr: String { cost > 0.0001 ? "$\(String(format: "%.2f", cost))" : "~$0" } }
    private struct RepoStat { let name: String; let lines: Int; let cost: Double
        var cplStr: String { lines > 0 ? "$\(String(format: "%.3f", cost / Double(lines)))\(I18n.t("menu.per_line"))" : "-" } }
    private struct Stats { let todaySummary: String?; let weekSummary: String?; let models: [ModelStat]; let repos: [RepoStat]; let netLines: Int; let hasActivity: Bool }

    private func fetchStats() async -> Stats {
        do {
            let cal = Calendar.current
            let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!.timeIntervalSince1970 * 1000
            let todayStart = cal.startOfDay(for: Date()).timeIntervalSince1970 * 1000

            // --- Today ---
            let todayCnt: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [todayStart]) ?? 0
            }
            let todayTokRow: Row? = try await AppDatabase.shared.read { db in
                try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(in_tokens),0) AS i, COALESCE(SUM(out_tokens),0) AS o, COALESCE(SUM(cache_tokens),0) AS c FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [todayStart])
            }
            let todayCst: Double? = try await AppDatabase.shared.read { db in
                try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [todayStart])
            }
            let todayNl: Int? = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(added - deleted),0) FROM code_change WHERE is_merge = 0 AND ts >= ?", arguments: [todayStart])
            }

            // --- This week ---
            let weekCnt: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [weekStart]) ?? 0
            }
            let weekTokRow: Row? = try await AppDatabase.shared.read { db in
                try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(in_tokens),0) AS i, COALESCE(SUM(out_tokens),0) AS o, COALESCE(SUM(cache_tokens),0) AS c FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [weekStart])
            }
            let weekCst: Double? = try await AppDatabase.shared.read { db in
                try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [weekStart])
            }
            let weekNl: Int? = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(added - deleted),0) FROM code_change WHERE is_merge = 0 AND ts >= ?", arguments: [weekStart])
            }

            // --- Submenu breakdowns (this week) ---
            let rows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT COALESCE(model,'unknown') as m, COUNT(*) as cnt, COALESCE(SUM(in_tokens+out_tokens+cache_tokens),0) as tok, COALESCE(SUM(cost_usd),0) as cst FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>') GROUP BY m ORDER BY cst DESC", arguments: [weekStart])
            }
            let models: [ModelStat] = rows.compactMap { r in
                let name: String = r["m"]
                guard name != "<synthetic>" && name != "unknown" else { return nil }
                let calls: Int64 = r["cnt"]; let tokens: Int64 = r["tok"]; let cost: Double = r["cst"]
                return ModelStat(name: name, calls: Int(calls), tokens: Int(tokens), cost: cost)
            }

            var cbr: [String: Double] = [:]
            let rcRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT repo_path AS p, COALESCE(SUM(cost_usd),0) AS c FROM usage_event WHERE repo_path IS NOT NULL AND ts >= ? GROUP BY repo_path", arguments: [weekStart])
            }
            for r in rcRows { if let p: String = r["p"], !p.isEmpty { cbr[p] = r["c"] ?? 0 } }

            let rrRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT repo_path AS p, COALESCE(SUM(added - deleted),0) AS l FROM code_change WHERE is_merge = 0 AND ts >= ? GROUP BY repo_path ORDER BY l DESC", arguments: [weekStart])
            }
            var repos: [RepoStat] = []
            for r in rrRows {
                let path: String = r["p"] ?? ""; let lines: Int = r["l"] ?? 0; let c = cbr[path] ?? 0
                guard lines > 0, c > 0 else { continue }
                repos.append(RepoStat(name: URL(fileURLWithPath: path).lastPathComponent, lines: lines, cost: c))
            }

            // --- Helper to format a stats line ---
            func makeSummary(cnt: Int, tokRow: Row?, cost: Double, netLines: Int, label: String) -> String? {
                guard cnt > 0 else { return nil }
                var t = 0
                if let row = tokRow {
                    let i: Int64 = row["i"]; let o: Int64 = row["o"]; let c: Int64 = row["c"]
                    t = Int(i + o + c)
                }
                let cS = cost > 0.0001 ? "$\(String(format: "%.2f", cost))" : "~$0"
                let cpl = netLines > 0 && cost > 0 ? " · $\(String(format: "%.3f", cost / Double(netLines)))\(I18n.t("menu.per_line"))" : ""
                return "\(label) \(cnt) \(I18n.t("menu.calls")) · \(fmt(t)) \(I18n.t("menu.tokens")) · \(cS)\(cpl)"
            }

            let todaySum = makeSummary(cnt: todayCnt, tokRow: todayTokRow, cost: todayCst ?? 0, netLines: todayNl ?? 0, label: I18n.t("menu.today"))
            let weekSum  = makeSummary(cnt: weekCnt,  tokRow: weekTokRow,  cost: weekCst ?? 0,  netLines: weekNl ?? 0,  label: I18n.t("menu.this_week"))

            let hasActivity = weekCnt > 0 || !repos.isEmpty
            if !hasActivity {
                return Stats(todaySummary: nil, weekSummary: nil, models: [], repos: [], netLines: 0, hasActivity: false)
            }
            return Stats(todaySummary: todaySum, weekSummary: weekSum, models: models, repos: repos, netLines: weekNl ?? 0, hasActivity: true)
        } catch {
            return Stats(todaySummary: I18n.t("menu.unavailable"), weekSummary: nil, models: [], repos: [], netLines: 0, hasActivity: false)
        }
    }

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000 { return "\(n/1_000_000).\( (n%1_000_000)/100_000)M" }
        if n >= 1_000 { return "\(n/1_000).\( (n%1_000)/100)K" }
        return "\(n)"
    }

    @objc private func openPreferences() {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = I18n.t("settings.title"); w.contentView = NSHostingView(rootView: SettingsView()); w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
        SettingsWindowManager.shared.window = w
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
