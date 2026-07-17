import AppKit
import Foundation

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
final class DataRefreshCoordinator: @unchecked Sendable {
    static let shared = DataRefreshCoordinator()

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
    }

    private func recreateTimers() {
        // Timer callbacks fire on notifyQueue (utility). Hop to MainActor
        // since runPhase* methods are MainActor-isolated.
        phase1Timer = makeTimer(interval: .seconds(30), firstDeadline: .now() + 5) { [weak self] in
            Task { @MainActor [weak self] in self?.runPhase1() }
        }
        phase2Timer = makeTimer(interval: .seconds(300), firstDeadline: .now() + 15) { [weak self] in
            Task { @MainActor [weak self] in self?.runPhase2() }
        }
        phase3Timer = makeTimer(interval: .seconds(3600), firstDeadline: .now() + 10) { [weak self] in
            Task { @MainActor [weak self] in self?.runPhase3() }
        }
        phase4Timer = makeTimer(interval: .seconds(300), firstDeadline: .now() + 20) { [weak self] in
            Task { @MainActor [weak self] in self?.runPhase4() }
        }
    }

    func triggerIngest() {
        notifyQueue.async { [weak self] in
            Task { @MainActor [weak self] in self?.runPhase1() }
        }
    }

    func notifyDataChange() {
        Task { @MainActor [weak self] in self?.scheduleUINotify() }
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

    /// Phase 4: Refresh dashboard cache for all three time ranges.
    /// Runs every 5 min in the background, independent of Dashboard open state.
    /// Ensures iCloud sync always has fresh data for iOS/watchOS.
    private func runPhase4() {
        let providerNames = Dictionary(uniqueKeysWithValues: IntegrationRegistry.all.map { ($0.id, $0.displayName) })
        let subAmort = StatsService.subscriptionDailyAmortization()
        Task.detached(priority: .background) {
            let cal = Calendar.current
            let todayStart = cal.startOfDay(for: Date())
            let todayMs = Int64(todayStart.timeIntervalSince1970 * 1000)
            let weekMs = Int64(cal.date(byAdding: .day, value: -6, to: todayStart)!.timeIntervalSince1970 * 1000)
            let monthMs = Int64(cal.date(byAdding: .day, value: -29, to: todayStart)!.timeIntervalSince1970 * 1000)

            async let todayCost = StatsService.combinedSpend(sinceMs: todayMs)
            async let weekCost = StatsService.combinedSpend(sinceMs: weekMs)
            async let monthCost = StatsService.combinedSpend(sinceMs: monthMs)
            async let todayStats = StatsService.dailyStats(days: 1)
            async let weekStats = StatsService.dailyStats(days: 7)
            async let monthStats = StatsService.dailyStats(days: 30)
            async let todayBal  = StatsService.balanceDailySpend(days: 1, sinceMs: todayMs)
            async let weekBal   = StatsService.balanceDailySpend(days: 7, sinceMs: weekMs)
            async let monthBal  = StatsService.balanceDailySpend(days: 30, sinceMs: monthMs)
            async let todayCode = StatsService.dailyCodeChanges(days: 1)
            async let weekCode  = StatsService.dailyCodeChanges(days: 7)
            async let monthCode = StatsService.dailyCodeChanges(days: 30)
            async let todayRepos = StatsService.repoBreakdown(days: 1)
            async let weekRepos  = StatsService.repoBreakdown(days: 7)
            async let monthRepos = StatsService.repoBreakdown(days: 30)
            async let pred = StatsService.prediction()

            let (t, w, m, ts, ws, ms, tb, wb, mb, tc, wc, mc, tr, wr, mr, pr) = await (
                todayCost, weekCost, monthCost,
                (try? todayStats) ?? [], (try? weekStats) ?? [], (try? monthStats) ?? [],
                (try? todayBal) ?? [], (try? weekBal) ?? [], (try? monthBal) ?? [],
                (try? todayCode) ?? [], (try? weekCode) ?? [], (try? monthCode) ?? [],
                (try? todayRepos) ?? [], (try? weekRepos) ?? [], (try? monthRepos) ?? [],
                pred
            )

            var provTotals: [String: (name: String, cost: Double)] = [:]
            for s in wb {
                let name = providerNames[s.providerId] ?? s.providerId
                let prev = provTotals[s.providerId]?.cost ?? 0
                provTotals[s.providerId] = (name, prev + s.spend)
            }
            let providers = provTotals.map { ProviderItem(providerId: $0.key, name: $0.value.name, cost: $0.value.cost) }.sorted { $0.cost > $1.cost }
            let toolCosts = providers.map { NameCostItem(name: $0.name, cost: $0.cost) }
            let todayCall = ts.first?.calls ?? 0
            let todayTok = ts.first?.tokens ?? 0

            func tp(_ s: [DailyStat]) -> [TrendPoint] { s.map { TrendPoint(ts: $0.date.timeIntervalSince1970, value: $0.cost, calls: $0.calls, tokens: $0.tokens, netLines: $0.netLines) } }
            func cp(_ c: [DailyCodeChange]) -> [TrendPoint] { c.map { TrendPoint(ts: $0.date.timeIntervalSince1970, value: Double($0.added), calls: 0, tokens: 0, netLines: $0.added - $0.deleted, added: $0.added, deleted: $0.deleted) } }
            func bp(_ s: [(String, Date, Double)]) -> [TrendPoint] { Dictionary(grouping: s, by: { $0.1 }).compactMap { d, v in TrendPoint(ts: d.timeIntervalSince1970, value: v.reduce(0) { $0 + $1.2 }, calls: 0, tokens: 0, netLines: 0) } }
            func rp(_ r: [RepoBreakdown]) -> [RepoItem] { r.map { RepoItem(name: $0.repo, cost: $0.cost, added: $0.added, deleted: $0.deleted, cpl: ($0.added + $0.deleted) > 0 ? $0.cost * 1000 / Double($0.added + $0.deleted) : 0) } }
            let predItem = PredictionItem(monthProjected: pr.monthProjected, dailyRate: pr.dailyRate, daysRemaining: pr.daysRemaining, monthSoFar: pr.monthSoFar)

            let todaySnap = DashboardSnapshot(todayCost: t, weekCost: w, monthCost: m, yesterdaySpend: 0, previousPeriodSpend: 0, subDaily: subAmort, todayCalls: todayCall, todayTokens: todayTok, providerBreakdown: providers, toolBreakdown: toolCosts, topRepos: rp(tr), prediction: predItem, dailyStats: tp(ts), codeChanges: cp(tc), balanceDaily: bp(tb), updatedAt: Date())
            await DashboardCache.write(timeRange: "today", json: todaySnap.jsonString())

            let weekSnap = DashboardSnapshot(todayCost: t, weekCost: w, monthCost: m, yesterdaySpend: 0, previousPeriodSpend: 0, subDaily: subAmort, todayCalls: todayCall, todayTokens: todayTok, providerBreakdown: providers, toolBreakdown: toolCosts, topRepos: rp(wr), prediction: predItem, dailyStats: tp(ws), codeChanges: cp(wc), balanceDaily: bp(wb), updatedAt: Date())
            await DashboardCache.write(timeRange: "week", json: weekSnap.jsonString())

            let monthSnap = DashboardSnapshot(todayCost: t, weekCost: w, monthCost: m, yesterdaySpend: 0, previousPeriodSpend: 0, subDaily: subAmort, todayCalls: todayCall, todayTokens: todayTok, providerBreakdown: providers, toolBreakdown: toolCosts, topRepos: rp(mr), prediction: predItem, dailyStats: tp(ms), codeChanges: cp(mc), balanceDaily: bp(mb), updatedAt: Date())
            await DashboardCache.write(timeRange: "30d", json: monthSnap.jsonString())
            await CloudSyncService.shared.syncFromCache()
            Task { @MainActor in Logger.debug("DataRefreshCoordinator: Phase 4 cache refreshed + synced") }
        }
    }

    // MARK: - Push-change notification (called by ingestion modules)

    /// Called by LogWatcher after a usage_event row is inserted.
    func notifyPhaseIngest() {
        Task { @MainActor [weak self] in self?.scheduleUINotify(playSound: true) }
    }

    /// Called by GitMonitor after a code_change row is inserted.
    func notifyPhaseGitScan() {
        Task { @MainActor [weak self] in self?.scheduleUINotify(playSound: true) }
    }

    /// Called by ApiPoller after a balance_snapshot row is inserted.
    func notifyPhaseBalance() {
        Task { @MainActor [weak self] in self?.scheduleUINotify(playSound: true) }
    }

    // MARK: - Debounce & dispatch

    private var notifyTask: Task<Void, Never>?

    private func scheduleUINotify(playSound: Bool = false) {
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
