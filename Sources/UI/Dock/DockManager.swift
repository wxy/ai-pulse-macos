import AppKit

/// Shows today's AI spend on the Dock tile — a mini "fuel gauge".
/// Updates every 60 seconds.
final class DockManager {
    static let shared = DockManager()
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        Task {
            let stats = await StatsService.dailyStats(days: 1)
            let todayCost = stats.first?.cost ?? 0
            let prediction = await StatsService.prediction()

            await MainActor.run {
                let tile = NSApp.dockTile
                if todayCost > 0.0001 {
                    let text = todayCost < 10
                        ? "$\(String(format: "%.2f", todayCost))"
                        : "$\(String(format: "%.0f", todayCost))"
                    tile.badgeLabel = text

                    // Color alert: red if today > 3x daily avg, yellow if > 1.5x
                    let dailyAvg = prediction.dailyRate
                    if dailyAvg > 0 && todayCost > dailyAvg * 3 {
                        NSApp.applicationIconImage = coloredIcon(.systemRed)
                    } else if dailyAvg > 0 && todayCost > dailyAvg * 1.5 {
                        NSApp.applicationIconImage = coloredIcon(.systemOrange)
                    } else {
                        NSApp.applicationIconImage = nil
                    }
                } else {
                    tile.badgeLabel = nil
                    NSApp.applicationIconImage = nil
                }
            }
        }
    }

    private func coloredIcon(_ color: NSColor) -> NSImage? {
        guard let img = NSApp.applicationIconImage?.copy() as? NSImage else { return nil }
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }
}
