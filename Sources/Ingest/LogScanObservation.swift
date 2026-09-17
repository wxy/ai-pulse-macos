import Foundation

/// Runtime scanner availability, not provider-wide usage completeness.
final class LogScanObservation: @unchecked Sendable {
    static let shared = LogScanObservation()
    static let didChange = Notification.Name("logScanObservationDidChange")
    enum Status: Equatable { case inactive, scanning, available, stale, failed }
    private let lock = NSLock()
    private var active = false
    private var scanning = false
    private var completedAt: Date?

    func begin() {
        lock.lock(); active = true; scanning = true; lock.unlock()
        notify()
    }

    func finish(at date: Date = Date()) {
        lock.lock(); scanning = false; completedAt = date; lock.unlock()
        notify()
    }

    func stop() {
        lock.lock(); active = false; scanning = false; lock.unlock()
        notify()
    }

    func status(now: Date = Date(), hasReadFailure: Bool, maxAge: TimeInterval = 120) -> Status {
        lock.lock(); defer { lock.unlock() }
        guard active else { return .inactive }
        if hasReadFailure { return .failed }
        if scanning { return .scanning }
        guard let completedAt else { return .inactive }
        let age = now.timeIntervalSince(completedAt)
        return age >= 0 && age <= maxAge ? .available : .stale
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }
}
