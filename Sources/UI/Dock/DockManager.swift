import AppKit

/// Dock icon with a progress bar along the rounded-rect border that
/// fills as daily spend grows. The bar colour reflects system health:
/// green (ok), yellow (degraded), orange (impaired), red (critical).
///
/// The bar starts at the 3 o'clock position and fills clockwise; a full loop
/// represents 3× the 30-day daily average.
final class DockManager: @unchecked Sendable {
    static let shared = DockManager()
    private var lastPulseTime: Date = .distantPast
    private let baseIcon: NSImage = AppIconLoader.load()
    private var dataChangeObserver: NSObjectProtocol?
    private var healthObserver: NSObjectProtocol?
    private var healthSeverity: AppHealthMonitor.Severity = .nominal

    func start() {
        // Observe health changes for progress bar colour
        healthObserver = NotificationCenter.default.addObserver(
            forName: .appHealthDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let snap = AppHealthMonitor.shared.current
            self.healthSeverity = snap.severity
            Task { await self.setProgressIcon() }
        }

        Task {
            // Initial refresh sets the progress icon
            await refresh()
            // Pulse once on launch so the user sees the app is alive
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await pulseIcon()
            // Restore progress after pulse (pulse overwrites with base frames)
            await setProgressIcon()
        }
        // Observe data-change notifications from the centralized coordinator
        dataChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.dataDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                // Refresh first to compute the latest progress icon
                await self.refresh()
                // Pulse the freshly-set progress icon
                await self.pulseIcon()
                // Restore progress icon after pulse animation finishes
                await self.setProgressIcon()
            }
        }
    }

    func stop() {
        if let token = dataChangeObserver {
            NotificationCenter.default.removeObserver(token)
            dataChangeObserver = nil
        }
        if let token = healthObserver {
            NotificationCenter.default.removeObserver(token)
            healthObserver = nil
        }
    }

    // MARK: - Pulse

    /// Animate the Dock icon with a scale-pulse + gold-flash overlay.
    /// The current `applicationIconImage` (set by refresh) is captured
    /// and restored after the animation.
    /// Throttled to at most once every 2 seconds.
    @MainActor
    func pulseIcon() async {
        guard NSApp != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPulseTime) >= 2.0 else { return }
        lastPulseTime = now

        // Pre-render the pulse frames (scale-up + gold tint overlay)
        let frames: [(scale: CGFloat, tint: CGFloat)] = [
            (1.00, 0.0),
            (1.15, 0.3),
            (1.30, 0.6),
            (1.15, 0.3),
        ]
        let images = frames.map { AppIconLoader.pulseFrame(scale: $0.scale, tintAmount: $0.tint) }

        let frameDuration: UInt64 = 80_000_000 // 80ms in nanoseconds
        for img in images {
            try? await Task.sleep(nanoseconds: frameDuration)
            NSApp.applicationIconImage = img
        }
    }

    // MARK: - Refresh

    @MainActor
    private func refresh() async {
        // Guard against test environment where NSApp may not be available
        guard NSApp != nil else { return }
        let todayStartMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        let todayCost = await StatsService.combinedSpend(sinceMs: todayStartMs)
        let dailyAvg = await rollingDailyAvg()

        // Cache progress state so setProgressIcon can recompute later
        let fillFraction: CGFloat
        if dailyAvg > 0 {
            fillFraction = min(CGFloat(todayCost / dailyAvg / 3.0), 1.0)
        } else {
            fillFraction = 0
        }

        let tile = NSApp.dockTile

        guard todayCost > 0.001 else {
            NSApp.applicationIconImage = self.baseIcon
            tile.badgeLabel = nil
            tile.display()
            return
        }

        NSApp.applicationIconImage = AppIconLoader.load(
            progress: Double(fillFraction), barColor: progressBarColor)
        tile.badgeLabel = "$\(String(format: "%.2f", todayCost))"
        tile.display()
        Logger.debug("Dock badge set: \(tile.badgeLabel ?? "nil") todayCost=\(todayCost)")

        _cachedProgressFraction = Double(fillFraction)
    }

    private var _cachedProgressFraction: Double = 0

    /// Re-render the progress icon after a pulse animation completes.
    @MainActor
    private func setProgressIcon() async {
        if _cachedProgressFraction > 0.001 {
            NSApp.applicationIconImage = AppIconLoader.load(
                progress: _cachedProgressFraction, barColor: progressBarColor)
        } else {
            NSApp.applicationIconImage = baseIcon
        }
    }

    /// Progress bar colour reflects system health so the user can tell at a glance
    /// whether the data is reliable.
    private var progressBarColor: NSColor {
        switch healthSeverity {
        case .nominal:  return .systemGreen
        case .degraded: return .systemYellow
        case .impaired: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// 30-day rolling daily average of combined spend (API + subscription amortization).
    private func rollingDailyAvg() async -> Double {
        // Compute average based on days that actually have spend data,
        // not a fixed 30-day divisor.  When the user is new (only a few
        // days of history), dividing by 30 makes the average artificially
        // tiny → progress bar instantly maxes out.
        let stats = (try? await StatsService.dailyStats(days: 30)) ?? []
        let daysWithSpend = stats.filter { $0.cost > 0.001 }.count
        guard daysWithSpend > 0 else { return 0 }
        let total = stats.reduce(0.0) { $0 + $1.cost }
        return total / Double(daysWithSpend)
    }
}
