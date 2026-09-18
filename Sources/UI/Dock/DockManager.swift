import AppKit
import AIPulseShared

/// The robot lamp shares the menu flame's state, palette and observation beat,
/// without converting activity into a budget ring or replacing the robot art.
@MainActor
final class DockManager {
    static let shared = DockManager()
    private var observers: [NSObjectProtocol] = []
    private var renderedKey: String?

    func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.pulseAppearanceDidChange, .pulseBeatDidChange, .appHealthDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor in self?.render() }
            })
        }
        render()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        renderedKey = nil
    }

    private func render() {
        guard NSApp != nil, !observers.isEmpty else { return }
        let snapshot = PulseFeedbackController.shared.snapshot
        let appearance = PulseAppearance(tier: snapshot?.isCurrent() == true ? snapshot?.tier : nil,
                                         cooling: snapshot?.activity?.freshness == .aging)
        let health = AppHealthMonitor.shared.current.severity
        let beat = PulseFeedbackController.shared.isBeating &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && health < .critical
        let key = "\(appearance.tier?.rawValue ?? "unknown")|\(appearance.cooling)|\(health.rawValue)|\(beat)"
        guard key != renderedKey else { return }
        renderedKey = key
        NSApp.dockTile.badgeLabel = nil
        NSApp.applicationIconImage = AppIconLoader.pulseIcon(appearance: appearance, beat: beat, healthDot: health)
        NSApp.dockTile.display()
    }
}
