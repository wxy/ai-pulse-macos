import AppKit

/// Dock icon with a green progress bar along the rounded-rect border that
/// fills as daily spend grows.
///
/// The bar starts at the 3 o'clock position and fills clockwise; a full loop
/// represents 3× the 30-day daily average. "Spend" here is the combined figure
/// (API balance spend + subscription amortization) shown on the Dashboard.
final class DockManager {
    static let shared = DockManager()
    private var timer: Timer?
    private var currentTask: Task<Void, Never>?
    private let baseIcon: NSImage = AppIconLoader.load()

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        currentTask?.cancel(); currentTask = nil
    }

    /// 30-day rolling daily average of combined spend (API + subscription amortization).
    private func rollingDailyAvg() async -> Double {
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: Date())) else { return 0 }
        let total = await StatsService.combinedSpend(sinceMs: Int64(start.timeIntervalSince1970 * 1000))
        return total / 30.0
    }

    private func refresh() {
        currentTask = Task {
            let todayStartMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
            let todayCost = await StatsService.combinedSpend(sinceMs: todayStartMs)
            let dailyAvg = await rollingDailyAvg()

            await MainActor.run {
                let tile = NSApp.dockTile

                guard todayCost > 0.001 else {
                    NSApp.applicationIconImage = self.baseIcon
                    tile.badgeLabel = nil
                    tile.display()
                    return
                }

                // Green bar fills the icon border as today's spend approaches
                // 3× the 30-day daily average (capped at 100%).
                let fillFraction: CGFloat
                if dailyAvg > 0 {
                    let ratio = todayCost / dailyAvg
                    fillFraction = min(CGFloat(ratio / 3.0), 1.0)
                } else {
                    fillFraction = 0
                }

                NSApp.applicationIconImage = AppIconLoader.load(progress: Double(fillFraction))
                tile.badgeLabel = "$\(String(format: "%.2f", todayCost))"
                tile.display()
                diagLog("Dock badge set: \(tile.badgeLabel ?? "nil") todayCost=\(todayCost)")
            }
        }
    }
}
