import Foundation
import GRDB
import AIPulseShared

/// Daily-aggregated stats for the Dashboard charts.
struct DailyStat: Identifiable {
    var id: Date { date }
    let date: Date
    let calls: Int
    let tokens: Int
    let netLines: Int
}

struct DailyCodeChange: Identifiable {
    var id: Date { date }
    let date: Date
    let added: Int
    let deleted: Int
    let commits: Int
}

/// Pre-aggregated stats service for the Dashboard.
enum StatsService {

    private struct AuthorizedCodeChange {
        let ts: Int64
        let added: Int
        let deleted: Int
        let commitHash: String
        let repoPath: String
    }

    /// Reads factual local Git output and applies the same repository boundary
    /// as GitMonitor. This prevents historical rows from repos outside the
    /// currently configured development directories from leaking into totals.
    private static func authorizedCodeChanges(
        sinceMs: Int64,
        beforeMs: Int64? = nil
    ) async throws -> [AuthorizedCodeChange] {
        let rows = try await AppDatabase.shared.read { db -> [(Int64, String, Int, Int, String)] in
            let rows: [Row]
            if let beforeMs {
                rows = try Row.fetchAll(db, sql: """
                    SELECT ts, repo_path, COALESCE(added, 0) AS a,
                           COALESCE(deleted, 0) AS d, commit_hash
                    FROM code_change
                    WHERE is_merge = 0 AND ts >= ? AND ts < ?
                    ORDER BY ts
                    """, arguments: [sinceMs, beforeMs])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT ts, repo_path, COALESCE(added, 0) AS a,
                           COALESCE(deleted, 0) AS d, commit_hash
                    FROM code_change
                    WHERE is_merge = 0 AND ts >= ?
                    ORDER BY ts
                    """, arguments: [sinceMs])
            }
            return rows.map { row in
                (row["ts"] as Int64? ?? 0,
                 row["repo_path"] as String? ?? "",
                 Int(row["a"] as Int64? ?? 0),
                 Int(row["d"] as Int64? ?? 0),
                 row["commit_hash"] as String? ?? "")
            }
        }
        let roots = RepositoryScope.configuredRoots()
        return rows.compactMap { ts, path, added, deleted, commitHash in
            guard let root = RepositoryScope.authorizedGitRoot(for: path, roots: roots) else { return nil }
            return AuthorizedCodeChange(ts: ts,
                                        added: max(added, 0),
                                        deleted: max(deleted, 0),
                                        commitHash: commitHash,
                                        repoPath: root)
        }
    }

    private struct AuthorizedCommit {
        let ts: Int64
        let repoPath: String
        let commitHash: String
        var identity: String { repoPath + "|" + commitHash }
    }

    /// Commits are independent facts, including merges and zero-line commits.
    private static func authorizedCommits(sinceMs: Int64, beforeMs: Int64? = nil) async throws -> [AuthorizedCommit] {
        let rows = try await AppDatabase.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, repo_path, commit_hash FROM git_commit
                WHERE ts >= ? AND ts < ? ORDER BY ts
                """, arguments: [sinceMs, beforeMs ?? Int64.max]).map { row in
                (ts: row["ts"] as Int64? ?? 0, path: row["repo_path"] as String? ?? "",
                 hash: row["commit_hash"] as String? ?? "")
            }
        }
        let roots = RepositoryScope.configuredRoots()
        return rows.compactMap { row in
            guard !row.hash.isEmpty,
                  let root = RepositoryScope.authorizedGitRoot(for: row.path, roots: roots) else { return nil }
            return AuthorizedCommit(ts: row.ts, repoPath: root, commitHash: row.hash)
        }
    }

    static func authorizedCodeOutput(sinceMs: Int64, beforeMs: Int64? = nil) async throws -> (added: Int, deleted: Int, commits: Int) {
        let rows = try await authorizedCodeChanges(sinceMs: sinceMs, beforeMs: beforeMs)
        let commits = try await authorizedCommits(sinceMs: sinceMs, beforeMs: beforeMs)
        return (rows.reduce(0) { $0 + $1.added },
                rows.reduce(0) { $0 + $1.deleted },
                Set(commits.map(\.identity)).count)
    }

    // MARK: - Daily trend

    /// Daily cost + netLines for the last `days` calendar days, or from `sinceMs` if provided.
    static func dailyStats(days: Int, sinceMs: Int64? = nil, now: Date = Date(), calendar cal: Calendar = .current) async throws -> [DailyStat] {
        let todayStart = cal.startOfDay(for: now)
        let startMs: Int64
        if let s = sinceMs {
            startMs = s
        } else {
            guard let start = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return [] }
            startMs = Int64(start.timeIntervalSince1970 * 1000)
        }
        guard let end = cal.date(byAdding: .day, value: 1, to: todayStart) else { return [] }
        let endMs = ObservationBounds.upperExclusive(now: now, periodEnd: end)

        do {
            // Observed activity, independent of historical price estimates.
            let usageRows = try await AppDatabase.shared.read { db -> [(day: Int64, cnt: Int, tok: Int64)] in
                try Row.fetchAll(db, sql: """
                    SELECT ts AS day_ts,
                           COUNT(*) AS cnt,
                           COALESCE(SUM(\(TokenAccounting.observedTotalSQL)), 0) AS tok
                    FROM usage_event
                    WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>')
                    GROUP BY day_ts ORDER BY day_ts
                    """, arguments: [startMs, endMs]).map { r in
                    (day: r["day_ts"] as Int64? ?? 0,
                     cnt: r["cnt"] as Int? ?? 0,
                     tok: r["tok"] as Int64? ?? 0)
                }
            }

            // Net lines per day
            let codeRows = try await authorizedCodeChanges(
                sinceMs: startMs,
                beforeMs: endMs
            )

            // Merge activity + lines by day
            var lineMap = [Int64: Int]()
            for row in codeRows {
                let day = cal.localDayTimestamp(milliseconds: row.ts)
                lineMap[day, default: 0] += row.added - row.deleted
            }

            // Calendar days are not fixed 24-hour UTC intervals. Use the same
            // local boundaries as the code-change chart, including DST days.
            var usageMap: [Int64: (calls: Int, tokens: Int64)] = [:]
            for r in usageRows {
                let day = cal.localDayTimestamp(milliseconds: r.day)
                usageMap[day, default: (0, 0)].calls += r.cnt
                usageMap[day, default: (0, 0)].tokens += r.tok
            }
            let result = Set(usageMap.keys).union(lineMap.keys).sorted().map { day in
                let usage = usageMap[day] ?? (calls: 0, tokens: 0)
                let nl = lineMap[day] ?? 0
                return DailyStat(date: Date(timeIntervalSince1970: Double(day) / 1000),
                                 calls: usage.calls, tokens: Int(clamping: usage.tokens), netLines: nl)
            }
            return result
        } catch {
            Logger.error("StatsService.dailyStats error: \(error)")
            throw error
        }
    }

    /// Hourly usage facts for the current local calendar day. The timestamps
    /// remain the real `usage_event.ts` buckets; no session is assigned wholesale
    /// to its start hour and no context-window capacity is treated as consumption.
    static func hourlyUsageStatsToday(now: Date = Date(), calendar cal: Calendar = .current) async throws -> [DailyStat] {
        let start = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let startMs = Int64(start.timeIntervalSince1970 * 1_000)
        let endMs = ObservationBounds.upperExclusive(now: now, periodEnd: end)

        do {
            let rows = try await AppDatabase.shared.read { db -> [(ts: Int64, tokens: Int64)] in
                try Row.fetchAll(db, sql: """
                    SELECT ts,
                           \(TokenAccounting.observedTotalSQL) AS tok
                    FROM usage_event
                    WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>')
                    ORDER BY ts
                    """, arguments: [startMs, endMs]).map { row in
                        (ts: row["ts"] as Int64? ?? 0,
                         tokens: row["tok"] as Int64? ?? 0)
                    }
            }
            var buckets: [Date: (calls: Int, tokens: Int64)] = [:]
            for row in rows {
                let date = Date(timeIntervalSince1970: Double(row.ts) / 1_000)
                guard let hour = cal.dateInterval(of: .hour, for: date)?.start else { continue }
                buckets[hour, default: (0, 0)].calls += 1
                buckets[hour, default: (0, 0)].tokens += max(row.tokens, 0)
            }
            return buckets.map { hour, values in
                DailyStat(
                    date: hour,
                    calls: values.calls,
                    tokens: Int(clamping: values.tokens),
                    netLines: 0)
            }.sorted { $0.date < $1.date }
        } catch {
            Logger.error("StatsService.hourlyUsageStatsToday error: \(error)")
            throw error
        }
    }

    /// Dashboard buckets follow the selected horizon: hourly for Today and
    /// daily for longer ranges.
    static func dashboardUsageStats(days: Int) async throws -> [DailyStat] {
        if days == 1 { return try await hourlyUsageStatsToday() }
        return try await dailyStats(days: days)
    }

    /// Explicit provenance for semantic snapshot conversion. Unknown
    /// currencies stay unconverted instead of silently falling back to 1:1.
    static func semanticUSDConversion(currency: String) -> (rate: Double, source: String)? {
        let rate: Double
        switch currency.uppercased() {
        case "USD": rate = 1.0
        case "CNY": rate = 0.14
        case "EUR": rate = 1.08
        case "GBP": rate = 1.27
        case "JPY": rate = 0.0067
        default: return nil
        }
        return (rate, "internal-static-approximation-v1")
    }

    /// Map usage_event.source to a human-readable label for CPL display.
    // MARK: - Balance spend (daily deltas, top-up filtered)

    /// Daily spend from balance snapshots. Filters out top-ups (balance increases).
    /// Returns per-provider daily spend estimates, converted to USD.
    static func balanceDailySpend(days: Int, sinceMs: Int64? = nil, now: Date = Date(), calendar cal: Calendar = .current) async throws -> [(providerId: String, date: Date, spend: Double)] {
        let todayStart = cal.startOfDay(for: now)
        let startMs: Int64 = sinceMs ?? {
            guard let s = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return 0 }
            return Int64(s.timeIntervalSince1970 * 1000)
        }()

        do {
            let deltas = try await AppDatabase.shared.read { db in
                try BalanceObservation.fetchBalanceDeltas(in: db, sinceMs: startMs,
                                                         beforeMs: Int64(now.timeIntervalSince1970 * 1_000))
            }
            let results: [(String, Date, Double)] = deltas.compactMap { delta in
                guard let conversion = semanticUSDConversion(currency: delta.currency) else { return nil }
                let date = cal.startOfDay(for: Date(timeIntervalSince1970: Double(delta.ts) / 1_000))
                return (delta.providerId, date, delta.nativeAmount * conversion.rate)
            }
            return results
        } catch {
            Logger.error("StatsService.balanceDailySpend error: \(error)")
            throw error
        }
    }

    // MARK: - Observed amounts and declared context

    /// Declared monthly context; never amortized into observed consumption.
    static func declaredMonthlyCostUSD() -> Double {
        IntegrationRegistry.activeCostSources().reduce(0.0) { total, source in
            if case .subscription(_, _, let fee) = source.kind, fee.isFinite, fee > 0 {
                return total + fee
            }
            return total
        }
    }



    static func observedSpendItems(sinceMs: Int64, now: Date = Date()) async -> [ObservedSpendItem] {
        do {
            let deltas = try await AppDatabase.shared.read { db in
                try BalanceObservation.fetchBalanceDeltas(in: db, sinceMs: sinceMs,
                                                         beforeMs: Int64(now.timeIntervalSince1970 * 1_000))
            }
            struct Aggregate {
                var nativeAmount = 0.0
                var observedAt = 0.0
                var intervalStart = Double.greatestFiniteMagnitude
            }
            var totals: [String: Aggregate] = [:]
            for delta in deltas {
                let key = "\(delta.providerId)|\(delta.currency)"
                var value = totals[key] ?? Aggregate()
                value.nativeAmount += delta.nativeAmount
                value.observedAt = max(value.observedAt, Double(delta.ts) / 1_000)
                value.intervalStart = min(value.intervalStart, Double(delta.startMs) / 1_000)
                totals[key] = value
            }
            clearObservationFailure("observedSpend")
            return totals.map { key, value in
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                let currency = parts.count > 1 ? parts[1] : "USD"
                let conversion = semanticUSDConversion(currency: currency)
                return ObservedSpendItem(
                    providerId: parts.first ?? "",
                    amount: value.nativeAmount,
                    currency: currency,
                    convertedUSD: conversion.map { value.nativeAmount * $0.rate },
                    conversionRateToUSD: conversion?.rate,
                    conversionSource: conversion?.source,
                    observedAt: value.observedAt,
                    intervalStart: value.intervalStart,
                    intervalEnd: value.observedAt)
            }.sorted { ($0.convertedUSD ?? 0) > ($1.convertedUSD ?? 0) }
        } catch {
            Logger.error("StatsService.observedSpendItems: \(error)")
            await recordObservationFailure("observedSpend", error: error)
            return []
        }
    }



    // MARK: - Remaining balance

    /// Latest remaining balance per balance-tracked provider.
    /// For usage-type providers (OpenAI), stored value is negative — reverse to positive.
    static func latestRemainingBalances(sinceMs: Int64) async throws -> [RemainingBalanceItem] {
        let balanceTrackedIds = Set(ProviderRegistry.all.filter { $0.canFetchBalance }.map { $0.id })
        guard !balanceTrackedIds.isEmpty else { return [] }
        let names = Dictionary(uniqueKeysWithValues: IntegrationRegistry.all.map { ($0.id, $0.displayName) })
        return try await AppDatabase.shared.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT bs.provider_id, bs.balance, bs.currency
                FROM balance_snapshot bs
                INNER JOIN (
                    SELECT provider_id, MAX(ts) AS max_ts
                    FROM balance_snapshot
                    WHERE ts >= ? AND ts <= ?
                    GROUP BY provider_id
                ) latest ON bs.provider_id = latest.provider_id AND bs.ts = latest.max_ts
                """, arguments: [sinceMs, Int64(Date().timeIntervalSince1970 * 1_000)])
            return rows.compactMap { row in
                guard let pid: String = row["provider_id"],
                      let storedBal: Double = row["balance"], storedBal.isFinite,
                      let cur: String = row["currency"],
                      balanceTrackedIds.contains(pid),
                      // Only show providers with a key configured — a provider
                      // whose key was deleted/cleared must not show stale balance.
                      ApiKeyManager.shared.get(pid) != nil
                else { return nil }
                let provider = ProviderRegistry.byId(pid)
                let rawBalance = provider?.balanceType == .usage ? -storedBal : storedBal
                return RemainingBalanceItem(
                    providerId: pid,
                    displayName: names[pid] ?? pid,
                    balance: rawBalance,
                    currency: cur.uppercased()
                )
            }
        }
    }

    /// Read independent subscription quota windows with observation freshness.
    static func latestQuotaStatus() async -> [QuotaStatusItem] {
        do {
            let rows = try await AppDatabase.shared.read { db -> [QuotaStatusItem] in
                try Row.fetchAll(db, sql: """
                    SELECT tool_id, window_id, utilization, limit_status,
                           reset_at, window_seconds, updated_at
                    FROM quota_window_status
                    ORDER BY tool_id, window_seconds
                    """).map { r in
                    QuotaStatusItem(
                        toolId: r["tool_id"] as String? ?? "",
                        windowId: r["window_id"] as String?,
                        utilization: r["utilization"] as Double? ?? 0,
                        limitStatus: r["limit_status"] as String? ?? "",
                        resetAt: r["reset_at"] as Double? ?? 0,
                        windowSeconds: r["window_seconds"] as Double? ?? 0,
                        updatedAt: r["updated_at"] as Double?
                    )
                }
            }
            clearObservationFailure("quotaStatus")
            return rows.filter { !$0.toolId.isEmpty }
        } catch {
            Logger.error("StatsService.latestQuotaStatus: \(error)")
            await recordObservationFailure("quotaStatus", error: error)
            return []
        }
    }

    // MARK: - Daily code changes

    /// Daily added/deleted lines (separate, not net) for the code-change chart.
    static func dailyCodeChanges(days: Int, now: Date = Date(), calendar cal: Calendar = .current) async throws -> [DailyCodeChange] {
        let todayStart = cal.startOfDay(for: now)
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return [] }
        let startMs = Int64(start.timeIntervalSince1970 * 1000)

        do {
            let end = cal.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
            let endMs = ObservationBounds.upperExclusive(now: now, periodEnd: end)
            let rows = try await authorizedCodeChanges(
                sinceMs: startMs,
                beforeMs: endMs
            )
            var buckets: [Date: (added: Int, deleted: Int, commits: Set<String>)] = [:]
            for row in rows {
                let date = Date(timeIntervalSince1970: Double(row.ts) / 1_000)
                let day = cal.startOfDay(for: date)
                buckets[day, default: (0, 0, [])].added += row.added
                buckets[day, default: (0, 0, [])].deleted += row.deleted
            }
            for commit in try await authorizedCommits(sinceMs: startMs, beforeMs: endMs) {
                let day = cal.startOfDay(for: Date(timeIntervalSince1970: Double(commit.ts) / 1_000))
                buckets[day, default: (0, 0, [])].commits.insert(commit.identity)
            }
            return buckets.map { day, values in
                DailyCodeChange(date: day, added: values.added, deleted: values.deleted,
                                commits: values.commits.count)
            }.sorted { $0.date < $1.date }
        } catch {
            Logger.error("StatsService.dailyCodeChanges error: \(error)")
            throw error
        }
    }

    /// Hourly added/deleted lines for the current local calendar day.
    /// The dashboard uses real commit timestamps for the 24-hour rhythm; it
    /// never spreads a daily total across invented hourly buckets.
    static func hourlyCodeChangesToday(now: Date = Date(), calendar cal: Calendar = .current) async throws -> [DailyCodeChange] {
        let start = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let startMs = Int64(start.timeIntervalSince1970 * 1_000)
        let endMs = ObservationBounds.upperExclusive(now: now, periodEnd: end)

        do {
            let rows = try await authorizedCodeChanges(sinceMs: startMs, beforeMs: endMs)
            var buckets: [Date: (added: Int, deleted: Int, commits: Set<String>)] = [:]
            for row in rows {
                let date = Date(timeIntervalSince1970: Double(row.ts) / 1_000)
                guard let hour = cal.dateInterval(of: .hour, for: date)?.start else { continue }
                buckets[hour, default: (0, 0, [])].added += row.added
                buckets[hour, default: (0, 0, [])].deleted += row.deleted
            }
            for commit in try await authorizedCommits(sinceMs: startMs, beforeMs: endMs) {
                let date = Date(timeIntervalSince1970: Double(commit.ts) / 1_000)
                guard let hour = cal.dateInterval(of: .hour, for: date)?.start else { continue }
                buckets[hour, default: (0, 0, [])].commits.insert(commit.identity)
            }
            return buckets.map { hour, values in
                DailyCodeChange(date: hour, added: values.added, deleted: values.deleted,
                                commits: values.commits.count)
            }.sorted { $0.date < $1.date }
        } catch {
            Logger.error("StatsService.hourlyCodeChangesToday error: \(error)")
            throw error
        }
    }

    /// Dashboard buckets follow the selected horizon: hourly for Today and
    /// daily for longer ranges.
    static func dashboardCodeChanges(days: Int) async throws -> [DailyCodeChange] {
        if days == 1 { return try await hourlyCodeChangesToday() }
        return try await dailyCodeChanges(days: days)
    }

    // MARK: - Full snapshot builder (shared by DashboardView and Phase 4 timer)

    /// Inputs have already passed repository authorization. Identity remains
    /// the Git root even when different roots have the same basename.
    static func repositoryActivities(
        tokensByRoot: [String: Int64],
        changes: [(repoPath: String, added: Int, deleted: Int, commitHash: String)],
        commits: [(repoPath: String, commitHash: String)] = []
    ) -> [RepoItem] {
        let codeByRoot = Dictionary(grouping: changes, by: \.repoPath)
        let commitsByRoot = Dictionary(grouping: commits, by: \.repoPath)
        return Set(tokensByRoot.keys).union(codeByRoot.keys).union(commitsByRoot.keys).sorted().map { root in
            let code = codeByRoot[root] ?? []
            return RepoItem(repoPath: root, name: URL(fileURLWithPath: root).lastPathComponent,
                            added: code.reduce(0) { $0 + max($1.added, 0) },
                            deleted: code.reduce(0) { $0 + max($1.deleted, 0) },
                            tokens: max(tokensByRoot[root] ?? 0, 0),
                            commits: Set((commitsByRoot[root] ?? []).map(\.commitHash).filter { !$0.isEmpty }).count)
        }.sorted {
            if ($0.tokens ?? 0) != ($1.tokens ?? 0) { return ($0.tokens ?? 0) > ($1.tokens ?? 0) }
            if $0.totalChanges != $1.totalChanges { return $0.totalChanges > $1.totalChanges }
            return $0.repoPath < $1.repoPath
        }
    }

    /// Builds unit-preserving activity from observed rows.
    /// Path groups are canonicalized and authorized by the caller.
    static func repositoryTokenActivity(in db: Database, sinceMs: Int64, beforeMs: Int64) throws -> [(path: String, tokens: Int64)] {
        try Row.fetchAll(db, sql: """
            SELECT repo_path AS p, COALESCE(SUM(\(TokenAccounting.observedTotalSQL)), 0) AS tok
            FROM usage_event
            WHERE ts >= ? AND ts < ? AND repo_path IS NOT NULL
              AND (model IS NULL OR model != '<synthetic>')
            GROUP BY p
            """, arguments: [sinceMs, beforeMs]).map {
                (path: $0["p"] as String? ?? "", tokens: $0["tok"] as Int64? ?? 0)
            }
    }

    static func modelActivity(in db: Database, sinceMs: Int64, beforeMs: Int64) throws -> [ModelActivityItem] {
        let rows = try Row.fetchAll(db, sql: """
                SELECT COALESCE(model, '') AS m, COALESCE(provider_id, 'unknown') AS pid,
                       source AS s,
                       COALESCE(SUM(\(TokenAccounting.observedTotalSQL)), 0) AS tok,
                       COUNT(*) AS cnt
                FROM usage_event
                WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>')
                GROUP BY m, pid, s
                """, arguments: [sinceMs, beforeMs]).map { r in
                    (m: r["m"] as String? ?? "",
                     pid: r["pid"] as String? ?? "unknown",
                     s: r["s"] as String? ?? "",
                     tok: r["tok"] as Int64? ?? 0,
                     cnt: r["cnt"] as Int? ?? 0)
                }
        return modelBreakdown(rows: rows.map {
            (model: $0.m, providerId: $0.pid, toolId: $0.s.isEmpty ? nil : $0.s, tokens: $0.tok, calls: $0.cnt)
        })
    }

    static func modelBreakdown(
        rows: [(model: String, providerId: String, toolId: String?, tokens: Int64, calls: Int)]
    ) -> [ModelActivityItem] {
        rows.map { row in
            ModelActivityItem(model: row.model.trimmingCharacters(in: .whitespacesAndNewlines),
                              providerId: row.providerId, toolId: row.toolId,
                              tokens: max(row.tokens, 0), calls: max(row.calls, 0))
        }
    }

    /// Await a throwing async value, logging the failure before returning the
    /// fallback. Replaces bare `try?` in dashboardSnapshot so a data-source
    /// failure is visible in logs instead of silently degrading.
    @TaskLocal static var observationFailures: ObservationFailures?
    @TaskLocal static var observationPeriod: DashboardPeriodKind?

    /// Menus must distinguish an empty observation from a failed read.
    static func observedValue<Value>(source: String, operation: () async -> Value) async -> Value? {
        let failures = ObservationFailures()
        let value = await $observationFailures.withValue(failures) { await operation() }
        guard await failures.snapshot().isEmpty else {
            AppHealthMonitor.shared.reportStatsError("Observation unavailable", source: source)
            return nil
        }
        AppHealthMonitor.shared.clearStatsError(source: source)
        return value
    }

    static func observedSpendForMenu(sinceMs: Int64) async -> [ObservedSpendItem]? {
        await observedValue(source: "menu.observedSpend") {
            await observedSpendItems(sinceMs: sinceMs)
        }
    }

    private static func clearObservationFailure(_ label: String) {
        if let period = observationPeriod {
            AppHealthMonitor.shared.clearStatsError(source: "dashboard.\(period.rawValue).\(label)")
        }
    }

    private static func recordObservationFailure(_ label: String, error: Error) async {
        await observationFailures?.record(label)
        if let period = observationPeriod {
            AppHealthMonitor.shared.reportStatsError(error.localizedDescription,
                source: "dashboard.\(period.rawValue).\(label)")
        }
    }

    static func resultOrLog<T>(_ label: String, _ fallback: T, _ body: () async throws -> T) async -> T {
        do {
            let value = try await body()
            clearObservationFailure(label)
            return value
        } catch {
            Logger.error("StatsService.dashboardSnapshot: \(label) failed: \(error)")
            await recordObservationFailure(label, error: error)
            return fallback
        }
    }

    /// Computes everything needed for a complete DashboardSnapshot for `days`.
    /// Used by both live Dashboard loading and background cache refresh.
    static func dashboardSnapshot(period: DashboardPeriodKind) async -> DashboardSnapshot {
        let failures = ObservationFailures()
        return await $observationFailures.withValue(failures) {
            await $observationPeriod.withValue(period) {
                await buildDashboardSnapshot(period: period)
            }
        }
    }

    private static func buildDashboardSnapshot(period: DashboardPeriodKind) async -> DashboardSnapshot {
        let snapshotStartedAt = Date()
        let cal = Calendar.current
        let horizon = DashboardPeriod(kind: period, now: snapshotStartedAt, calendar: cal)
        let days = horizon.elapsedDays
        let todayStart = cal.startOfDay(for: snapshotStartedAt)
        let rangeStart = horizon.start
        let rangeStartMs = Int64(rangeStart.timeIntervalSince1970 * 1000)
        let rangeEndMs = ObservationBounds.upperExclusive(now: snapshotStartedAt, periodEnd: horizon.end)
        // 30-day window + 14d lookback for correct balance delta computation.
        let monthStart = cal.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        let lookbackStart = cal.date(byAdding: .day, value: -14, to: monthStart) ?? monthStart
        let lookbackStartMs = Int64(lookbackStart.timeIntervalSince1970 * 1000)

        async let observedSpendItemsR = StatsService.observedSpendItems(sinceMs: rangeStartMs, now: snapshotStartedAt)
        async let coverageR = resultOrLog("activityCoverage", ActivityCoverage()) {
            try await AppDatabase.shared.read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS events,
                           COALESCE(SUM(CASE WHEN \(TokenAccounting.missingComponentsSQL) THEN 1 ELSE 0 END), 0) AS incomplete
                    FROM usage_event WHERE ts >= ? AND ts < ?
                      AND (model IS NULL OR model != '<synthetic>')
                    """, arguments: [rangeStartMs, rangeEndMs])!
                return ActivityCoverage(observedEvents: row["events"] as Int64? ?? 0,
                                        incompleteEvents: row["incomplete"] as Int64? ?? 0)
            }
        }
        // Each throwing source goes through resultOrLog so a failure is logged
        // (label + error) instead of being swallowed by bare `try?`.
        async let stR: [DailyStat] = resultOrLog("dashboardUsageStats", []) {
            if horizon.isHourly { return try await StatsService.hourlyUsageStatsToday(now: snapshotStartedAt, calendar: cal) }
            return try await StatsService.dailyStats(days: days, sinceMs: rangeStartMs, now: snapshotStartedAt, calendar: cal)
        }
        async let blR = resultOrLog("balanceDailySpend", []) { try await StatsService.balanceDailySpend(days: days, sinceMs: rangeStartMs, now: snapshotStartedAt, calendar: cal) }
        // Query full 30 days of balance data + 14d lookback for provider breakdown
        async let bmR = resultOrLog("balanceDailySpend44", []) { try await StatsService.balanceDailySpend(days: 44, sinceMs: lookbackStartMs, now: snapshotStartedAt, calendar: cal) }
        async let cdR: [DailyCodeChange] = resultOrLog("dashboardCodeChanges", []) {
            if horizon.isHourly { return try await StatsService.hourlyCodeChangesToday(now: snapshotStartedAt, calendar: cal) }
            return try await StatsService.dailyCodeChanges(days: days, now: snapshotStartedAt, calendar: cal)
        }
        async let repoCodeR = resultOrLog("repositoryCode", []) { try await authorizedCodeChanges(sinceMs: rangeStartMs, beforeMs: rangeEndMs) }
        async let repoCommitsR = resultOrLog("repositoryCommits", []) { try await authorizedCommits(sinceMs: rangeStartMs, beforeMs: rangeEndMs) }
        async let lbR = resultOrLog("latestRemainingBalances", []) { try await StatsService.latestRemainingBalances(sinceMs: lookbackStartMs) }
        async let qsR = StatsService.latestQuotaStatus()
        async let modelRowsR = resultOrLog("modelBreakdown", []) { try await AppDatabase.shared.read { db in
            try modelActivity(in: db, sinceMs: rangeStartMs, beforeMs: rangeEndMs)
        } }
        async let sourceAggR = resultOrLog("toolUsage", []) { try await AppDatabase.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source AS s,
                       COALESCE(SUM(\(TokenAccounting.observedTotalSQL)), 0) AS tok,
                       COUNT(*) AS cnt,
                       COUNT(DISTINCT NULLIF(session_id, '')) AS sessions
                FROM usage_event WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>') GROUP BY s
                """, arguments: [rangeStartMs, rangeEndMs]).map { r in
                    (s: r["s"] as String? ?? "",
                     tok: r["tok"] as Int64? ?? 0,
                     cnt: r["cnt"] as Int? ?? 0,
                     sessions: r["sessions"] as Int64? ?? 0)
                }
        } }
        async let repoTokensR = resultOrLog("repoTokens", []) { try await AppDatabase.shared.read { db in
            try repositoryTokenActivity(in: db, sinceMs: rangeStartMs,
                                        beforeMs: rangeEndMs)
        } }
        let (observedSpendItems, activityCoverage,
             st, bl, bm, cd, repoCode, repoCommits, lb, qs,
             modelRows, sourceAgg, repoTokens) = await (
            observedSpendItemsR, coverageR,
            stR, blR, bmR, cdR, repoCodeR, repoCommitsR, lbR, qsR,
            modelRowsR, sourceAggR, repoTokensR
        )
        DiagnosticJournal.log("dashboard_snapshot_stage", [
            "stage": .string("core_data"),
            "days": .int(days),
            "elapsed_ms": .double(Date().timeIntervalSince(snapshotStartedAt) * 1_000),
        ])

        let observedSpend: Double? = !observedSpendItems.isEmpty && observedSpendItems.allSatisfy { $0.convertedUSD != nil }
            ? observedSpendItems.compactMap(\.convertedUSD).reduce(0, +)
            : nil
        let declaredMonthlyCost = declaredMonthlyCostUSD()

        // Provider breakdown — use 30-day query (bm) filtered to `days` range
        let names = Dictionary(uniqueKeysWithValues: IntegrationRegistry.all.map { ($0.id, $0.displayName) })
        var provTotals: [String: (name: String, cost: Double)] = [:]
        for s in bm where s.date.timeIntervalSince1970 >= rangeStart.timeIntervalSince1970 {
            let name = names[s.providerId] ?? s.providerId
            let prev = provTotals[s.providerId]?.cost ?? 0
            provTotals[s.providerId] = (name, prev + s.spend)
        }
        let providers = provTotals.map { entry in
            let providerKind: String = {
                guard let def = ProviderRegistry.byId(entry.key) else { return "balance" }
                return def.balanceType == .usage ? "usage" : "balance"
            }()
            return ProviderItem(
                providerId: entry.key,
                name: entry.value.name,
                cost: entry.value.cost,
                sourceKind: providerKind)
        }.sorted { $0.cost > $1.cost }

        let toolActivities = sourceAgg.filter { $0.tok > 0 || $0.cnt > 0 }.sorted {
            if $0.tok != $1.tok { return $0.tok > $1.tok }
            return $0.s < $1.s
        }.map { row in
            ToolActivityItem(toolId: row.s, name: IntegrationRegistry.toolDisplayName(for: row.s),
                             tokens: row.tok, calls: row.cnt)
        }

        // Repository activity
        let repoRoots = RepositoryScope.configuredRoots()
        var authorizedRepoTokens: [String: Int64] = [:]
        for row in repoTokens {
            guard let root = RepositoryScope.authorizedGitRoot(for: row.path, roots: repoRoots) else { continue }
            authorizedRepoTokens[root, default: 0] += row.tokens
        }
        let repoItems = repositoryActivities(tokensByRoot: authorizedRepoTokens, changes: repoCode.map {
            (repoPath: $0.repoPath, added: $0.added, deleted: $0.deleted, commitHash: $0.commitHash)
        }, commits: repoCommits.map { (repoPath: $0.repoPath, commitHash: $0.commitHash) })

        let modelItems = modelRows

        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        let dailyPts = st.map { TrendPoint(ts: $0.date.timeIntervalSince1970, value: Double($0.tokens), calls: Int64($0.calls), tokens: Int64($0.tokens), netLines: $0.netLines) }
        let codePts = cd.map { TrendPoint(ts: $0.date.timeIntervalSince1970, value: Double($0.added), calls: 0, tokens: 0, netLines: $0.added - $0.deleted, added: $0.added, deleted: $0.deleted, commits: $0.commits) }
        let balPts = Dictionary(grouping: bl, by: { $0.date }).compactMap { d, v in TrendPoint(ts: d.timeIntervalSince1970, value: v.reduce(0) { $0 + $1.spend }, calls: 0, tokens: 0, netLines: 0) }
        let todayCall = Int64(st.reduce(0) { $0 + $1.calls })
        let todayTok = Int64(st.reduce(0) { $0 + $1.tokens })

        var snap = DashboardSnapshot(
            todayCalls: todayCall, todayTokens: todayTok,
            activityCoverage: activityCoverage,
            observedSpend: observedSpendItems,
            convertedObservedSpendUSD: observedSpend,
            declaredMonthlyCostUSD: declaredMonthlyCost,
            providerBreakdown: providers, toolBreakdown: toolActivities, topRepos: repoItems,
            dailyStats: dailyPts, codeChanges: codePts, balanceDaily: balPts,
            remainingBalances: lb, quotaStatus: qs,
            modelBreakdown: modelItems,
            updatedAt: Date()
        )
        snap.period = horizon
        snap.readFailures = await observationFailures?.snapshot() ?? []
        snap.periodSessions = sourceAgg.reduce(Int64(0)) { $0 + $1.sessions }
        snap.payloadVersion = CKSchema.payloadVersion
        snap.writerAppVersion = CKSchema.writerAppVersion
        // Sanitize at the source so every downstream consumer — local cache,
        // CloudKit sync, iOS/watchOS/widget decoders — can only ever receive
        // finite, non-negative values.
        let sanitized = snap.sanitized()
        DiagnosticJournal.log("dashboard_snapshot_stage", [
            "stage": .string("total"),
            "days": .int(days),
            "elapsed_ms": .double(Date().timeIntervalSince(snapshotStartedAt) * 1_000),
        ])
        return sanitized
    }

    // MARK: - Tool detail (conclusion card + session explorer)

    static func toolActivitySummary(source: String, sinceMs: Int64, sessionCount: Int, now: Date = Date()) async throws -> ToolActivitySummary {
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let endMs = ObservationBounds.upperExclusive(now: now, periodEnd: end)
        let paths = try await AppDatabase.shared.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT repo_path FROM usage_event
                WHERE source = ? AND ts >= ? AND ts < ? AND repo_path IS NOT NULL
                  AND (model IS NULL OR model != '<synthetic>')
                """, arguments: [source, sinceMs, endMs])
        }
        let roots = RepositoryScope.configuredRoots()
        let touched = Set(paths.compactMap { RepositoryScope.authorizedGitRoot(for: $0, roots: roots) })
        let rows = try await AppDatabase.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT repo_path, commit_hash, COALESCE(added, 0) AS a, COALESCE(deleted, 0) AS d
                FROM code_change WHERE is_merge = 0 AND ts >= ? AND ts < ?
                """, arguments: [sinceMs, endMs]).map { row in
                (path: row["repo_path"] as String? ?? "", hash: row["commit_hash"] as String? ?? "",
                 added: row["a"] as Int? ?? 0, deleted: row["d"] as Int? ?? 0)
            }
        }
        let relevant = rows.filter { row in
            guard let root = RepositoryScope.authorizedGitRoot(for: row.path, roots: roots) else { return false }
            return touched.contains(root)
        }
        let commits = try await authorizedCommits(sinceMs: sinceMs, beforeMs: endMs)
        return ToolActivitySummary(sessionCount: sessionCount,
            commitCount: Set(commits.filter { touched.contains($0.repoPath) }.map(\.identity)).count,
            addedLines: relevant.reduce(0) { $0 + max($1.added, 0) },
            deletedLines: relevant.reduce(0) { $0 + max($1.deleted, 0) })
    }

    /// Sessions with non-synthetic observations in the selected local period.
    static func sessionRows(source: String, sinceMs: Int64, now: Date = Date()) async throws -> [SessionRow] {
        let roots = RepositoryScope.configuredRoots()
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let toMs = ObservationBounds.upperExclusive(now: now, periodEnd: end)
        do {
            let rows = try await AppDatabase.shared.read { db in
                try sessionRows(in: db, source: source, sinceMs: sinceMs, beforeMs: toMs)
            }
            return authorizedSessionRepositories(rows, roots: roots)
        } catch {
            Logger.error("StatsService.sessionRows failed: \(error)")
            throw error
        }
    }

    static func authorizedSessionRepositories(
        _ rows: [SessionRow], roots: [String], resolve: ((String) -> String?)? = nil
    ) -> [SessionRow] {
        let resolvePath = resolve ?? { RepositoryScope.authorizedGitRoot(for: $0, roots: roots) }
        var resolved: [String: String] = [:]
        var unavailable: Set<String> = []
        return rows.map { row in
            var result = row
            guard let path = row.repo, !path.isEmpty else {
                result.repo = nil
                return result
            }
            if let root = resolved[path] {
                result.repo = root
            } else if unavailable.contains(path) {
                result.repo = nil
            } else if let root = resolvePath(path) {
                resolved[path] = root
                result.repo = root
            } else {
                unavailable.insert(path)
                result.repo = nil
            }
            return result
        }
    }

    static func sessionRows(in db: Database, source: String, sinceMs: Int64, beforeMs toMs: Int64) throws -> [SessionRow] {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT u.session_id AS sid,
                           MIN(u.ts) AS first_ts,
                           MAX(u.ts) AS last_ts,
                           (SELECT \(TokenAccounting.inputSQL(alias: "u3")) FROM usage_event u3
                            WHERE u3.source = u.source AND u3.session_id = u.session_id
                              AND u3.ts >= ? AND u3.ts < ?
                              AND (u3.model IS NULL OR u3.model != '<synthetic>')
                            ORDER BY u3.ts DESC, u3.id DESC LIMIT 1) AS last_input,
                           COALESCE(SUM(\(TokenAccounting.observedTotalSQL(alias: "u"))), 0) AS observed_tokens,
                           COALESCE((SELECT repo_path FROM usage_event u2
                                     WHERE u2.source = u.source AND u2.session_id = u.session_id
                                       AND u2.ts >= ? AND u2.ts < ?
                                       AND (u2.model IS NULL OR u2.model != '<synthetic>')
                                     ORDER BY u2.ts, u2.id LIMIT 1), '') AS repo,
                           s.title AS title,
                           s.window_tokens AS window
                    FROM usage_event u
                    LEFT JOIN session_info s ON s.source = u.source AND s.session_id = u.session_id
                    WHERE u.source = ? AND u.ts >= ? AND u.ts < ? AND NULLIF(u.session_id, '') IS NOT NULL
                      AND (u.model IS NULL OR u.model != '<synthetic>')
                    GROUP BY u.session_id
                    ORDER BY last_ts DESC
                    """, arguments: [sinceMs, toMs, sinceMs, toMs, source, sinceMs, toMs])
                // Batch-load all turns in the range, then aggregate per session
                // in Swift (30d ≈ 20k rows, millisecond-scale; keeps SQL simple
                // and the aggregation logic unit-testable via SessionStats.metrics).
                let turns = try Row.fetchAll(db, sql: """
                    SELECT session_id AS sid, \(TokenAccounting.inputSQL()) AS inT, cache_tokens AS cacheT
                    FROM usage_event
                    WHERE source = ? AND ts >= ? AND ts < ? AND NULLIF(session_id, '') IS NOT NULL
                      AND (model IS NULL OR model != '<synthetic>')
                      AND (\(TokenAccounting.inputSQL())) > 0
                    ORDER BY ts
                    """, arguments: [source, sinceMs, toMs])
                var grouped: [String: [TurnPoint]] = [:]
                for turn in turns {
                    let sid: String = turn["sid"]
                    let input: Int = turn["inT"] ?? 0
                    let cache: Int = turn["cacheT"] ?? 0
                    let ctx = input
                    var list = grouped[sid] ?? []
                    list.append(TurnPoint(
                        index: list.count, ts: 0, inputTokens: input,
                        cacheTokens: cache, outTokens: 0, contextTokens: ctx))
                    grouped[sid] = list
                }
                return rows.map { row in
                    let repo: String? = row["repo"]
                    let title: String? = row["title"]
                    let window: Int? = row["window"]
                    let firstTs: Int? = row["first_ts"]
                    let lastTs: Int? = row["last_ts"]
                    let lastInput: Int? = row["last_input"]
                    let sid: String? = row["sid"]
                    let m = SessionStats.metrics(
                        turns: sid.flatMap { grouped[$0] } ?? [],
                        windowTokens: window)
                    return SessionRow(
                        source: source,
                        sessionId: sid,
                        title: title,
                        repo: repo?.isEmpty == true ? nil : repo,
                        firstTs: firstTs ?? 0,
                        lastTs: lastTs ?? 0,
                        lastInput: lastInput ?? 0,
                        windowTokens: window,
                        turnCount: m.turnCount,
                        observedTokens: row["observed_tokens"] as Int64? ?? 0,
                        avgOccupancy: m.avgOccupancy,
                        avgCacheRatio: m.avgCacheRatio,
                        compactionCount: m.compactionCount)
                }
    }

    /// Full per-turn trajectory of one session (context trend chart data).
    static func turnSeries(source: String, sessionId: String, now: Date = Date()) async throws -> ContextTrend {
        let beforeMs = Int64(now.timeIntervalSince1970 * 1_000) + 1
        do {
            return try await AppDatabase.shared.read { db in
                try turnSeries(in: db, source: source, sessionId: sessionId, beforeMs: beforeMs)
            }
        } catch {
            Logger.error("StatsService.turnSeries failed: \(error)")
            throw error
        }
    }

    static func turnSeries(in db: Database, source: String, sessionId: String, beforeMs: Int64) throws -> ContextTrend {
                let turns = try TurnPoint.fetchAll(db, sql: """
                    SELECT (ROW_NUMBER() OVER (ORDER BY ts, id)) AS turn_index,
                           ts, \(TokenAccounting.inputSQL()) AS inputTokens, cache_tokens AS cacheTokens,
                           \(TokenAccounting.outputSQL()) AS outTokens,
                           \(TokenAccounting.inputSQL()) AS contextTokens
                    FROM usage_event
                    WHERE source = ? AND session_id = ? AND (\(TokenAccounting.inputSQL())) > 0
                      AND ts < ? AND (model IS NULL OR model != '<synthetic>')
                    ORDER BY ts, id
                    """, arguments: [source, sessionId, beforeMs])
                let window: Int? = try Int.fetchOne(db, sql: """
                    SELECT window_tokens FROM session_info WHERE source = ? AND session_id = ?
                    """, arguments: [source, sessionId])
                let model: String? = try String.fetchOne(db, sql: """
                    SELECT model FROM usage_event WHERE source = ? AND session_id = ?
                      AND ts < ? AND NULLIF(model, '') IS NOT NULL AND model != '<synthetic>'
                    ORDER BY ts DESC, id DESC LIMIT 1
                    """, arguments: [source, sessionId, beforeMs])
                let totals = try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS observations,
                           COALESCE(SUM(\(TokenAccounting.outputSQL())), 0) AS output,
                           COALESCE(SUM(CASE WHEN \(TokenAccounting.missingComponentsSQL) THEN 1 ELSE 0 END), 0) AS incomplete
                    FROM usage_event WHERE source = ? AND session_id = ? AND ts < ?
                      AND (model IS NULL OR model != '<synthetic>')
                    """, arguments: [source, sessionId, beforeMs])!
                return ContextTrend(turns: turns, windowTokens: window, model: model,
                                    observedOutputTokens: totals["output"] as Int?,
                                    observationCount: totals["observations"] as Int?,
                                    incompleteEvents: totals["incomplete"] as Int?)
    }

}
