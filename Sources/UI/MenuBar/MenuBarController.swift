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

        menu = NSMenu()
        summaryItem = NSMenuItem(title: I18n.t("menu.loading"), action: nil, keyEquivalent: "")
        menu.addItem(summaryItem)
        menu.addItem(.separator())
        let prefsItem = NSMenuItem(title: I18n.t("menu.preferences"), action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self; menu.addItem(prefsItem)
        let quitItem = NSMenuItem(title: I18n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)
        statusItem.menu = menu

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshStats() }
        refreshStats()
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
                        let l = stats.netLines > 0 ? " · $\(String(format: "%.3f", x.cost / Double(stats.netLines)))/line" : ""
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
        var cplStr: String { lines > 0 ? "$\(String(format: "%.3f", cost / Double(lines)))/line" : "-" } }
    private struct Stats { let summary: String; let cpl: String; let models: [ModelStat]; let repos: [RepoStat]; let netLines: Int; let hasActivity: Bool }

    private func fetchThisWeekStats() async -> Stats {
        do {
            let cal = Calendar.current
            let w = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!.timeIntervalSince1970 * 1000

            let cnt: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event WHERE ts >= ?", arguments: [w]) ?? 0
            }
            let tokRow: Row? = try await AppDatabase.shared.read { db in
                try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(in_tokens),0) AS i, COALESCE(SUM(out_tokens),0) AS o, COALESCE(SUM(cache_tokens),0) AS c FROM usage_event WHERE ts >= ?", arguments: [w])
            }
            let cst: Double? = try await AppDatabase.shared.read { db in
                try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_event WHERE ts >= ?", arguments: [w])
            }

            let rows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT COALESCE(model,'unknown') as m, COUNT(*) as cnt, COALESCE(SUM(in_tokens+out_tokens+cache_tokens),0) as tok, COALESCE(SUM(cost_usd),0) as cst FROM usage_event WHERE ts >= ? GROUP BY m ORDER BY cst DESC", arguments: [w])
            }
            let models = rows.map { r in ModelStat(name: r["m"] ?? "?", calls: r["cnt"] ?? 0, tokens: r["tok"] ?? 0, cost: r["cst"] ?? 0) }

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

            let totalT = (tokRow?["i"] as? Int ?? 0) + (tokRow?["o"] as? Int ?? 0) + (tokRow?["c"] as? Int ?? 0)
            let coeff = cst ?? 0
            let costS = coeff > 0.0001 ? "$\(String(format: "%.2f", coeff))" : "~$0"
            let nlv = nl ?? 0
            let cplS = nlv > 0 && coeff > 0 ? "$\(String(format: "%.3f", coeff / Double(nlv)))/line" : ""
            let sum = cplS.isEmpty ? "📊 \(cnt) calls · \(fmt(totalT)) tokens · \(costS)" : "📊 \(cnt) calls · \(fmt(totalT)) tokens · \(costS) · \(cplS)"

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
        w.title = "AI Pulse Preferences"; w.contentView = NSHostingView(rootView: SettingsView()); w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
        SettingsWindowManager.shared.window = w
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
