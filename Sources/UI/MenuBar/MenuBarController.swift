import AppKit
import GRDB

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🤖"
            button.font = NSFont.systemFont(ofSize: 14)
        }

        let menu = NSMenu()
        let statsItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        menu.addItem(statsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        // Refresh stats every 30 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshStats(menu, statsItem: statsItem)
        }
        refreshStats(menu, statsItem: statsItem)
    }

    private func refreshStats(_ menu: NSMenu, statsItem: NSMenuItem) {
        Task {
            let stats = await fetchTodayStats()
            DispatchQueue.main.async {
                statsItem.title = stats
                if let button = self.statusItem.button {
                    button.title = stats.contains("💬") || stats.contains("0 tokens") ? "🤖" : "💬"
                }
            }
        }
    }

    private func fetchTodayStats() async -> String {
        do {
            let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
            let count: Int = try await AppDatabase.shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event WHERE ts >= ?", arguments: [todayStart]) ?? 0
            }
            let tokens: (Int, Int, Int)? = try await AppDatabase.shared.read { db in
                try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(in_tokens),0) AS inp, COALESCE(SUM(out_tokens),0) AS outp, COALESCE(SUM(cache_tokens),0) AS cache FROM usage_event WHERE ts >= ?", arguments: [todayStart]).map { row in
                    (row["inp"], row["outp"], row["cache"])
                }
            }

            if count == 0 {
                return "No AI usage recorded today"
            }
            let total = (tokens?.0 ?? 0) + (tokens?.1 ?? 0) + (tokens?.2 ?? 0)
            // Rough cost estimate: ~$3/M input, $15/M output (Claude Sonnet)
            let estCost = (Double(tokens?.0 ?? 0) * 3.0 + Double(tokens?.1 ?? 0) * 15.0) / 1_000_000
            return "\(count) calls · \(formatNumber(total)) tokens · ~$\(String(format: "%.2f", estCost))"
        } catch {
            return "Stats unavailable"
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return "\(n / 1_000_000).\( (n % 1_000_000) / 100_000)M" }
        if n >= 1_000 { return "\(n / 1_000).\( (n % 1_000) / 100)K" }
        return "\(n)"
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
