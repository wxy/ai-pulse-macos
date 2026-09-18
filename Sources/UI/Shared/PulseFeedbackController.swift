import AppKit
import AIPulseShared

extension Notification.Name {
    static let pulseBeatDidChange = Notification.Name("PulseBeatDidChange")
    static let pulseAppearanceDidChange = Notification.Name("PulseAppearanceDidChange")
}

/// A single clock/gate for both visual surfaces. Data refresh, launch, quotas
/// and Git updates never manufacture a consumption beat. No continuous loop.
@MainActor
final class PulseFeedbackController {
    static let shared = PulseFeedbackController()
    static let minimumInterval: TimeInterval = 2
    static let durationNanoseconds: UInt64 = 320_000_000
    private var observer: NSObjectProtocol?
    private var refreshObservers: [NSObjectProtocol] = []
    private var generation = 0
    private let loadSnapshot: @Sendable () async -> PulseSnapshot?
    private var finishTask: Task<Void, Never>?
    private var lastBeat = Date.distantPast
    private(set) var isBeating = false
    private(set) var snapshot: PulseSnapshot?

    init(loadSnapshot: @escaping @Sendable () async -> PulseSnapshot? = { await PulseEngine.shared.snapshot() }) {
        self.loadSnapshot = loadSnapshot
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .consumptionDidOccur, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                self?.beat()
            }
        }
        for name in [Notification.Name.dataDidChange, .pulseDidChange] {
            refreshObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor in await self?.refresh() }
            })
        }
        Task { await refresh() }
    }

    /// Publish once; the two renderers never independently select a tier.
    func refresh() async {
        guard observer != nil else { return }
        generation &+= 1
        let request = generation
        let fresh = await loadSnapshot()
        guard request == generation, observer != nil else { return }
        snapshot = fresh?.isCurrent() == true ? fresh : nil
        NotificationCenter.default.post(name: .pulseAppearanceDidChange, object: nil)
    }

    @discardableResult
    func beat(at now: Date = Date()) -> Bool {
        guard now.timeIntervalSince1970.isFinite,
              now.timeIntervalSince(lastBeat) >= Self.minimumInterval else { return false }
        lastBeat = now
        finishTask?.cancel()
        isBeating = true
        NotificationCenter.default.post(name: .pulseBeatDidChange, object: nil)
        finishTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Self.durationNanoseconds) }
            catch { return }
            guard let self else { return }
            self.isBeating = false
            NotificationCenter.default.post(name: .pulseBeatDidChange, object: nil)
        }
        return true
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        refreshObservers.forEach { NotificationCenter.default.removeObserver($0) }
        refreshObservers.removeAll()
        generation &+= 1
        snapshot = nil
        finishTask?.cancel()
        finishTask = nil
        lastBeat = .distantPast
        isBeating = false
        NotificationCenter.default.post(name: .pulseAppearanceDidChange, object: nil)
        NotificationCenter.default.post(name: .pulseBeatDidChange, object: nil)
    }
}
