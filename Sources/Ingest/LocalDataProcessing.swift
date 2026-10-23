import Foundation

/// Ownership of queued and running local work, independent of whether a
/// previous scan or cached snapshot is already usable.
nonisolated final class LocalDataProcessing: @unchecked Sendable {
    static let shared = LocalDataProcessing()
    static let didChange = Notification.Name("localDataProcessingDidChange")

    enum Stage: Int, Sendable {
        case preparing, reading, parsing

        var message: String {
            switch self {
            case .reading: return I18n.t("processing.reading")
            case .parsing: return I18n.t("processing.parsing")
            case .preparing: return I18n.t("processing.preparing")
            }
        }
    }

    final class Activity: Sendable {
        private let owner: LocalDataProcessing
        private let id: UUID
        fileprivate init(owner: LocalDataProcessing, id: UUID) { self.owner = owner; self.id = id }
        func update(_ stage: Stage) { owner.update(id, stage: stage) }
        func finish() { owner.update(id, stage: nil) }
        deinit { finish() }
    }

    private let lock = NSLock()
    private var work: [UUID: Stage] = [:]
    private var notificationPending = false

    var stage: Stage? { lock.withLock { currentStage } }
    private var currentStage: Stage? { work.values.max { $0.rawValue < $1.rawValue } }

    func begin(_ stage: Stage) -> Activity {
        let id = UUID()
        lock.withLock {
            let previous = currentStage
            work[id] = stage
            if currentStage != previous { notifyLocked() }
        }
        return Activity(owner: self, id: id)
    }

    private func update(_ id: UUID, stage: Stage?) {
        lock.withLock {
            guard work[id] != nil else { return } // late callbacks cannot revive finished work
            let previous = currentStage
            work[id] = stage
            if currentStage != previous { notifyLocked() }
        }
    }

    /// Coalesce fast per-file transitions instead of flooding the UI queue.
    private func notifyLocked() {
        guard !notificationPending else { return }
        notificationPending = true
        DispatchQueue.main.async { [self] in
            lock.withLock { notificationPending = false }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}
