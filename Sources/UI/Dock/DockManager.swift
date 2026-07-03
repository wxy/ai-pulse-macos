import AppKit

/// Dock icon with a green progress bar along the rounded-rect border that
/// fills as daily spend grows.
///
/// The bar starts at the 3 o'clock position and fills clockwise; a full loop
/// represents 3× the 30-day daily average. "Spend" here is the combined figure
/// (API balance spend + subscription amortization) shown on the Dashboard.
final class DockManager {
    static let shared = DockManager()
    private var currentTask: Task<Void, Never>?
    private var lastPulseTime: Date = .distantPast
    private let baseIcon: NSImage = AppIconLoader.load()

    func start() {
        refresh()
        // Observe data-change notifications from the centralized coordinator
        NotificationCenter.default.addObserver(
            forName: Notification.Name.dataDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
            self?.pulseIcon()
        }
    }

    func stop() {
        currentTask?.cancel(); currentTask = nil
        NotificationCenter.default.removeObserver(self)
    }

    /// Animate the Dock icon with a brief scale pulse to signal new data.
    /// Throttled to at most once every 2 seconds.
    func pulseIcon() {
        let now = Date()
        guard now.timeIntervalSince(lastPulseTime) >= 2.0 else { return }
        lastPulseTime = now

        let tile = NSApp.dockTile
        if let view = tile.contentView {
            view.wantsLayer = true
            let anim = CAKeyframeAnimation(keyPath: "transform.scale")
            anim.values = [1.0, 1.15, 1.0]
            anim.keyTimes = [0, 0.5, 1.0]
            anim.duration = 0.3
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.layer?.add(anim, forKey: "pulse")
        }
        tile.display()
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
