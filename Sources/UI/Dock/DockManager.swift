import AppKit

/// Shows today's AI spend on the Dock tile — a mini "fuel gauge".
/// Uses a gauge SF Symbol as the base icon, tinted by spend level.
final class DockManager {
    static let shared = DockManager()
    private var timer: Timer?
    private let baseIcon: NSImage = AppIconLoader.load()

    func start() {
        // Set base icon immediately
        NSApp.applicationIconImage = baseIcon
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

                    // Tint by alert level
                    let dailyAvg = prediction.dailyRate
                    let color: NSColor?
                    if dailyAvg > 0 && todayCost > dailyAvg * 3 { color = .systemRed }
                    else if dailyAvg > 0 && todayCost > dailyAvg * 1.5 { color = .systemOrange }
                    else { color = nil }

                    if let c = color {
                        NSApp.applicationIconImage = tintedIcon(baseIcon, with: c)
                    } else {
                        NSApp.applicationIconImage = baseIcon
                    }
                } else {
                    tile.badgeLabel = nil
                    NSApp.applicationIconImage = baseIcon
                }
            }
        }
    }

    private func tintedIcon(_ image: NSImage, with color: NSColor) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }
}
