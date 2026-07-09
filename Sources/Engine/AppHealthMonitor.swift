import Foundation
import UserNotifications

/// Aggregates health status across all subsystems and posts
/// `.appHealthDidChange` when severity changes.
///
/// Consumers (Dashboard error banner, Dock progress-bar colour)
/// observe the notification and query `current` for the latest state.
final class AppHealthMonitor: @unchecked Sendable {
    static let shared = AppHealthMonitor()

    enum Severity: Int, Comparable, Sendable {
        case nominal  = 0   // everything ok
        case degraded = 1   // partial failure, most data available
        case impaired = 2   // significant data missing
        case critical = 3   // DB unreachable, no data at all

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Snapshot: Sendable {
        let severity: Severity
        let messages: [String]   // most recent error descriptions, newest last
        let hasDBError: Bool
        let hasAPIError: Bool
        let hasStatsError: Bool
    }

    private let lock = NSLock()
    private var _severity: Severity = .nominal
    private var _messages: [String] = []
    private var _hasDBError = false
    private var _apiErrors = Set<String>()  // provider IDs currently failing
    private var _hasStatsError = false

    /// Thread-safe read of the current snapshot.
    var current: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            severity: _severity,
            messages: _messages,
            hasDBError: _hasDBError,
            hasAPIError: !_apiErrors.isEmpty,
            hasStatsError: _hasStatsError
        )
    }

    /// Provider IDs currently failing balance/API fetches (thread-safe).
    var failingProviders: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return _apiErrors
    }

    private init() {}

    // MARK: - Reporting

    /// Report a database-level error (DB not set up, migration failure).
    func reportDBError(_ message: String) {
        update(severity: .critical, message: message, category: .db)
    }

    /// Report an API-level error (balance fetch failed for a specific provider).
    /// Pass the provider ID (e.g. "deepseek") so errors are tracked per-provider.
    func reportAPIError(providerId: String, message: String) {
        update(severity: .degraded, providerId: providerId, message: message, category: .api)
    }

    /// Report a stats query failure.
    func reportStatsError(_ message: String) {
        update(severity: .impaired, message: message, category: .stats)
    }

    /// Clear a specific category (called when things recover).
    func clearDBError()  { clear(category: .db) }
    func clearAPIError(providerId: String) { clear(category: .api, providerId: providerId) }
    func clearAPIErrors() { clear(category: .api) }  // clear all
    func clearStatsError() { clear(category: .stats) }

    /// Reset everything to nominal (call on startup).
    func reset() {
        lock.lock()
        _severity = .nominal
        _messages = []
        _hasDBError = false
        _apiErrors.removeAll()
        _hasStatsError = false
        lock.unlock()
    }

    // MARK: - Internal

    private enum Category { case db, api, stats }

    private func update(severity newSeverity: Severity, providerId: String = "",
                        message: String, category: Category) {
        let oldSeverity: Severity
        let severityChanged: Bool
        lock.lock()
        oldSeverity = _severity
        _severity = max(_severity, newSeverity)
        switch category {
        case .db:    _hasDBError = true
        case .api:   _apiErrors.insert(providerId)
        case .stats: _hasStatsError = true
        }
        // Deduplicate: skip if the last message is identical
        if _messages.last != message {
            _messages.append(message)
            if _messages.count > 20 { _messages.removeFirst(_messages.count - 20) }
        }
        severityChanged = (_severity != oldSeverity)
        lock.unlock()

        if severityChanged {
            Logger.warning("HealthMonitor: severity \(oldSeverity) → \(_severity) — \(message)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .appHealthDidChange, object: nil)
            }
            if _severity == .critical {
                sendCriticalNotification(message: message)
            }
        }
        // Even if severity didn't change, new messages should refresh the UI
        if !severityChanged {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .appHealthDidChange, object: nil)
            }
        }
    }

    private func clear(category: Category, providerId: String = "") {
        lock.lock()
        switch category {
        case .db:    _hasDBError = false
        case .api:
            if providerId.isEmpty {
                _apiErrors.removeAll()
            } else {
                _apiErrors.remove(providerId)
                // Remove stale messages for this provider
                _messages.removeAll { $0.hasPrefix("\(providerId):") }
            }
        case .stats: _hasStatsError = false
        }
        let prev = _severity
        _severity = recomputeSeverity()
        lock.unlock()
        if _severity != prev {
            Logger.info("HealthMonitor: severity \(prev) → \(_severity) (cleared)")
        }
        // Always notify so the UI refreshes (messages may have changed)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .appHealthDidChange, object: nil)
        }
    }

    private func sendCriticalNotification(message: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "AI Pulse"
        content.body = message
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "ai-pulse-health-critical",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    private func recomputeSeverity() -> Severity {
        if _hasDBError { return .critical }
        if _hasStatsError { return .impaired }
        if !_apiErrors.isEmpty { return .degraded }
        return .nominal
    }
}

extension Notification.Name {
    /// Posted when AppHealthMonitor.severity changes.
    static let appHealthDidChange = Notification.Name("AIPulseAppHealthDidChange")
}
