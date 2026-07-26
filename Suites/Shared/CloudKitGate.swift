import Foundation
import os

/// Serializes every iCloud/CloudKit network operation triggered from the iOS
/// app so that at most one is ever in flight, with an enforced minimum gap
/// between them, and de-duplicates redundant fetches of the same key within
/// a short window.
///
/// Background: on some devices (confirmed: iPhone SE 2nd gen) a burst of
/// concurrent CloudKit/APNs-adjacent network operations — most commonly seen
/// during app launch, when several independent code paths (push
/// registration, notification-permission + CK subscription setup, the
/// initial "today" fetch, and `DashboardView`'s `onAppear` fetch) all hit the
/// network within the same fraction of a second — has been observed to
/// trigger a *silent* Wi-Fi drop: the interface stays associated but stops
/// passing traffic and does not recover on its own. This looks like a Wi-Fi
/// firmware/driver issue on the affected hardware (there is no public API to
/// repair it once it happens), so the only thing under our control is
/// removing the trigger condition: overlapping/duplicate network bursts of
/// our own making.
///
/// Every call site that talks to CloudKit from the iOS app is already
/// `@MainActor`, so this gate is `@MainActor` too. That keeps everything on
/// one serial executor and avoids cross-actor `Sendable` friction while
/// still giving us a single, app-wide serialization point.
@MainActor
final class CloudKitGate {
    static let shared = CloudKitGate()

    private static let log = Logger(subsystem: "com.wxy.aipulse", category: "CloudKitGate")

    /// Minimum wall-clock spacing enforced between the end of one gated
    /// operation and the start of the next.
    private let minSpacingNanos: UInt64 = 600_000_000 // 600ms

    /// How long a completed fetch is considered fresh enough that a
    /// duplicate request for the same key can be skipped outright instead of
    /// hitting the network again.
    private let dedupeWindow: TimeInterval = 3

    private var lastOperationEnd: DispatchTime?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var recentKeys: [String: Date] = [:]

    private init() {}

    /// Marks `key` as freshly fetched without running an operation. Lets a
    /// caller whose fetch happens outside the gate (e.g. `hasData()`, which
    /// must always run) still suppress a near-immediate duplicate elsewhere
    /// (e.g. `DashboardView.onAppear` re-fetching the same range).
    func markRecentlyFetched(_ key: String) {
        recentKeys[key] = Date()
    }

    /// Runs `operation` after any in-flight gated operation completes, and
    /// after waiting out the minimum spacing since the previous one ended.
    @discardableResult
    func run<T>(_ label: String, _ operation: () async throws -> T) async throws -> T {
        await acquire()
        defer { lastOperationEnd = .now(); release() }

        if let last = lastOperationEnd {
            let elapsed = DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds
            if elapsed < minSpacingNanos {
                let waitMs = (minSpacingNanos - elapsed) / 1_000_000
                Self.log.debug("gate: spacing \(waitMs, privacy: .public)ms before '\(label, privacy: .public)'")
                try? await Task.sleep(nanoseconds: minSpacingNanos - elapsed)
            }
        }
        Self.log.debug("gate: running '\(label, privacy: .public)'")
        return try await operation()
    }

    /// Like `run`, but skips entirely (returning `nil`) if `key` was already
    /// completed within the dedupe window — prevents e.g. two near-
    /// simultaneous fetches of the same time range from both hitting the
    /// network.
    @discardableResult
    func runDeduped<T>(_ label: String, dedupeKey key: String, _ operation: () async throws -> T) async throws -> T? {
        if let last = recentKeys[key], Date().timeIntervalSince(last) < dedupeWindow {
            Self.log.debug("gate: skip '\(label, privacy: .public)' — deduped")
            return nil
        }
        recentKeys[key] = Date() // mark immediately (before any await) to close the race
        return try await run(label, operation)
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
