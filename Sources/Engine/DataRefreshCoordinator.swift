import Foundation
import GRDB

/// Centralized scheduler that replaces scattered independent timers.
///
/// Three ingestion phases run at staggered intervals:
/// - Phase 1 (30s): LogWatcher incremental scan + RepoDiscovery
/// - Phase 2 (5min): GitMonitor commit polling
/// - Phase 3 (1h): ApiPoller balance fetching
///
/// After any phase detects changes, a 500ms debounce window coalesces
/// rapid-fire writes before posting `.dataDidChange` to notify all UI consumers.
final class DataRefreshCoordinator {
    static let shared = DataRefreshCoordinator()

    enum Phase {
        case ingest, gitScan, balance
    }

    private var phase1Timer: DispatchSourceTimer?
    private var phase2Timer: DispatchSourceTimer?
    private var phase3Timer: DispatchSourceTimer?
    private var pendingNotifyWorkItem: DispatchWorkItem?
    private let notifyQueue = DispatchQueue(label: "com.wxy.aipulse.coordinator", qos: .utility)

    private init() {}

    // MARK: - Public

    func start() {
        // Phase 1: Ingest (30s, first after 5s)
        phase1Timer = makeTimer(interval: .seconds(30), firstDeadline: .now() + 5) { [weak self] in
            self?.runPhase1()
        }

        // Phase 2: Git scan (5min, first after 15s)
        phase2Timer = makeTimer(interval: .seconds(300), firstDeadline: .now() + 15) { [weak self] in
            self?.runPhase2()
        }

        // Phase 3: Balance poll (1h, first after 10s)
        phase3Timer = makeTimer(interval: .seconds(3600), firstDeadline: .now() + 10) { [weak self] in
            self?.runPhase3()
        }

        diagLog("DataRefreshCoordinator: started (P1=30s, P2=5min, P3=1h)")
    }

    func stop() {
        phase1Timer?.cancel(); phase1Timer = nil
        phase2Timer?.cancel(); phase2Timer = nil
        phase3Timer?.cancel(); phase3Timer = nil
        pendingNotifyWorkItem?.cancel(); pendingNotifyWorkItem = nil
        diagLog("DataRefreshCoordinator: stopped")
    }

    /// Called by external triggers (e.g., Settings adds a new directory)
    /// to force an immediate ingest scan.
    func triggerIngest() {
        notifyQueue.async { [weak self] in
            self?.runPhase1()
        }
    }

    /// External callers can explicitly notify consumers (e.g., after
    /// on-demand polling by ApiPoller.fetchNow).
    func notifyDataChange() {
        notifyQueue.async { [weak self] in
            self?.scheduleUINotify()
        }
    }

    // MARK: - Phase runners

    private func runPhase1() {
        let countBefore = countUsageEvents()
        LogWatcher.shared.scan()
        let discovered = RepoDiscovery.scan()
        if discovered > 0 {
            diagLog("RepoDiscovery: found \(discovered) new repo(s)")
        }
        let countAfter = countUsageEvents()
        let changed = countAfter > countBefore || discovered > 0
        phaseDidComplete(.ingest, changesDetected: changed)
    }

    private func runPhase2() {
        let countBefore = countCodeChanges()
        GitMonitor.shared.poll()
        let countAfter = countCodeChanges()
        phaseDidComplete(.gitScan, changesDetected: countAfter > countBefore)
    }

    private func runPhase3() {
        let countBefore = countBalanceSnapshots()
        ApiPoller.shared.pollAll()
        // Balance snapshots are written async via URLSession callbacks.
        // Wait a short grace period then check for changes.
        notifyQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            let countAfter = self.countBalanceSnapshots()
            self.phaseDidComplete(.balance, changesDetected: countAfter > countBefore)
        }
    }

    // MARK: - Change detection

    private func phaseDidComplete(_ phase: Phase, changesDetected: Bool) {
        guard changesDetected else { return }
        diagLog("DataRefreshCoordinator: phase \(phase) detected changes")
        scheduleUINotify()
    }

    private func scheduleUINotify() {
        pendingNotifyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.notifyConsumers()
        }
        pendingNotifyWorkItem = workItem
        notifyQueue.asyncAfter(deadline: .now() + .milliseconds(500), execute: workItem)
    }

    private func notifyConsumers() {
        diagLog("DataRefreshCoordinator: posting .dataDidChange")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .dataDidChange, object: nil)
            CoinSound.playForDataChange()
        }
    }

    // MARK: - Row counters (lightweight change detection)

    private func countUsageEvents() -> Int {
        let sem = DispatchSemaphore(value: 0)
        var count = 0
        Task {
            do {
                count = try await AppDatabase.shared.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event") ?? 0
                }
            } catch { }
            sem.signal()
        }
        sem.wait()
        return count
    }

    private func countCodeChanges() -> Int {
        let sem = DispatchSemaphore(value: 0)
        var count = 0
        Task {
            do {
                count = try await AppDatabase.shared.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM code_change") ?? 0
                }
            } catch { }
            sem.signal()
        }
        sem.wait()
        return count
    }

    private func countBalanceSnapshots() -> Int {
        let sem = DispatchSemaphore(value: 0)
        var count = 0
        Task {
            do {
                count = try await AppDatabase.shared.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM balance_snapshot") ?? 0
                }
            } catch { }
            sem.signal()
        }
        sem.wait()
        return count
    }

    // MARK: - Timer factory

    private func makeTimer(interval: DispatchTimeInterval,
                           firstDeadline: DispatchTime,
                           handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: notifyQueue)
        timer.schedule(deadline: firstDeadline, repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }
}
