import Foundation

/// Centralized scheduler that replaces scattered independent timers.
///
/// Three ingestion phases run at staggered intervals:
/// - Phase 1 (30s): LogWatcher incremental scan + RepoDiscovery
/// - Phase 2 (5min): GitMonitor commit polling
/// - Phase 3 (1h): ApiPoller balance fetching
///
/// Ingestion modules push-change notifications to the coordinator when they
/// successfully write new data. The coordinator applies a 500ms debounce and
/// posts `.dataDidChange` to notify all UI consumers.
final class DataRefreshCoordinator: @unchecked Sendable {
    static let shared = DataRefreshCoordinator()

    private var phase1Timer: DispatchSourceTimer?
    private var phase2Timer: DispatchSourceTimer?
    private var phase3Timer: DispatchSourceTimer?
    private var pendingNotifyWorkItem: DispatchWorkItem?
    private var lastNotifyTime: Date = .distantPast
    private let notifyQueue = DispatchQueue(label: "com.wxy.aipulse.coordinator", qos: .utility)

    /// Minimum interval between consecutive .dataDidChange posts.
    /// Prevents the staggered startup phases (5s/10s/15s) and rapid
    /// multi-source writes from triggering a storm of notifications.
    private let minNotifyInterval: TimeInterval = 3.0

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

        Logger.info("DataRefreshCoordinator: started (P1=30s, P2=5min, P3=1h)")
    }

    func stop() {
        phase1Timer?.cancel(); phase1Timer = nil
        phase2Timer?.cancel(); phase2Timer = nil
        phase3Timer?.cancel(); phase3Timer = nil
        pendingNotifyWorkItem?.cancel(); pendingNotifyWorkItem = nil
        lastNotifyTime = .distantPast
        Logger.info("DataRefreshCoordinator: stopped")
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
        let start = Date()
        LogWatcher.shared.scan()
        let discovered = RepoDiscovery.scan()
        let elapsed = Date().timeIntervalSince(start)
        Logger.debug("Phase1 ingest completed in \(String(format: "%.3f", elapsed))s, discovered=\(discovered)")
        if discovered > 0 {
            Logger.info("RepoDiscovery: found \(discovered) new repo(s)")
        }
        // LogWatcher.insertEvent() pushes notifyPhaseIngest() on successful write
    }

    private func runPhase2() {
        let start = Date()
        GitMonitor.shared.poll()
        Logger.debug("Phase2 git scan completed in \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        // GitMonitor.insertChange() pushes notifyPhaseGitScan() on successful write
    }

    private func runPhase3() {
        let start = Date()
        ApiPoller.shared.pollAll()
        Logger.debug("Phase3 balance poll dispatched in \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        // ApiPoller.cacheBalance() pushes notifyPhaseBalance() on successful write
    }

    // MARK: - Push-change notification (called by ingestion modules)

    /// Called by LogWatcher after a usage_event row is inserted.
    func notifyPhaseIngest() {
        notifyQueue.async { [weak self] in
            self?.scheduleUINotify()
        }
    }

    /// Called by GitMonitor after a code_change row is inserted.
    func notifyPhaseGitScan() {
        notifyQueue.async { [weak self] in
            self?.scheduleUINotify()
        }
    }

    /// Called by ApiPoller after a balance_snapshot row is inserted.
    func notifyPhaseBalance() {
        notifyQueue.async { [weak self] in
            self?.scheduleUINotify()
        }
    }

    // MARK: - Debounce & dispatch

    private func scheduleUINotify() {
        pendingNotifyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.notifyConsumers()
        }
        pendingNotifyWorkItem = workItem
        notifyQueue.asyncAfter(deadline: .now() + .milliseconds(500), execute: workItem)
    }

    private func notifyConsumers() {
        let now = Date()
        guard now.timeIntervalSince(lastNotifyTime) >= minNotifyInterval else {
            Logger.debug("DataRefreshCoordinator: suppressing notify (last was \(String(format: "%.1f", now.timeIntervalSince(lastNotifyTime)))s ago)")
            return
        }
        lastNotifyTime = now
        Logger.debug("DataRefreshCoordinator: posting .dataDidChange")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .dataDidChange, object: nil)
            CoinSound.playForDataChange()
        }
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
