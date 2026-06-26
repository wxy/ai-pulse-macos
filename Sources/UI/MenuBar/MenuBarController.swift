import AppKit
import SwiftUI
import GRDB

/// Holds a reference to the Preferences window so it stays alive
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
        if let button = statusItem.button {
            button.title = "🤖"
        }

        menu = NSMenu()
        summaryItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(.separator())
        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshStats()
        }
        refreshStats()
    }

    private func refreshStats() {
        Task {
            let stats = await fetchTodayStats()
            DispatchQueue.main.async {
                self.summaryItem.title = stats.summary
                // Remove old submenu items
                for item in self.modelItems { self.menu.removeItem(item) }
                self.modelItems.removeAll()

                if !stats.models.isEmpty {
                    let byModel = NSMenuItem(title: "▸ By Model", action: nil, keyEquivalent: "")
                    let mSub = NSMenu()
                    for m in stats.models {
                        let cplStr = stats.netLines > 0 ? " · $\(String(format: "%.3f", m.cost / Double(stats.netLines)))/line" : ""
                        mSub.addItem(NSMenuItem(title: "\(m.name)  ·  \(m.costStr)\(cplStr)", action: nil, keyEquivalent: ""))
                    }
                    byModel.submenu = mSub
                    self.menu.insertItem(byModel, at: self.menu.numberOfItems - 2)
                    self.modelItems.append(byModel)
                }

                if !stats.repos.isEmpty {
                    let byRepo = NSMenuItem(title: "▸ By Repo", action: nil, keyEquivalent: "")
                    let rSub = NSMenu()
                    for r in stats.repos {
                        rSub.addItem(NSMenuItem(title: "\(r.name) · \(r.lines) lines · \(r.cplStr)", action: nil, keyEquivalent: ""))
                    }
                    byRepo.submenu = rSub
                    self.menu.insertItem(byRepo, at: self.menu.numberOfItems - 2)
                    self.modelItems.append(byRepo)
                }

                if let button = self.statusItem.button {
                    button.title = stats.hasActivity ? "💬" : "🤖"
                }
            }
        }
    }

    private struct ModelStat {
        let name: String; let calls: Int; let tokens: Int; let cost: Double
        var costStr: String { cost > 0.0001 ? "$\(String(format: "%.2f", cost))" : "~$0" }
    }
    private struct RepoStat {
        let name: String; let lines: Int; let cost: Double
        var cplStr: String { lines > 0 ? "$\(String(format: "%.3f", cost / Double(lines)))/line" : "-" }
    }

    private struct Stats {
        let summary: String; let cpl: String; let models: [ModelStat]; let repos: [RepoStat]; let netLines: Int; let hasActivity: Bool
    }

    private func fetchTodayStats() async -> Stats {
        do {
            let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
            let count: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event WHERE ts >= ?", arguments: [todayStart]) ?? 0
            }
            let tokens: (Int, Int, Int)? = try await AppDatabase.shared.read { db in
                try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(in_tokens),0) AS inp, COALESCE(SUM(out_tokens),0) AS outp, COALESCE(SUM(cache_tokens),0) AS cache FROM usage_event WHERE ts >= ?", arguments: [todayStart]).map { ($0["inp"], $0["outp"], $0["cache"]) }
            }
            let cost: Double? = try await AppDatabase.shared.read { db in
                try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_event WHERE ts >= ?", arguments: [todayStart])
            }

            // Per-model breakdown
            let rows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT COALESCE(model,'unknown') as model, COUNT(*) as cnt,
                           COALESCE(SUM(in_tokens+out_tokens+cache_tokens),0) as tok,
                           COALESCE(SUM(cost_usd),0) as cst
                    FROM usage_event WHERE ts >= ?
                    GROUP BY model ORDER BY cst DESC
                    """, arguments: [todayStart])
            }
            let models: [ModelStat] = rows.map { row in
                ModelStat(name: row["model"] ?? "unknown",
                          calls: row["cnt"] ?? 0,
                          tokens: row["tok"] ?? 0,
                          cost: row["cst"] ?? 0)
            }

            // Per-repo cost (all-time), keyed by repo_path
            let repoCostRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT repo_path AS path, COALESCE(SUM(cost_usd),0) AS cost
                    FROM usage_event WHERE repo_path IS NOT NULL
                    GROUP BY repo_path
                    """)
            }
            var costByRepo: [String: Double] = [:]
            for row in repoCostRows {
                let path: String = row["path"] ?? ""
                guard !path.isEmpty else { continue }
                costByRepo[path] = row["cost"] ?? 0
            }

            // Per-repo net lines (all-time). Use typed subscripts: GRDB's untyped
            // subscript returns DatabaseValueConvertible? (boxing Int64), so `as? Int`
            // would always be nil and silently drop every repo.
            let repoRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT repo_path AS path, COALESCE(SUM(added - deleted),0) AS lines
                    FROM code_change WHERE is_merge = 0
                    GROUP BY repo_path ORDER BY lines DESC
                    """)
            }
            let repos: [RepoStat] = repoRows.compactMap { row -> RepoStat? in
                let path: String = row["path"] ?? ""
                let lines: Int = row["lines"] ?? 0
                guard lines > 0 else { return nil }
                let name = URL(fileURLWithPath: path).lastPathComponent
                return RepoStat(name: name, lines: lines, cost: costByRepo[path] ?? 0)
            }

            // Net lines (all-time)
            let netLines: Int? = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(added - deleted),0) FROM code_change WHERE is_merge = 0")
            }

            let totalT = (tokens?.0 ?? 0) + (tokens?.1 ?? 0) + (tokens?.2 ?? 0)

            if count == 0 && repos.isEmpty {
                return Stats(summary: "No AI usage recorded today", cpl: "", models: [], repos: [], netLines: 0, hasActivity: false)
            }
            if count == 0 {
                return Stats(summary: "No AI usage today · \(repos.count) repos tracked", cpl: "", models: [], repos: repos, netLines: netLines ?? 0, hasActivity: true)
            }
            let costStr: String
            if let cost, cost > 0.0001 { costStr = "$\(String(format: "%.2f", cost))" }
            else { costStr = "~$0" }
            let cplStr: String
            if let lines = netLines, lines > 0, let cost, cost > 0 {
                let cpl = cost / Double(lines)
                cplStr = "$\(String(format: "%.3f", cpl))/line"
            } else {
                cplStr = ""
            }
            let summaryLine = if !cplStr.isEmpty {
                "📊 \(count) calls · \(formatNumber(totalT)) tokens · \(costStr) · \(cplStr)"
            } else {
                "📊 \(count) calls · \(formatNumber(totalT)) tokens · \(costStr)"
            }
            return Stats(
                summary: summaryLine, cpl: cplStr,
                models: models, repos: repos, netLines: netLines ?? 0, hasActivity: true
            )
        } catch {
            return Stats(summary: "Stats unavailable", cpl: "", models: [], repos: [], netLines: 0, hasActivity: false)
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return "\(n / 1_000_000).\( (n % 1_000_000) / 100_000)M" }
        if n >= 1_000 { return "\(n / 1_000).\( (n % 1_000) / 100)K" }
        return "\(n)"
    }

    @objc private func openPreferences() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let settingsView = SettingsView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "AI Pulse Preferences"
        window.setContentSize(NSSize(width: 600, height: 400))
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        SettingsWindowManager.shared.window = window
        window.isReleasedWhenClosed = false
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
