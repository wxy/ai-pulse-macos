import AppKit
import Foundation
import AIPulseShared
import GRDB

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

/// One newly observed AI activity occurrence. It gates sound playback; amounts
/// are retained for factual context but no longer grade the sound.
struct ConsumptionEvent {
    var spendUSD: Double?
    var tokens: Int?
    var source: String

    var isEmpty: Bool { (spendUSD ?? 0) <= 0 && (tokens ?? 0) <= 0 }
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
    private let invalidateDashboardCache: @Sendable () async -> Void
    private let playConsumption: @MainActor @Sendable ([ConsumptionEvent], PulseSnapshot?) -> Void

    private var phase1Timer: DispatchSourceTimer?
    private var phase2Timer: DispatchSourceTimer?
    private var phase3Timer: DispatchSourceTimer?
    private var phase4Timer: DispatchSourceTimer?
    private var pulseTimer: DispatchSourceTimer?
    private var pendingNotifyWorkItem: DispatchWorkItem?
    /// Consumption events accumulated across debounce/suppression windows.
    /// Main-thread only: every writer hops through DispatchQueue.main.async.
    private var pendingEvents: [ConsumptionEvent] = []
    private var pendingConsumptionBeat = false
    private var lastNotifyTime: Date = .distantPast
    private let notifyQueue = DispatchQueue(label: "com.wxy.aipulse.coordinator", qos: .utility)
    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var stopped = false
    private(set) var isRunning = false
    var isSuspended: Bool { timersSuspended }

    /// Minimum interval between consecutive .dataDidChange posts.
    /// Prevents the staggered startup phases (5s/10s/15s) and rapid
    /// multi-source writes from triggering a storm of notifications.
    private let minNotifyInterval: TimeInterval = 3.0

    init(actions: IngestActions = .live,
         invalidateDashboardCache: @escaping @Sendable () async -> Void = { await DashboardCache.invalidateAll() },
         playConsumption: @escaping @MainActor @Sendable ([ConsumptionEvent], PulseSnapshot?) -> Void = {
             CoinSound.play(events: $0, pulse: $1)
         }) {
        self.actions = actions
        self.invalidateDashboardCache = invalidateDashboardCache
        self.playConsumption = playConsumption
    }

    // MARK: - Public

    func start() {
        guard !isRunning else { return }
        isRunning = true
        stopped = false
        timersSuspended = false
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
        isRunning = false
        timersSuspended = false
        pendingEvents.removeAll()
        pendingConsumptionBeat = false
        lastNotifyTime = .distantPast
        Logger.info("DataRefreshCoordinator: stopped")
    }

    // MARK: - Sleep / wake

    private var timersSuspended = false

    private func suspendTimers() {
        guard isRunning, !timersSuspended else { return }
        timersSuspended = true
        cancelAllTimers()
        Logger.debug("DataRefreshCoordinator: timers suspended (system sleeping)")
        DiagnosticJournal.log("sleep", ["timers_suspended": .bool(true)])
    }

    private func resumeTimers() {
        guard isRunning, timersSuspended else { return }
        timersSuspended = false
        recreateTimers()
        Logger.info("DataRefreshCoordinator: timers resumed (system woke)")
        DiagnosticJournal.log("wake", ["timers_resumed": .bool(true)])
    }

    private func cancelAllTimers() {
        phase1Timer?.cancel(); phase1Timer = nil
        phase2Timer?.cancel(); phase2Timer = nil
        phase3Timer?.cancel(); phase3Timer = nil
        phase4Timer?.cancel(); phase4Timer = nil
        pulseTimer?.cancel(); pulseTimer = nil
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
        // Pulse decay is time-based. This cheap tick only invalidates the
        // derived snapshot and refreshes perception consumers; it never scans
        // sources or plays sound.
        pulseTimer = makeTimer(interval: .seconds(30), firstDeadline: .now() + 30) { [weak self] in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.runPulseTick() } }
        }
    }

    func triggerIngest() {
        notifyQueue.async { [weak self] in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.runPhase1() } }
        }
    }

    /// Explicit refresh requested by the macOS widget. Collection finishes
    /// before caches and the local widget payload are rebuilt, so neither the
    /// widget nor CloudKit receives the pre-refresh snapshot.
    @MainActor
    func refreshFromMacWidget() async {
        let startedAt = Date()
        await LogWatcher.shared.scanAndWait()
        _ = RepoDiscovery.scan()
        await GitMonitor.shared.pollAndWait()
        await DashboardCache.invalidateAll()

        for period in [DashboardPeriodKind.today, .week, .days30] {
            let snapshot = await StatsService.dashboardSnapshot(period: period)
            await DashboardCache.write(timeRange: period.rawValue, json: snapshot.jsonString())
        }

        NotificationCenter.default.post(name: .dataDidChange, object: nil)
        NotificationCenter.default.post(name: .dashboardRefresh, object: nil)
        await CloudSyncService.shared.syncFromCache()
        Logger.info(
            "MacWidget: explicit refresh completed in "
                + String(format: "%.3f", Date().timeIntervalSince(startedAt)) + "s"
        )
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
        // LogWatcher.insertEvent() pushes notifyPhaseIngest() with playSound: true
        maybeRingClosingBell()
    }

    // MARK: - WI-7: closing bell (日终收盘)

    /// Lazy daily check riding the 30s phase-1 tick — no new timer. Fires at
    /// most once per calendar day, and only when an observed fact is available.
    private func maybeRingClosingBell() {
        let d = UserDefaults.standard
        guard d.object(forKey: "closing_bell_enabled") as? Bool ?? true else { return }
        let now = Date()
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        let dayKey = String(Int64(dayStart.timeIntervalSince1970 * 1000))
        guard d.string(forKey: "closing_bell_last_fired") != dayKey else { return }
        let minutesNow = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let closingMinutes = SoundSettings.parseHM(d.string(forKey: "closing_bell_time") ?? "21:30")
            ?? 21 * 60 + 30
        guard minutesNow >= closingMinutes else { return }
        Task { @MainActor in
            let todayStartMs = Int64(dayStart.timeIntervalSince1970 * 1000)
            async let observed = StatsService.observedSpendItems(sinceMs: todayStartMs)
            async let quota = StatsService.latestQuotaStatus()
            let endMs = Int64(now.timeIntervalSince1970 * 1000) + 1
            async let codeOutput = StatsService.authorizedCodeOutput(sinceMs: todayStartMs, beforeMs: endMs)
            async let counts = AppDatabase.shared.read { db in
                let tokens = try Int64.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(\(TokenAccounting.observedTotalSQL)), 0)
                    FROM usage_event WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>')
                    """, arguments: [todayStartMs, endMs]) ?? 0
                return tokens
            }
            let pulse = await PulseEngine.shared.snapshot()
            let (spend, quotas, output) = await (observed, quota, try? counts)
            let code = try? await codeOutput
            let freshQuota = quotas.filter {
                !$0.isStale(asOf: now) && $0.utilization.isFinite && (0...100).contains($0.utilization)
            }.map(\.utilization).max()
            let summary = ClosingBellSummary(
                tier: pulse?.tier ?? .resting,
                reason: pulse?.reason ?? "no_recent_signal",
                activityTokens: output,
                observedSpend: spend,
                quotaPercent: freshQuota,
                changedLines: code.map { $0.added + $0.deleted },
                commits: code?.commits)
            guard summary.hasActivity else { return }
            // Concurrent slow reads may finish after another daily task. Claim
            // on the main actor immediately before firing, without an await.
            guard ClosingBell.claimDailyDelivery(for: dayStart) else { return }
            await ClosingBell.fire(summary: summary, at: now)
        }
    }

    private func runPhase2() {
        let start = Date()
        GitMonitor.shared.poll()
        Logger.debug("Phase2 git scan completed in \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        // GitMonitor.insertChange() pushes notifyPhaseGitScan() with playSound: true
    }

    private func runPhase3() {
        let start = Date()
        ApiPoller.shared.pollAll()
        UsageMonitor.shared.refreshCopilotStatus()
        Logger.debug("Phase3 balance poll dispatched in \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        // ApiPoller.cacheBalance() pushes notifyPhaseBalance() with playSound: true
    }

    /// Phase 4: Refresh dashboard cache for all three time ranges.
    /// Runs every 5 min in the background, independent of Dashboard open state.
    /// Ensures iCloud sync always has fresh data for iOS/watchOS.
    private func runPhase4() {
        // A cold database may still be backfilling years of JSONL at the 20s
        // startup mark. Never let that partial view become a fresh cache entry;
        // the next five-minute tick runs after history import has settled.
        guard !LogWatcher.backfill.isActive else { return }
        Task.detached(priority: .background) {
            let now = Date().timeIntervalSince1970
            // Per-range throttles: today=5min, week=1h, 30d=12h
            let intervals: [(String, Int, TimeInterval)] = [
                ("today", 1, 300), ("week", 7, 3600), ("30d", 30, 43200)
            ]
            for (key, _, interval) in intervals {
                let lastKey = "cache_refresh_\(key)"
                let last = UserDefaults.standard.double(forKey: lastKey)
                guard now - last >= interval else { continue }
                UserDefaults.standard.set(now, forKey: lastKey)
                guard let period = DashboardPeriodKind(rawValue: key) else { continue }
                let snap = await StatsService.dashboardSnapshot(period: period)
                await DashboardCache.write(timeRange: key, json: snap.jsonString())
            }

            await CloudSyncService.shared.syncFromCache()
            Task { @MainActor in Logger.debug("Phase 4 refreshed") }
        }
    }

    private func runPulseTick() {
        guard !stopped else { return }
        Task { @MainActor in
            await PulseEngine.shared.invalidate()
            NotificationCenter.default.post(name: .pulseDidChange, object: nil)
        }
    }

    // MARK: - Push-change notification (called by ingestion modules)

    /// Called by LogWatcher after usage_event rows are inserted, carrying the
    /// batch's consumption totals — the coin sound's only log-side trigger.
    func notifyPhaseIngest(_ event: ConsumptionEvent? = nil) {
        DiagnosticJournal.log("cache_invalidate", [
            "reason": .string("usage_event"),
        ])
        Task { await DashboardCache.invalidateAll() }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.appendEvent(event)
                self?.scheduleUINotify()
            }
        }
    }

    /// Called by GitMonitor after a code_change row is inserted. Code changes
    /// are not consumption events (v2 §4.2 — unattributed output never burns),
    /// so this only refreshes UI.
    func notifyPhaseGitScan() {
        Task { [weak self] in
            guard let self else { return }
            await invalidateDashboardCache()
            await MainActor.run { self.scheduleUINotify() }
        }
    }

    /// Called by ApiPoller after a balance_snapshot row is inserted, optionally
    /// carrying the detected spend delta.
    ///
    /// Balance deltas feed API spend in every dashboard range, but the cached
    /// snapshots refresh at different rates (today=5min, week=1h, 30d=12h).
    /// Without invalidation a new API delta would appear on Today within
    /// minutes while This Week keeps showing the pre-poll snapshot for up to
    /// an hour. Drop the caches so the next load recomputes from the new row.
    func notifyPhaseBalance(_ event: ConsumptionEvent? = nil) {
        DiagnosticJournal.log("cache_invalidate", [
            "reason": .string("balance_snapshot"),
        ])
        Task { await DashboardCache.invalidateAll() }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.appendEvent(event)
                self?.scheduleUINotify()
            }
        }
    }

    /// Main-thread only (all callers hop through DispatchQueue.main.async).
    private func appendEvent(_ event: ConsumptionEvent?) {
        guard let event, !event.isEmpty else { return }
        pendingConsumptionBeat = true
        // Quiet-time observations still update facts and pulse state, but they
        // never enter the sound queue and therefore cannot replay in the
        // morning if UI notification delivery was delayed.
        let settings = SoundSettings.current()
        guard !CoinSound.isQuietTime(Date(), settings: settings) else { return }
        pendingEvents.append(event)
    }

    // MARK: - Debounce & dispatch

    private var notifyTask: Task<Void, Never>?

    private func scheduleUINotify() {
        guard !stopped else { return }
        notifyTask?.cancel()
        notifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.notifyConsumers()
        }
    }

    private func notifyConsumers() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastNotifyTime)
        guard elapsed >= minNotifyInterval else {
            let delay = max(minNotifyInterval - elapsed, 0)
            Logger.debug("DataRefreshCoordinator: delaying notify by \(String(format: "%.1f", delay))s")
            // Keep the pending consumption events and guarantee delivery after
            // the minimum interval. Previously they waited for an unrelated
            // future event, which could make a legitimate coin beat disappear.
            notifyTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.notifyConsumers()
            }
            return
        }
        lastNotifyTime = now
        Logger.debug("DataRefreshCoordinator: posting .dataDidChange (\(pendingEvents.count) consumption event(s))")
        let events = pendingEvents
        pendingEvents.removeAll()
        let shouldBeat = pendingConsumptionBeat
        pendingConsumptionBeat = false
        Task { @MainActor in
            await PulseEngine.shared.invalidate()
            NotificationCenter.default.post(name: .dataDidChange, object: nil)
            if shouldBeat {
                NotificationCenter.default.post(name: .consumptionDidOccur, object: nil)
            }
            guard !events.isEmpty else { return }
            let pulse = await PulseEngine.shared.snapshot()
            self.playConsumption(events, pulse)
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
