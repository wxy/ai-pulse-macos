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
            button.font = NSFont.systemFont(ofSize: 14)
        }

        menu = NSMenu()
        summaryItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        menu.addItem(summaryItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.separator())
        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        menu.addItem(.separator())
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
                // Remove old model items
                for item in self.modelItems {
                    self.menu.removeItem(item)
                }
                self.modelItems.removeAll()

                // Insert model breakdown after summary
                let afterSummary = self.menu.index(of: self.summaryItem) + 2 // skip separator
                for m in stats.models.reversed() {
                    let item = NSMenuItem(title: "  \(m.name)  ·  \(m.costStr)", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    self.menu.insertItem(item, at: afterSummary)
                    self.modelItems.append(item)
                }

                if let button = self.statusItem.button {
                    button.title = stats.hasActivity ? "💬" : "🤖"
                }
            }
        }
    }

    private struct ModelStat {
        let name: String
        let calls: Int
        let tokens: Int
        let cost: Double
        var costStr: String {
            if cost > 0.0001 { return "$\(String(format: "%.2f", cost))" }
            return "~$0"
        }
    }

    private struct Stats {
        let summary: String
        let models: [ModelStat]
        let hasActivity: Bool
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

            if count == 0 {
                return Stats(summary: "No AI usage recorded today", models: [], hasActivity: false)
            }
            let totalT = (tokens?.0 ?? 0) + (tokens?.1 ?? 0) + (tokens?.2 ?? 0)
            let costStr: String
            if let cost, cost > 0.0001 { costStr = "$\(String(format: "%.2f", cost))" }
            else { costStr = "~$0" }
            return Stats(
                summary: "📊 \(count) calls · \(formatNumber(totalT)) tokens · \(costStr)",
                models: models, hasActivity: true
            )
        } catch {
            return Stats(summary: "Stats unavailable", models: [], hasActivity: false)
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
