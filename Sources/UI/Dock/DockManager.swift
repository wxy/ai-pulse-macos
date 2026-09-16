import AppKit
import AIPulseShared

/// Dock icon with a ring driven by the current unit-free Pulse score. Money is
/// intentionally absent: the Dock communicates pressure, not an inferred bill.
final class DockManager: @unchecked Sendable {
    static let shared = DockManager()
    private var lastPulseTime: Date = .distantPast
    private let baseIcon: NSImage = AppIconLoader.load()
    private var dataChangeObserver: NSObjectProtocol?
    private var healthObserver: NSObjectProtocol?
    private var pulseObserver: NSObjectProtocol?
    private var healthSeverity: AppHealthMonitor.Severity = .nominal

    func start() {
        // Observe health changes for progress bar colour
        healthObserver = NotificationCenter.default.addObserver(
            forName: .appHealthDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let snap = AppHealthMonitor.shared.current
                self.healthSeverity = snap.severity
                await self.setProgressIcon()
            }
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
        pulseObserver = NotificationCenter.default.addObserver(
            forName: .pulseDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { [weak self] in await self?.refreshPulseAppearance() }
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
        if let token = pulseObserver {
            NotificationCenter.default.removeObserver(token)
            pulseObserver = nil
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
        guard healthSeverity < .critical else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
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
    private func refreshPulseAppearance() async {
        // Pulse ticks include natural time decay. Recompute both colour and
        // length so the Dock cannot retain a stale full ring between data writes.
        await refresh()
    }

    @MainActor
    private func refresh() async {
        // Guard against test environment where NSApp may not be available
        guard NSApp != nil else { return }
        let snapshot = await PulseEngine.shared.snapshot()
        let ringColor = Self.tierRingColor(for: snapshot?.tier)
        let fillFraction = Self.pulseFillFraction(snapshot)
        Logger.debug("Dock pulse: tier=\(snapshot?.tier.rawValue ?? "resting") fillFraction=\(String(format: "%.2f", fillFraction))")

        let tile = NSApp.dockTile
        tile.badgeLabel = nil
        guard fillFraction > 0.001 else {
            NSApp.applicationIconImage = AppIconLoader.load(healthDot: healthSeverity)
            tile.display()
            _cachedProgressFraction = 0
            _cachedLap = 0
            _cachedRingColor = ringColor
            return
        }

        NSApp.applicationIconImage = AppIconLoader.load(
            progress: fillFraction, lap: 0, healthDot: healthSeverity,
            ringColor: ringColor)
        tile.display()

        _cachedProgressFraction = fillFraction
        _cachedLap = 0
        _cachedRingColor = ringColor
    }

    /// The primary signal keeps all surfaces visually aligned while activity
    /// remains the fallback when another channel is unavailable. Three times
    /// baseline nearly closes the ring; a small gap remains so an intense Pulse
    /// still reads as live progress instead of a permanent coloured border.
    nonisolated static func pulseFillFraction(_ snapshot: PulseSnapshot?) -> Double {
        guard let snapshot else { return 0 }
        let primary = snapshot.primarySignal.flatMap { kind in
            snapshot.signals.first { $0.kind == kind }
        }
        let score = primary?.normalized ?? snapshot.activity?.normalized ?? 0
        guard score.isFinite else { return 0 }
        return min(max(score / 3, 0), 0.92)
    }

    /// Dock ring colours (§3.3 绿→金→橙→红); cold keeps the legacy green so a
    /// quiet day never renders the ring in alarm colours.
    nonisolated private static func tierRingColor(for tier: PulseTier?) -> NSColor {
        switch tier {
        case .intense: return .systemRed
        case .elevated: return .systemOrange
        case .active: return .systemYellow
        case .resting, .none: return .systemGreen
        }
    }

    private var _cachedProgressFraction: Double = 0
    private var _cachedLap: Int = 0
    @MainActor private var _cachedRingColor: NSColor = .systemGreen

    /// Re-render the progress icon after a pulse animation completes.
    @MainActor
    private func setProgressIcon() async {
        // Test environment: NSApp may be nil; the delayed start() task can reach
        // this without an NSApplication. Sibling refresh()/pulseIcon() guard too.
        guard NSApp != nil else { return }
        if _cachedProgressFraction > 0.001 {
            NSApp.applicationIconImage = AppIconLoader.load(
                progress: _cachedProgressFraction, lap: _cachedLap, healthDot: healthSeverity,
                ringColor: _cachedRingColor)
        } else {
            NSApp.applicationIconImage = AppIconLoader.load(healthDot: healthSeverity)
        }
    }

}
