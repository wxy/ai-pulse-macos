import AppKit

/// Dock icon with a "gauge arc" overlay that fills as daily spend grows.
///
/// Arc colors: green (normal), orange (>1.5x daily avg), red (>3x).
/// The arc fills clockwise from the 7-o'clock position; a full circle
/// represents 3× the 7-day daily average.
final class DockManager {
    static let shared = DockManager()
    private var timer: Timer?
    private let baseIcon: NSImage = AppIconLoader.load()

    func start() {
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
                let dailyAvg = prediction.dailyRate

                // No spend today → reset to plain icon, no arc
                guard todayCost > 0.001 else {
                    tile.badgeLabel = nil
                    NSApp.applicationIconImage = self.baseIcon
                    return
                }
                tile.badgeLabel = todayCost < 10
                    ? "$\(String(format: "%.2f", todayCost))"
                    : "$\(String(format: "%.0f", todayCost))"

                // Gauge arc: how much of the daily budget is spent?
                let fillFraction: CGFloat
                let arcColor: NSColor

                if dailyAvg > 0 {
                    let ratio = todayCost / dailyAvg
                    if ratio > 3 {
                        fillFraction = 1.0
                        arcColor = .systemRed
                    } else if ratio > 1.5 {
                        fillFraction = CGFloat(ratio / 3.0)
                        arcColor = .systemOrange
                    } else if ratio > 0.01 {
                        fillFraction = CGFloat(ratio / 3.0)
                        arcColor = .systemGreen
                    } else {
                        fillFraction = 0
                        arcColor = .clear
                    }
                } else {
                    fillFraction = 0
                    arcColor = .clear
                }

                NSApp.applicationIconImage = iconWithArc(fill: fillFraction, color: arcColor)
            }
        }
    }

    /// Draw the base icon with a coloured arc segment around its outer ring.
    private func iconWithArc(fill: CGFloat, color: NSColor) -> NSImage {
        let size = baseIcon.size
        let image = NSImage(size: size, flipped: false) { rect in
            // 1. Base icon
            self.baseIcon.draw(in: rect)

            guard fill > 0, color != .clear else { return true }

            // 2. Arc overlay — matches the icon's own ring geometry.
            //    Source icon: 1024×1024, ring Ø=960 (r=480), stroke=48
            //    Scale factor relative to render size (e.g. 128 for Dock).
            let scale = size.width / 1024.0
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius: CGFloat = 480 * scale      // ring midline radius
            let lineWidth: CGFloat = 48 * scale     // ring stroke width

            let path = NSBezierPath()
            let startAngle: CGFloat = 135           // 7 o'clock
            let sweepAngle: CGFloat = 360 * fill    // full circle at 3× daily avg
            path.appendArc(
                withCenter: center, radius: radius,
                startAngle: startAngle, endAngle: startAngle + sweepAngle,
                clockwise: true
            )
            color.setStroke()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.stroke()

            return true
        }
        return image
    }
}
