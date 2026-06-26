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
    private var summaryItem: NSMenuItem!
    private var modelItems: [NSMenuItem] = []

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button { button.title = "🤖" }

        buildMenu()

        // Observe language changes so we can rebuild the menu + window title
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChange),
            name: I18n.didChangeLanguage, object: nil
        )

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshStats() }
        refreshStats()
    }

    private func buildMenu() {
        menu = NSMenu()
        summaryItem = NSMenuItem(title: I18n.t("menu.loading"), action: nil, keyEquivalent: "")
        menu.addItem(summaryItem)
        menu.addItem(.separator())
        let prefsItem = NSMenuItem(title: I18n.t("menu.preferences"), action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self; menu.addItem(prefsItem)
        let quitItem = NSMenuItem(title: I18n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func onLanguageChange() {
        // Save old model submenu items so refreshStats doesn't orphan them
        modelItems.removeAll()
        buildMenu()
        refreshStats()
        // Also update the prefs window title if it's open
        SettingsWindowManager.shared.window?.title = I18n.t("settings.title")
    }

    private func refreshStats() {
        Task {
            let stats = await fetchThisWeekStats()
            DispatchQueue.main.async {
                self.summaryItem.title = stats.summary
                for item in self.modelItems { self.menu.removeItem(item) }
                self.modelItems.removeAll()
                if !stats.models.isEmpty {
                    let m = NSMenuItem(title: I18n.t("menu.by_model"), action: nil, keyEquivalent: "")
                    let s = NSMenu()
                    for x in stats.models {
                        let l = stats.netLines > 0 ? " · $\(String(format: "%.3f", x.cost / Double(stats.netLines)))\(I18n.t("menu.per_line"))" : ""
                        s.addItem(NSMenuItem(title: "\(x.name) · \(x.costStr)\(l)", action: nil, keyEquivalent: ""))
                    }
                    m.submenu = s; self.menu.insertItem(m, at: self.menu.numberOfItems - 2); self.modelItems.append(m)
                }
                if !stats.repos.isEmpty {
                    let m = NSMenuItem(title: I18n.t("menu.by_repo"), action: nil, keyEquivalent: "")
                    let s = NSMenu()
                    for r in stats.repos { s.addItem(NSMenuItem(title: "\(r.name) · \(r.lines) \(I18n.t("menu.lines")) · \(r.cplStr)", action: nil, keyEquivalent: "")) }
                    m.submenu = s; self.menu.insertItem(m, at: self.menu.numberOfItems - 2); self.modelItems.append(m)
                }
                if let button = self.statusItem.button { button.title = stats.hasActivity ? "💬" : "🤖" }
            }
        }
    }

    // MARK: - Data

    private struct ModelStat { let name: String; let calls: Int; let tokens: Int; let cost: Double
        var costStr: String { cost > 0.0001 ? "$\(String(format: "%.2f", cost))" : "~$0" } }
    private struct RepoStat { let name: String; let lines: Int; let cost: Double
        var cplStr: String { lines > 0 ? "$\(String(format: "%.3f", cost / Double(lines)))\(I18n.t("menu.per_line"))" : "-" } }
    private struct Stats { let summary: String; let cpl: String; let models: [ModelStat]; let repos: [RepoStat]; let netLines: Int; let hasActivity: Bool }

    private func fetchThisWeekStats() async -> Stats {
        do {
            let cal = Calendar.current
            let w = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!.timeIntervalSince1970 * 1000

            let cnt: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [w]) ?? 0
            }
            let tokRow: Row? = try await AppDatabase.shared.read { db in
                try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(in_tokens),0) AS i, COALESCE(SUM(out_tokens),0) AS o, COALESCE(SUM(cache_tokens),0) AS c FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [w])
            }
            let cst: Double? = try await AppDatabase.shared.read { db in
                try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')", arguments: [w])
            }

            let rows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT COALESCE(model,'unknown') as m, COUNT(*) as cnt, COALESCE(SUM(in_tokens+out_tokens+cache_tokens),0) as tok, COALESCE(SUM(cost_usd),0) as cst FROM usage_event WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>') GROUP BY m ORDER BY cst DESC", arguments: [w])
            }
            let models: [ModelStat] = rows.compactMap { r in
                let name: String = r["m"]
                guard name != "<synthetic>" && name != "unknown" else { return nil }
                let calls: Int64 = r["cnt"]
                let tokens: Int64 = r["tok"]
                let cost: Double = r["cst"]
                return ModelStat(name: name, calls: Int(calls), tokens: Int(tokens), cost: cost)
            }

            var cbr: [String: Double] = [:]
            let rcRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT repo_path AS p, COALESCE(SUM(cost_usd),0) AS c FROM usage_event WHERE repo_path IS NOT NULL AND ts >= ? GROUP BY repo_path", arguments: [w])
            }
            for r in rcRows { if let p: String = r["p"], !p.isEmpty { cbr[p] = r["c"] ?? 0 } }

            let rrRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT repo_path AS p, COALESCE(SUM(added - deleted),0) AS l FROM code_change WHERE is_merge = 0 AND ts >= ? GROUP BY repo_path ORDER BY l DESC", arguments: [w])
            }
            var repos: [RepoStat] = []
            for r in rrRows {
                let path: String = r["p"] ?? ""; let lines: Int = r["l"] ?? 0; let c = cbr[path] ?? 0
                guard lines > 0, c > 0 else { continue }
                repos.append(RepoStat(name: URL(fileURLWithPath: path).lastPathComponent, lines: lines, cost: c))
            }

            let nl: Int? = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(added - deleted),0) FROM code_change WHERE is_merge = 0 AND ts >= ?", arguments: [w])
            }

            // Use explicit‑type subscript: `row["col"] as Int` picks the generic
            // DatabaseValueConvertible overload.  `as? Int` would cast the raw
            // DatabaseValue (which is not Int) and always return nil.
            let totalT: Int
            if let row = tokRow {
                let i: Int64 = row["i"]
                let o: Int64 = row["o"]
                let c: Int64 = row["c"]
                totalT = Int(i + o + c)
            } else { totalT = 0 }
            let coeff = cst ?? 0
            let costS = coeff > 0.0001 ? "$\(String(format: "%.2f", coeff))" : "~$0"
            let nlv = nl ?? 0
            let cplS = nlv > 0 && coeff > 0 ? "$\(String(format: "%.3f", coeff / Double(nlv)))\(I18n.t("menu.per_line"))" : ""
            let sum = cplS.isEmpty ? "📊 \(cnt) \(I18n.t("menu.calls")) · \(fmt(totalT)) \(I18n.t("menu.tokens")) · \(costS)" : "📊 \(cnt) \(I18n.t("menu.calls")) · \(fmt(totalT)) \(I18n.t("menu.tokens")) · \(costS) · \(cplS)"

            if cnt == 0 && repos.isEmpty { return Stats(summary: I18n.t("menu.no_usage"), cpl: "", models: [], repos: [], netLines: 0, hasActivity: false) }
            return Stats(summary: sum, cpl: cplS, models: models, repos: repos, netLines: nl ?? 0, hasActivity: true)
        } catch { return Stats(summary: I18n.t("menu.unavailable"), cpl: "", models: [], repos: [], netLines: 0, hasActivity: false) }
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
