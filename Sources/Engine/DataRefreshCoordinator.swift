import AppKit
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
    private var pendingPlaySound = false  // sticky: true if any caller wants sound
    private var lastNotifyTime: Date = .distantPast
    private let notifyQueue = DispatchQueue(label: "com.wxy.aipulse.coordinator", qos: .utility)
    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    /// Formatted today spend at the last sound-triggered notification.
    /// Compared against the current formatted value so the coin sound only
    /// plays when the dock badge label would actually change.
    private var lastSoundBadgeLabel: String = ""

    /// Minimum interval between consecutive .dataDidChange posts.
    /// Prevents the staggered startup phases (5s/10s/15s) and rapid
    /// multi-source writes from triggering a storm of notifications.
    private let minNotifyInterval: TimeInterval = 3.0

    private init() {}

    // MARK: - Public

    func start() {
        recreateTimers()

        Logger.info("DataRefreshCoordinator: started (P1=30s, P2=5min, P3=1h)")

        // Pause timers when screen(s) turn off — covers both display sleep
        // and system sleep (which always sleeps screens first).  Multi-display
        // safe: NSWorkspace.screensDidSleepNotification fires only when the
        // entire display subsystem powers down (all screens off).
        let nc = NSWorkspace.shared.notificationCenter
        screenSleepObserver = nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.suspendTimers()
        }
        screenWakeObserver = nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            self?.resumeTimers()
        }
    }

    func stop() {
        if let o = screenSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = screenWakeObserver  { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        screenSleepObserver = nil; screenWakeObserver = nil
        cancelAllTimers()
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
        pendingNotifyWorkItem?.cancel(); pendingNotifyWorkItem = nil
    }

    private func recreateTimers() {
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
        UsageMonitor.shared.refreshClaudeStatus()
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

    // MARK: - Push-change notification (called by ingestion modules)

    /// Called by LogWatcher after a usage_event row is inserted.
    func notifyPhaseIngest() {
        notifyQueue.async { [weak self] in
            self?.scheduleUINotify(playSound: true)
        }
    }

    /// Called by GitMonitor after a code_change row is inserted.
    func notifyPhaseGitScan() {
        notifyQueue.async { [weak self] in
            self?.scheduleUINotify(playSound: true)
        }
    }

    /// Called by ApiPoller after a balance_snapshot row is inserted.
    func notifyPhaseBalance() {
        notifyQueue.async { [weak self] in
            self?.scheduleUINotify(playSound: true)
        }
    }

    // MARK: - Debounce & dispatch

    private func scheduleUINotify(playSound: Bool = false) {
        if playSound { pendingPlaySound = true }  // sticky: any caller can request sound
        pendingNotifyWorkItem?.cancel()
        let shouldPlay = pendingPlaySound
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingPlaySound = false
            self?.notifyConsumers(playSound: shouldPlay)
        }
        pendingNotifyWorkItem = workItem
        notifyQueue.asyncAfter(deadline: .now() + .milliseconds(500), execute: workItem)
    }

    private func notifyConsumers(playSound: Bool = false) {
        let now = Date()
        guard now.timeIntervalSince(lastNotifyTime) >= minNotifyInterval else {
            Logger.debug("DataRefreshCoordinator: suppressing notify (last was \(String(format: "%.1f", now.timeIntervalSince(lastNotifyTime)))s ago)")
            return
        }
        lastNotifyTime = now
        Logger.debug("DataRefreshCoordinator: posting .dataDidChange\(playSound ? " + sound" : "")")
        DispatchQueue.main.async { [weak self] in
            NotificationCenter.default.post(name: .dataDidChange, object: nil)
            guard let self, playSound else { return }
            // Only play coin sound when the dock badge label would change.
            // Uses the same formatting as DockManager.swift:120 so sound
            // exactly mirrors visible badge updates.
            Task {
                let todayStartMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
                let spend = await StatsService.combinedSpend(sinceMs: todayStartMs)
                let label = "$\(String(format: "%.2f", spend))"
                if label != self.lastSoundBadgeLabel {
                    self.lastSoundBadgeLabel = label
                    CoinSound.playForDataChange()
                } else {
                    Logger.debug("DataRefreshCoordinator: suppressing sound — badge unchanged at \(label)")
                }
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
