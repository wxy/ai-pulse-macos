import AppKit
import Foundation

/// Injected phase-1 ingestion actions so tests can drive the coordinator
/// without touching real log directories, repository scans, or status caches.
struct IngestActions: Sendable {
    var scanLogs: @Sendable () -> Void
    var scanRepos: @Sendable () -> Int
    var refreshClaudeStatus: @Sendable () -> Void

    static let live = IngestActions(
        scanLogs: { LogWatcher.shared.scan() },
        scanRepos: { RepoDiscovery.scan() },
        refreshClaudeStatus: { UsageMonitor.shared.refreshClaudeStatus() }
    )

    static let noop = IngestActions(
        scanLogs: {},
        scanRepos: { 0 },
        refreshClaudeStatus: {}
    )
}

/// Centralized scheduler that replaces scattered independent timers.
///
/// Three ingestion phases run at staggered intervals:
/// - Phase 1 (30s): LogWatcher incremental scan + RepoDiscovery
/// - Phase 2 (5min): GitMonitor commit polling
/// - Phase 3 (1h): ApiPoller balance fetching
/// - Phase 4 (5min): Refresh dashboard cache (all 3 time ranges) for iCloud sync
///
/// Ingestion modules push-change notifications to the coordinator when they
/// successfully write new data. The coordinator applies a 500ms debounce and
/// posts `.dataDidChange` to notify all UI consumers.
nonisolated final class DataRefreshCoordinator: @unchecked Sendable {
    static let shared = DataRefreshCoordinator()
    private let actions: IngestActions

    private var phase1Timer: DispatchSourceTimer?
    private var phase2Timer: DispatchSourceTimer?
    private var phase3Timer: DispatchSourceTimer?
    private var phase4Timer: DispatchSourceTimer?
    private var pendingNotifyWorkItem: DispatchWorkItem?
    private var pendingPlaySound = false  // sticky: true if any caller wants sound
    private var lastNotifyTime: Date = .distantPast
    private let notifyQueue = DispatchQueue(label: "com.wxy.aipulse.coordinator", qos: .utility)
    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var stopped = false
    /// Formatted today spend at the last sound-triggered notification.
    /// Compared against the current formatted value so the coin sound only
    /// plays when the dock badge label would actually change.
    private var lastSoundBadgeLabel: String = ""

    /// Minimum interval between consecutive .dataDidChange posts.
    /// Prevents the staggered startup phases (5s/10s/15s) and rapid
    /// multi-source writes from triggering a storm of notifications.
    private let minNotifyInterval: TimeInterval = 3.0

    init(actions: IngestActions = .live) {
        self.actions = actions
    }

    // MARK: - Public

    func start() {
        stopped = false
        // One-time session metadata backfill for logs that predate the
        // session_info table (runs once, guarded internally).
        SessionInfoBackfill.runIfNeeded()
        recreateTimers()

        Logger.info("DataRefreshCoordinator: started (P1=30s, P2=5min, P3=1h)")

        // Pause timers when screen(s) turn off — covers both display sleep
        // and system sleep (which always sleeps screens first).  Multi-display
        // safe: NSWorkspace.screensDidSleepNotification fires only when the
        // entire display subsystem powers down (all screens off).
        let nc = NSWorkspace.shared.notificationCenter
        screenSleepObserver = nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendTimers()
            }
        }
        screenWakeObserver = nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeTimers()
            }
        }
    }

    func stop() {
        if let o = screenSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = screenWakeObserver  { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        screenSleepObserver = nil; screenWakeObserver = nil
        cancelAllTimers()
        stopped = true
        pendingPlaySound = false
        lastNotifyTime = .distantPast
        Logger.info("DataRefreshCoordinator: stopped")
    }

    // MARK: - Sleep / wake

    private var timersSuspended = false

    private func suspendTimers() {
        guard !timersSuspended else { return }
        timersSuspended = true
        cancelAllTimers()
        Logger.debug("DataRefreshCoordinator: timers suspended (system sleeping)")
    }

    private func resumeTimers() {
        guard timersSuspended else { return }
        timersSuspended = false
        recreateTimers()
        Logger.info("DataRefreshCoordinator: timers resumed (system woke)")
    }

    private func cancelAllTimers() {
        phase1Timer?.cancel(); phase1Timer = nil
        phase2Timer?.cancel(); phase2Timer = nil
        phase3Timer?.cancel(); phase3Timer = nil
        phase4Timer?.cancel(); phase4Timer = nil
        pendingNotifyWorkItem?.cancel(); pendingNotifyWorkItem = nil
        notifyTask?.cancel(); notifyTask = nil
    }

    private func recreateTimers() {
        // Timer callbacks fire on notifyQueue (utility). Hop to MainActor
        // since runPhase* methods are MainActor-isolated.
        phase1Timer = makeTimer(interval: .seconds(30), firstDeadline: .now() + 5) { [weak self] in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.runPhase1() } }
        }
        phase2Timer = makeTimer(interval: .seconds(300), firstDeadline: .now() + 15) { [weak self] in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.runPhase2() } }
        }
        phase3Timer = makeTimer(interval: .seconds(3600), firstDeadline: .now() + 10) { [weak self] in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.runPhase3() } }
        }
        phase4Timer = makeTimer(interval: .seconds(300), firstDeadline: .now() + 20) { [weak self] in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.runPhase4() } }
        }
    }

    func triggerIngest() {
        notifyQueue.async { [weak self] in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.runPhase1() } }
        }
    }

    func notifyDataChange() {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.scheduleUINotify() } }
    }

    // MARK: - Phase runners

    private func runPhase1() {
        let start = Date()
        actions.scanLogs()
        let discovered = actions.scanRepos()
        actions.refreshClaudeStatus()
        let elapsed = Date().timeIntervalSince(start)
        Logger.debug("Phase1 ingest completed in \(String(format: "%.3f", elapsed))s, discovered=\(discovered)")
        if discovered > 0 {
            Logger.info("RepoDiscovery: found \(discovered) new repo(s)")
        }
        // Heartbeat: always notify UI so dock icon stays current (pulses),
        // but without coin sound unless LogWatcher inserted actual new data.
        scheduleUINotify(playSound: false)
        // LogWatcher.insertEvent() pushes notifyPhaseIngest() with playSound: true
    }

    private func runPhase2() {
        let start = Date()
        GitMonitor.shared.poll()
        Logger.debug("Phase2 git scan completed in \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        // Heartbeat (no sound unless GitMonitor found new commits).
        scheduleUINotify(playSound: false)
        // GitMonitor.insertChange() pushes notifyPhaseGitScan() with playSound: true
    }

    private func runPhase3() {
        let start = Date()
        ApiPoller.shared.pollAll()
        UsageMonitor.shared.refreshCopilotStatus()
        Logger.debug("Phase3 balance poll dispatched in \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        // Heartbeat (no sound unless ApiPoller found balance changes).
        scheduleUINotify(playSound: false)
        // ApiPoller.cacheBalance() pushes notifyPhaseBalance() with playSound: true
    }

    /// Phase 4: Refresh dashboard cache for all three time ranges.
    /// Runs every 5 min in the background, independent of Dashboard open state.
    /// Ensures iCloud sync always has fresh data for iOS/watchOS.
    private func runPhase4() {
        Task.detached(priority: .background) {
            let now = Date().timeIntervalSince1970
            // Per-range throttles: today=5min, week=1h, 30d=12h
            let intervals: [(String, Int, TimeInterval)] = [
                ("today", 1, 300), ("week", 7, 3600), ("30d", 30, 43200)
            ]
            // Compute actual weekDays
                        let sTodayStart = Calendar.current.startOfDay(for: Date())
            let weekDays = Calendar.current.dateComponents([.day], from: Calendar.mondayOfWeek(), to: sTodayStart).day! + 1
            let dayMap: [String: Int] = ["today": 1, "week": weekDays, "30d": 30]

            for (key, _, interval) in intervals {
                let lastKey = "cache_refresh_\(key)"
                let last = UserDefaults.standard.double(forKey: lastKey)
                guard now - last >= interval else { continue }
                UserDefaults.standard.set(now, forKey: lastKey)
                let snap = await StatsService.dashboardSnapshot(days: dayMap[key] ?? 1)
                await DashboardCache.write(timeRange: key, json: snap.jsonString())
            }

            await CloudSyncService.shared.syncFromCache()
            Task { @MainActor in Logger.debug("Phase 4 refreshed") }
        }
    }

    // MARK: - Push-change notification (called by ingestion modules)

    /// Called by LogWatcher after a usage_event row is inserted.
    func notifyPhaseIngest() {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.scheduleUINotify(playSound: true) } }
    }

    /// Called by GitMonitor after a code_change row is inserted.
    func notifyPhaseGitScan() {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.scheduleUINotify(playSound: true) } }
    }

    /// Called by ApiPoller after a balance_snapshot row is inserted.
    func notifyPhaseBalance() {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.scheduleUINotify(playSound: true) } }
    }

    // MARK: - Debounce & dispatch

    private var notifyTask: Task<Void, Never>?

    private func scheduleUINotify(playSound: Bool = false) {
        guard !stopped else { return }
        if playSound { pendingPlaySound = true }
        notifyTask?.cancel()
        let shouldPlay = pendingPlaySound
        notifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.pendingPlaySound = false
            self.notifyConsumers(playSound: shouldPlay)
        }
    }

    private func notifyConsumers(playSound: Bool = false) {
        let now = Date()
        guard now.timeIntervalSince(lastNotifyTime) >= minNotifyInterval else {
            Logger.debug("DataRefreshCoordinator: suppressing notify (last was \(String(format: "%.1f", now.timeIntervalSince(lastNotifyTime)))s ago)")
            return
        }
        lastNotifyTime = now
        Logger.debug("DataRefreshCoordinator: posting .dataDidChange\(playSound ? " + sound" : "")")
        NotificationCenter.default.post(name: .dataDidChange, object: nil)

        guard playSound else { return }
        Task { @MainActor in
            let todayStartMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
            let spend = await StatsService.combinedSpend(sinceMs: todayStartMs)
            let label = "$\(String(format: "%.2f", spend))"
            if label != lastSoundBadgeLabel {
                lastSoundBadgeLabel = label
                CoinSound.playForDataChange()
            } else {
                Logger.debug("DataRefreshCoordinator: suppressing sound — badge unchanged at \(label)")
            }
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
