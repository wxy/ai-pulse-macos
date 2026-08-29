import Foundation
import GRDB
import AIPulseShared

/// Daily-aggregated stats for the Dashboard charts.
struct DailyStat: Identifiable {
    var id: Date { date }
    let date: Date
    let cost: Double
    let calls: Int
    let tokens: Int
    let netLines: Int
    let costPerLine: Double
}

struct CPLSource: Identifiable {
    var id: String { "\(label)-\(String(format: "%.4f", cpl))" }
    let label: String        // "Claude Code", "GitHub Copilot"
    let cpl: Double          // cost per 1000 lines, independent per source
}

struct RepoBreakdown: Identifiable {
    var id: String { repo }
    let repo: String
    let cost: Double
    let added: Int
    let deleted: Int
    var totalChanges: Int { added + deleted }
    let apiSources: [CPLSource]               // per-source CPLs (Claude Code, aider, etc.)
    let subscriptionSources: [CPLSource]      // editor→subscription CPLs (independent)
    var allSources: [CPLSource] {
        var srcs = apiSources
        srcs.append(contentsOf: subscriptionSources)
        return srcs.filter { $0.cpl > 0 }
    }
}

struct Prediction {
    let monthProjected: Double
    let dailyRate: Double
    let daysRemaining: Int
    let monthSoFar: Double
}

struct ProviderDailyCost: Identifiable {
    var id: String { "\(providerId)-\(Int(date.timeIntervalSince1970))" }
    let date: Date
    let providerId: String
    let cost: Double
}

struct DailyCodeChange: Identifiable {
    var id: Date { date }
    let date: Date
    let added: Int
    let deleted: Int
}

/// Pre-aggregated stats service for the Dashboard.
enum StatsService {

    // MARK: - Daily trend

    /// Daily cost + netLines for the last `days` calendar days, or from `sinceMs` if provided.
    static func dailyStats(days: Int, sinceMs: Int64? = nil) async throws -> [DailyStat] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let startMs: Int64
        if let s = sinceMs {
            startMs = s
        } else {
            guard let start = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return [] }
            startMs = Int64(start.timeIntervalSince1970 * 1000)
        }
        let todayMs  = Int64(todayStart.timeIntervalSince1970 * 1000)

        do {
            // Cost per day
            let costRows = try await AppDatabase.shared.read { db -> [(day: Int64, c: Double, cnt: Int, tok: Int64)] in
                try Row.fetchAll(db, sql: """
                    SELECT (ts / 86400000) * 86400000 AS day_ts,
                           COALESCE(SUM(cost_usd), 0) AS c,
                           COUNT(*) AS cnt,
                           COALESCE(SUM(in_tokens + out_tokens + cache_tokens), 0) AS tok
                    FROM usage_event
                    WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>')
                    GROUP BY day_ts ORDER BY day_ts
                    """, arguments: [startMs, todayMs + 86_400_000]).map { r in
                    (day: r["day_ts"] as Int64? ?? 0,
                     c: r["c"] as Double? ?? 0,
                     cnt: r["cnt"] as Int? ?? 0,
                     tok: r["tok"] as Int64? ?? 0)
                }
            }

            // Net lines per day
            let lineRows = try await AppDatabase.shared.read { db -> [(day: Int64, nl: Int)] in
                try Row.fetchAll(db, sql: """
                    SELECT (ts / 86400000) * 86400000 AS day_ts,
                           COALESCE(SUM(added - deleted), 0) AS nl
                    FROM code_change
                    WHERE is_merge = 0 AND ts >= ? AND ts < ?
                    GROUP BY day_ts ORDER BY day_ts
                    """, arguments: [startMs, todayMs + 86_400_000]).map { r in
                    (day: r["day_ts"] as Int64? ?? 0, nl: r["nl"] as Int? ?? 0)
                }
            }

            // Merge cost + lines by day
            var lineMap = [Int64: Int]()
            for r in lineRows { lineMap[r.day] = r.nl }

            var result = [DailyStat]()
            for r in costRows {
                let nl = lineMap[r.day] ?? 0
                let cpl = nl > 0 ? r.c * 1000 / Double(nl) : 0  // per 1K lines
                let date = Date(timeIntervalSince1970: Double(r.day) / 1000)
                result.append(DailyStat(date: date, cost: r.c, calls: r.cnt, tokens: Int(r.tok), netLines: nl, costPerLine: cpl))
            }
            AppHealthMonitor.shared.clearStatsError()
            return result
        } catch {
            Logger.error("StatsService.dailyStats error: \(error)")
            AppHealthMonitor.shared.reportStatsError("dailyStats: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Repo breakdown

    static func repoBreakdown(days: Int = 7, editorMappings: [EditorDetector.Mapping] = [], sinceMs: Int64? = nil) async throws -> [RepoBreakdown] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let startMs: Int64
        if let s = sinceMs {
            startMs = s
        } else {
            guard let start = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return [] }
            startMs = Int64(start.timeIntervalSince1970 * 1000)
        }
        let todayMs  = Int64(todayStart.timeIntervalSince1970 * 1000)

        do {
            let costRows = try await AppDatabase.shared.read { db -> [(p: String, s: String, c: Double)] in
                try Row.fetchAll(db, sql: """
                    SELECT repo_path AS p, source AS s, COALESCE(SUM(cost_usd), 0) AS c
                    FROM usage_event WHERE repo_path IS NOT NULL AND ts >= ? AND ts < ?
                    GROUP BY p, s
                    """, arguments: [startMs, todayMs + 86_400_000]).map { r in
                    (p: r["p"] ?? "", s: r["s"] ?? "unknown", c: r["c"] ?? 0)
                }
            }
            let lineRows = try await AppDatabase.shared.read { db -> [(p: String, a: Int, d: Int)] in
                try Row.fetchAll(db, sql: """
                    SELECT repo_path AS p,
                           COALESCE(SUM(added), 0) AS a,
                           COALESCE(SUM(deleted), 0) AS d
                    FROM code_change WHERE is_merge = 0 AND ts >= ? AND ts < ?
                    GROUP BY p
                    """, arguments: [startMs, todayMs + 86_400_000]).map { r in
                    (p: r["p"] ?? "", a: Int(r["a"] as Int64? ?? 0), d: Int(r["d"] as Int64? ?? 0))
                }
            }
            var lineMap = [String: (added: Int, deleted: Int)]()
            for r in lineRows {
                lineMap[r.p] = (r.a, r.d)
            }

            // Build repo path → [(source, cost)] from per-source rows
            var costMap = [String: [(source: String, cost: Double)]]()
            for r in costRows {
                guard !r.p.isEmpty else { continue }
                costMap[r.p, default: []].append((r.s, r.c))
            }

            // Build repo path → subscription sources from certain editor detections
            let certainMappings = editorMappings.filter { $0.confidence == .certain && $0.dailySubscriptionCost > 0 }

            // Collect CostSource subscription attribution: which repos does each sub tool touch?
            let subSources = IntegrationRegistry.activeCostSources(editorMappings: editorMappings)
                .filter { if case .subscription = $0.kind { return true }; return false }
            var subRepoMap = [String: [(label: String, dailyCost: Double)]]()
            for cs in subSources {
                guard case .subscription(let toolId, _, let monthlyFee) = cs.kind, monthlyFee > 0 else { continue }
                let daily = monthlyFee / Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
                // Subscription tools (Cursor/Copilot/Windsurf) don't have
                // their own usage_event.source entries — only log-parsers
                // (Claude Code, aider) write those. Attribute subscription
                // cost across all repos that had any usage in the period.
                let repos: [String]
                do {
                    repos = try await AppDatabase.shared.read { db in
                        try String.fetchAll(db, sql: """
                            SELECT DISTINCT repo_path FROM usage_event
                            WHERE repo_path IS NOT NULL
                            AND ts >= ? AND ts < ?
                            """, arguments: [startMs, todayMs + 86_400_000])
                    }
                } catch {
                    Logger.error("StatsService.repoBreakdown: subscription repo query failed for \(toolId): \(error)")
                    continue
                }
                for r in repos {
                    subRepoMap[r, default: []].append((cs.label, daily))
                }
            }
            // Also include editor-detected mappings
            for m in certainMappings {
                subRepoMap[m.repoPath, default: []].append((m.toolName, m.dailySubscriptionCost))
            }

            // Latest event timestamp per repo — used for stable recency-based sorting
            var latestEventMs: [String: Int64] = [:]
            do {
                let tsRows = try await AppDatabase.shared.read { db -> [(repoPath: String, latest: Int64)] in
                    try Row.fetchAll(db, sql: """
                        SELECT repo_path, MAX(ts) AS latest
                        FROM usage_event WHERE repo_path IS NOT NULL
                        GROUP BY repo_path
                    """).map { r in
                        (repoPath: r["repo_path"] ?? "", latest: r["latest"] ?? 0)
                    }
                }
                for r in tsRows {
                    latestEventMs[URL(fileURLWithPath: r.repoPath).lastPathComponent] = r.latest
                }
            } catch {
                Logger.debug("StatsService.repoBreakdown: latestEventMs query failed, continuing without it")
            }

            AppHealthMonitor.shared.clearStatsError()
            return costMap.compactMap { (p, sourceCosts) in
                let totalCost = sourceCosts.reduce(0.0) { $0 + $1.cost }
                let (a, d) = lineMap[p] ?? (0, 0)
                let total = a + d

                // Per-source API CPLs
                let apiSources: [CPLSource] = sourceCosts.compactMap { sc in
                    let cpl = total > 0 ? sc.cost * 1000 / Double(total) : 0.0
                    guard cpl > 0 else { return nil }
                    return CPLSource(label: sourceLabel(sc.source), cpl: cpl)
                }

                // Subscription CPLs for this repo (fuzzy match on path)
                var subEntries: [(label: String, dailyCost: Double)] = []
                for (rpath, entries) in subRepoMap {
                    if p.hasSuffix(rpath) || rpath.hasSuffix(p) || p == rpath {
                        subEntries.append(contentsOf: entries)
                    }
                }
                let subSourceList: [CPLSource] = subEntries.compactMap { entry in
                    let subCPL = total > 0 ? entry.dailyCost * Double(days) * 1000 / Double(total) : 0.0
                    guard subCPL > 0 else { return nil }
                    return CPLSource(label: entry.label, cpl: subCPL)
                }

                return RepoBreakdown(
                    repo: URL(fileURLWithPath: p).lastPathComponent,
                    cost: totalCost, added: a, deleted: d,
                    apiSources: apiSources,
                    subscriptionSources: subSourceList
                )
            }
            // Sort by latest activity — repos with recent usage rise to the top.
            // Sort by total changes descending as tiebreaker for repos without usage events.
            .sorted { a, b in
                let aLast = latestEventMs[a.repo] ?? 0
                let bLast = latestEventMs[b.repo] ?? 0
                if aLast != bLast { return aLast > bLast }
                return a.totalChanges > b.totalChanges
            }
        } catch {
            Logger.error("StatsService.repoBreakdown error: \(error)")
            AppHealthMonitor.shared.reportStatsError("repoBreakdown: \(error.localizedDescription)")
            throw error
        }
    }

    /// Simple currency → USD conversion (approximate rates, updated periodically).
    static func toUSD(currency: String) -> Double {
        switch currency.uppercased() {
        case "USD": return 1.0
        case "CNY": return 0.14
        case "EUR": return 1.08
        case "GBP": return 1.27
        case "JPY": return 0.0067
        default:    return 1.0
        }
    }

    /// Map usage_event.source to a human-readable label for CPL display.
    private static func sourceLabel(_ source: String) -> String {
        switch source {
        case "claude-code": return "Claude Code"
        case "aider": return "aider"
        default: return source
        }
    }

    // MARK: - Prediction

    /// Rolling 30-day projection — matches the 30d tab logic, not the natural month.
    /// `dailyRate` = last-30-day average; `monthProjected` = dailyRate × 30.
    /// `monthSoFar` stays as calendar-month spend (used in the 30d tab prediction text).
    /// `daysRemaining` = calendar days left in this month.
    static func prediction() async -> Prediction {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())

        // Calendar month for "spent X this month" and "remaining Z days" display
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) else {
            return Prediction(monthProjected: 0, dailyRate: 0, daysRemaining: 0, monthSoFar: 0)
        }
        let daysElapsed = max(1, (cal.dateComponents([.day], from: monthStart, to: todayStart).day ?? 0) + 1)
        let totalDays = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
        let daysRemaining = totalDays - daysElapsed

        // Rolling 30-day window for stable daily rate
        let rollingStart = cal.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        let rollingMs = Int64(rollingStart.timeIntervalSince1970 * 1000)
        let monthMs = Int64(monthStart.timeIntervalSince1970 * 1000)

        do {
            async let rollingSpent: Double = AppDatabase.shared.read { db in
                try Double.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(cost_usd), 0) FROM usage_event
                    WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')
                    """, arguments: [rollingMs]) ?? 0
            }
            async let monthSpent: Double = AppDatabase.shared.read { db in
                try Double.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(cost_usd), 0) FROM usage_event
                    WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')
                    """, arguments: [monthMs]) ?? 0
            }
            let (rs, ms_) = try await (rollingSpent, monthSpent)
            let dailyRate = rs / 30.0
            let projected = dailyRate * Double(totalDays)
            return Prediction(monthProjected: projected, dailyRate: dailyRate, daysRemaining: daysRemaining, monthSoFar: ms_)
        } catch {
            Logger.error("StatsService.prediction: query failed — \(error)")
            return Prediction(monthProjected: 0, dailyRate: 0, daysRemaining: 0, monthSoFar: 0)
        }
    }

    // MARK: - Balance spend (daily deltas, top-up filtered)

    /// Daily spend from balance snapshots. Filters out top-ups (balance increases).
    /// Returns per-provider daily spend estimates, converted to USD.
    static func balanceDailySpend(days: Int, sinceMs: Int64? = nil) async throws -> [(providerId: String, date: Date, spend: Double)] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let startMs: Int64 = sinceMs ?? {
            guard let s = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return 0 }
            return Int64(s.timeIntervalSince1970 * 1000)
        }()
        let todayMs = Int64(todayStart.timeIntervalSince1970 * 1000)

        do {
            let rows = try await AppDatabase.shared.read { db -> [(providerId: String, ts: Int64, balance: Double, currency: String)] in
                let fetched = try Row.fetchAll(db, sql: """
                    SELECT provider_id, ts, balance, currency FROM balance_snapshot
                    WHERE ts >= ? AND ts < ?
                    ORDER BY provider_id, ts
                    """, arguments: [startMs, todayMs + 86_400_000])
                return fetched.map { r in
                    let providerId: String = r["provider_id"] ?? ""
                    let ts: Int64 = r["ts"] ?? 0
                    let balance: Double = r["balance"] ?? 0
                    let currency: String = r["currency"] ?? "USD"
                    return (providerId: providerId, ts: ts, balance: balance, currency: currency)
                }
            }
            // Group by provider_id and compute positive deltas, converting to USD
            var results: [(String, Date, Double)] = []
            var currentPid: String? = nil
            var prevBalance: Double? = nil
            for r in rows {
                let pid = r.providerId
                let ts = r.ts
                let balance = r.balance
                let currency = r.currency

                if pid == currentPid, let prev = prevBalance, balance < prev {
                    // Balance decreased → spend occurred
                    let spend = (prev - balance) * toUSD(currency: currency)
                    let date = cal.startOfDay(for: Date(timeIntervalSince1970: Double(ts) / 1000))
                    results.append((pid, date, spend))
                }
                currentPid = pid
                prevBalance = balance
            }
            AppHealthMonitor.shared.clearStatsError()
            return results
        } catch {
            Logger.error("StatsService.balanceDailySpend error: \(error)")
            AppHealthMonitor.shared.reportStatsError("balanceDailySpend: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Combined spend (API balance spend + subscription amortization)

    /// Per-day subscription amortization: Σ (monthlyFee / daysInMonth) across
    /// active subscription CostSources.
    static func subscriptionDailyAmortization() -> Double {
        let subSources = IntegrationRegistry.activeCostSources().filter {
            if case .subscription(_, _, let fee) = $0.kind, fee > 0 { return true }
            return false
        }
        guard !subSources.isEmpty else { return 0 }
        let daysInMonth = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
        return subSources.reduce(0.0) { total, cs in
            if case .subscription(_, _, let fee) = cs.kind {
                return total + fee / daysInMonth
            }
            return total
        }
    }

    /// Combined spend (balance-derived API spend + subscription amortization) for all
    /// days on/after `sinceMs`, matching the Dashboard "Spend" chart total.
    ///
    /// The balance query looks back an extra 14 days before `sinceMs` so the first
    /// in-range daily delta is measured against a prior snapshot (otherwise it would
    /// be silently dropped and undercount the boundary day, e.g. "today").
    static func combinedSpend(sinceMs: Int64) async -> Double {
        let cal = Calendar.current
        let filterDay = cal.startOfDay(for: Date(timeIntervalSince1970: Double(sinceMs) / 1000))
        let queryStart = cal.date(byAdding: .day, value: -14, to: filterDay) ?? filterDay
        let queryStartMs = Int64(queryStart.timeIntervalSince1970 * 1000)

        let rows = (try? await balanceDailySpend(days: 1, sinceMs: queryStartMs)) ?? []
        let filterDayStart = filterDay.timeIntervalSince1970
        let api = rows
            .filter { $0.date.timeIntervalSince1970 >= filterDayStart }
            .reduce(0.0) { $0 + $1.spend }

        let today = cal.startOfDay(for: Date())
        let dayCount = max((cal.dateComponents([.day], from: filterDay, to: today).day ?? 0) + 1, 1)
        let total = api + subscriptionDailyAmortization() * Double(dayCount)
        Logger.debug("combinedSpend(sinceMs=\(sinceMs)): rows=\(rows.count) api=\(api) dayCount=\(dayCount) total=\(total)")
        return total
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
                    WHERE ts >= ?
                    GROUP BY provider_id
                ) latest ON bs.provider_id = latest.provider_id AND bs.ts = latest.max_ts
                """, arguments: [sinceMs])
            return rows.compactMap { row in
                guard let pid: String = row["provider_id"],
                      let storedBal: Double = row["balance"],
                      let cur: String = row["currency"],
                      balanceTrackedIds.contains(pid),
                      // Only show providers with a key configured — a provider
                      // whose key was deleted/cleared must not show stale balance.
                      ApiKeyManager.shared.get(pid) != nil
                else { return nil }
                let provider = ProviderRegistry.byId(pid)
                let rawBalance = provider?.balanceType == .usage ? -storedBal : storedBal
                let usdBalance = rawBalance * toUSD(currency: cur)
                return RemainingBalanceItem(
                    providerId: pid,
                    displayName: names[pid] ?? pid,
                    balance: usdBalance,
                    currency: "USD"
                )
            }
        }
    }

    /// Read subscription quota state (Claude / Copilot) from quota_status.
    static func latestQuotaStatus() async -> [QuotaStatusItem] {
        do {
            let rows = try await AppDatabase.shared.read { db -> [QuotaStatusItem] in
                try Row.fetchAll(db, sql: """
                    SELECT tool_id, utilization, limit_status, reset_at, window_seconds
                    FROM quota_status
                    """).map { r in
                    QuotaStatusItem(
                        toolId: r["tool_id"] as String? ?? "",
                        utilization: r["utilization"] as Double? ?? 0,
                        limitStatus: r["limit_status"] as String? ?? "",
                        resetAt: r["reset_at"] as Double? ?? 0,
                        windowSeconds: r["window_seconds"] as Double? ?? 0
                    )
                }
            }
            return rows.filter { !$0.toolId.isEmpty }
        } catch {
            Logger.error("StatsService.latestQuotaStatus: \(error)")
            return []
        }
    }

    // MARK: - Provider daily cost

    /// Daily cost grouped by provider_id for the cost chart.
    static func providerDailyCosts(days: Int) async throws -> [ProviderDailyCost] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return [] }
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let todayMs  = Int64(todayStart.timeIntervalSince1970 * 1000)

        do {
            let result: [ProviderDailyCost] = try await AppDatabase.shared.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT (ts / 86400000) * 86400000 AS day_ts,
                           COALESCE(provider_id, 'unknown') AS pid,
                           COALESCE(SUM(cost_usd), 0) AS c
                    FROM usage_event
                    WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>')
                    GROUP BY day_ts, pid ORDER BY day_ts, c DESC
                    """, arguments: [startMs, todayMs + 86_400_000])
                return rows.compactMap { r in
                    guard let day: Int64 = r["day_ts"],
                          let pid: String = r["pid"],
                          let c: Double = r["c"],
                          c > 0 else { return nil }
                    let date = Date(timeIntervalSince1970: Double(day) / 1000)
                    return ProviderDailyCost(date: date, providerId: pid, cost: c)
                }
            }
            AppHealthMonitor.shared.clearStatsError()
            return result
        } catch {
            Logger.error("StatsService.providerDailyCosts error: \(error)")
            AppHealthMonitor.shared.reportStatsError("providerDailyCosts: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Daily code changes

    /// Daily added/deleted lines (separate, not net) for the code-change chart.
    static func dailyCodeChanges(days: Int) async throws -> [DailyCodeChange] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return [] }
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let todayMs  = Int64(todayStart.timeIntervalSince1970 * 1000)

        do {
            AppHealthMonitor.shared.clearStatsError()
            return try await AppDatabase.shared.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT (ts / 86400000) * 86400000 AS day_ts,
                           COALESCE(SUM(added), 0) AS a,
                           COALESCE(SUM(deleted), 0) AS d
                    FROM code_change
                    WHERE is_merge = 0 AND ts >= ? AND ts < ?
                    GROUP BY day_ts ORDER BY day_ts
                    """, arguments: [startMs, todayMs + 86_400_000])
                return rows.compactMap { r in
                    guard let day: Int64 = r["day_ts"] else { return nil }
                    let a: Int64 = r["a"] ?? 0
                    let d: Int64 = r["d"] ?? 0
                    let date = Date(timeIntervalSince1970: Double(day) / 1000)
                    return DailyCodeChange(date: date, added: Int(a), deleted: Int(d))
                }
            }
        } catch {
            Logger.error("StatsService.dailyCodeChanges error: \(error)")
            AppHealthMonitor.shared.reportStatsError("dailyCodeChanges: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Full snapshot builder (shared by DashboardView and Phase 4 timer)

    /// One row of per-model usage aggregation.
    struct ModelBreakdownRow {
        let model: String
        let providerId: String
        let toolId: String?
        let tokens: Int64
        let calls: Int
        let cost: Double
    }

    /// Builds per-model attribution items from DB aggregation rows, coercing
    /// every count to non-negative and dropping non-finite costs to nil.
    static func modelBreakdown(
        rows: [(model: String, providerId: String, toolId: String?, tokens: Int64, calls: Int, cost: Double)]
    ) -> [ModelCostItem] {
        rows.map { row in
            let safeCost: Double? = row.cost.isFinite && row.cost >= 0 ? row.cost : nil
            return ModelCostItem(
                model: row.model,
                providerId: row.providerId,
                toolId: row.toolId,
                tokens: max(row.tokens, 0),
                calls: max(row.calls, 0),
                cost: safeCost,
                costIsEstimate: safeCost == nil ? nil : false)
        }
    }

    /// Providers whose balance is consumed by exactly one tool. Only these can
    /// expose per-tool/per-model spend as fact instead of an estimate.
    static func exclusiveProviders(usageByTool: [String: Set<String>]) -> Set<String> {
        var providerTools: [String: Set<String>] = [:]
        for (tool, providers) in usageByTool {
            for provider in providers {
                providerTools[provider, default: []].insert(tool)
            }
        }
        return Set(providerTools.filter { $0.value.count == 1 }.keys)
    }

    /// Aggregates token usage by repo basename. Distinct paths can share a
    /// basename (e.g. /a/new-chat and /b/new-chat), so collisions are summed
    /// instead of crashing a unique-key dictionary.
    static func repoTokenByName(_ rows: [(path: String, tokens: Int64)]) -> [String: Int64] {
        var map: [String: Int64] = [:]
        for row in rows {
            let name = URL(fileURLWithPath: row.path).lastPathComponent
            map[name, default: 0] += row.tokens
        }
        return map
    }

    struct SubscriptionProgress {
        let elapsedDays: Int
        let totalDays: Int
        let nextReset: Date?
    }

    /// Cycle progress for a user-entered subscription start date. Never
    /// amortizes money — only tracks elapsed time within the billing cycle.
    static func subscriptionProgress(start: Date?, periodDays: Int?, now: Date) -> SubscriptionProgress {
        guard let start, let periodDays, periodDays > 0 else {
            return SubscriptionProgress(elapsedDays: 0, totalDays: 30, nextReset: nil)
        }
        let cal = Calendar.current
        let cycleStart = cal.startOfDay(for: start)
        let today = cal.startOfDay(for: now)
        let rawElapsed = cal.dateComponents([.day], from: cycleStart, to: today).day ?? 0
        let elapsed = min(max(rawElapsed, 0), periodDays)
        let nextReset = cal.date(byAdding: .day, value: periodDays, to: cycleStart)
        return SubscriptionProgress(elapsedDays: elapsed, totalDays: periodDays, nextReset: nextReset)
    }

    /// Await a throwing async value, logging the failure before returning the
    /// fallback. Replaces bare `try?` in dashboardSnapshot so a data-source
    /// failure is visible in logs instead of silently degrading.
    private static func resultOrLog<T>(_ label: String, _ fallback: T, _ body: () async throws -> T) async -> T {
        do {
            return try await body()
        } catch {
            Logger.error("StatsService.dashboardSnapshot: \(label) failed: \(error)")
            return fallback
        }
    }

    /// Computes everything needed for a complete DashboardSnapshot for `days`.
    /// Used by both live Dashboard loading and background cache refresh.
    static func dashboardSnapshot(days: Int) async -> DashboardSnapshot {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let rangeStart = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
        let rangeStartMs = Int64(rangeStart.timeIntervalSince1970 * 1000)
        let todayStartMs = Int64(todayStart.timeIntervalSince1970 * 1000)
        // 30-day window + 14d lookback for correct balance delta computation.
        let monthStart = cal.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        let monthStartMs = Int64(monthStart.timeIntervalSince1970 * 1000)
        let lookbackStart = cal.date(byAdding: .day, value: -14, to: monthStart) ?? monthStart
        let lookbackStartMs = Int64(lookbackStart.timeIntervalSince1970 * 1000)

        // Monday of this week (for unified week cost)
        let mondayStartMs = Int64(Calendar.mondayOfWeek().timeIntervalSince1970 * 1000)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let yesterdayStartMs = Int64(yesterdayStart.timeIntervalSince1970 * 1000)
        // Previous 30-day window for period-over-period comparison
        let prevPeriodStart = cal.date(byAdding: .day, value: -30, to: todayStart) ?? todayStart

        //
        // ── Unified cost computation: all three ranges use combinedSpend ──
        // combinedSpend = balance API (with 14d lookback) + subscription × days
        async let tcR = StatsService.combinedSpend(sinceMs: todayStartMs)
        async let wcR = StatsService.combinedSpend(sinceMs: mondayStartMs)
        async let mcR = StatsService.combinedSpend(sinceMs: monthStartMs)
        async let ycR = StatsService.combinedSpend(sinceMs: yesterdayStartMs)
        // Each throwing source goes through resultOrLog so a failure is logged
        // (label + error) instead of being swallowed by bare `try?`.
        async let stR = resultOrLog("dailyStats", []) { try await StatsService.dailyStats(days: days) }
        async let blR = resultOrLog("balanceDailySpend", []) { try await StatsService.balanceDailySpend(days: days, sinceMs: rangeStartMs) }
        // Query full 30 days of balance data + 14d lookback for provider breakdown
        async let bmR = resultOrLog("balanceDailySpend44", []) { try await StatsService.balanceDailySpend(days: 44, sinceMs: lookbackStartMs) }
        async let cdR = resultOrLog("dailyCodeChanges", []) { try await StatsService.dailyCodeChanges(days: days) }
        async let rpR = resultOrLog("repoBreakdown", []) { try await StatsService.repoBreakdown(days: days) }
        async let prR = StatsService.prediction()
        async let lbR = resultOrLog("latestRemainingBalances", []) { try await StatsService.latestRemainingBalances(sinceMs: lookbackStartMs) }
        async let qsR = StatsService.latestQuotaStatus()
        async let modelRowsR = resultOrLog("modelBreakdown", []) { try await AppDatabase.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT model AS m, COALESCE(provider_id, 'unknown') AS pid,
                       source AS s,
                       COALESCE(SUM(in_tokens + out_tokens + cache_tokens), 0) AS tok,
                       COUNT(*) AS cnt,
                       COALESCE(SUM(cost_usd), 0) AS c
                FROM usage_event
                WHERE ts >= ? AND model IS NOT NULL AND model != '<synthetic>'
                GROUP BY m, pid
                """, arguments: [rangeStartMs]).map { r in
                    (m: r["m"] as String? ?? "",
                     pid: r["pid"] as String? ?? "unknown",
                     s: r["s"] as String? ?? "",
                     tok: r["tok"] as Int64? ?? 0,
                     cnt: r["cnt"] as Int? ?? 0,
                     c: r["c"] as Double? ?? 0)
                }
        } }
        async let sourceAggR = resultOrLog("toolUsage", []) { try await AppDatabase.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source AS s,
                       COALESCE(SUM(in_tokens + out_tokens + cache_tokens), 0) AS tok,
                       COUNT(*) AS cnt
                FROM usage_event WHERE ts >= ? GROUP BY s
                """, arguments: [rangeStartMs]).map { r in
                    (s: r["s"] as String? ?? "",
                     tok: r["tok"] as Int64? ?? 0,
                     cnt: r["cnt"] as Int? ?? 0)
                }
        } }
        async let usageByToolR = resultOrLog("toolProviders", [:]) { try await AppDatabase.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source AS s, COALESCE(provider_id, 'unknown') AS pid
                FROM usage_event WHERE ts >= ? AND provider_id IS NOT NULL
                GROUP BY s, pid
                """, arguments: [rangeStartMs]).reduce(into: [String: Set<String>]()) { map, r in
                    let s: String = r["s"] ?? ""
                    let pid: String = r["pid"] ?? "unknown"
                    if !s.isEmpty { map[s, default: []].insert(pid) }
                }
        } }
        async let repoTokensR = resultOrLog("repoTokens", []) { try await AppDatabase.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT repo_path AS p, COALESCE(SUM(in_tokens + out_tokens + cache_tokens), 0) AS tok
                FROM usage_event WHERE ts >= ? AND repo_path IS NOT NULL
                GROUP BY p
                """, arguments: [rangeStartMs]).map { r in
                    (p: r["p"] as String? ?? "", tok: r["tok"] as Int64? ?? 0)
                }
        } }
        async let sourceDailyR = resultOrLog("sourceDailyTokens", []) { try await AppDatabase.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source AS s, (ts / 86400000) * 86400000 AS day,
                       COALESCE(SUM(in_tokens + out_tokens + cache_tokens), 0) AS tok
                FROM usage_event WHERE ts >= ? GROUP BY s, day
                """, arguments: [rangeStartMs]).map { r in
                    (s: r["s"] as String? ?? "", day: r["day"] as Int64? ?? 0, tok: r["tok"] as Int64? ?? 0)
                }
        } }

        let (tc, wc, mc, yc, st, bl, bm, cd, rp, pr, lb, qs,
             modelRows, sourceAgg, usageByTool, repoTokens, sourceDaily) = await (
            tcR, wcR, mcR, ycR,
            stR, blR, bmR, cdR, rpR, prR, lbR, qsR,
            modelRowsR, sourceAggR, usageByToolR, repoTokensR, sourceDailyR
        )

        let subAmort = subscriptionDailyAmortization()

        // Previous 30-day period spend (for 30d period-over-period badge)
        let prevPeriodApiSpend = bm.filter {
            let ts = $0.date.timeIntervalSince1970
            return ts >= prevPeriodStart.timeIntervalSince1970 && ts < todayStart.timeIntervalSince1970
        }.reduce(0.0) { $0 + $1.spend }
        let prevPeriodDays = Double(min(30, cal.dateComponents([.day], from: prevPeriodStart, to: todayStart).day ?? 30))
        let previousPeriodSpend = prevPeriodApiSpend + subAmort * prevPeriodDays

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

        // Tool costs from usage_event source aggregation
        let toolStartMs = rangeStartMs
        let toolMap: [String: Double] = await resultOrLog("toolCosts", [:]) {
            try await AppDatabase.shared.read { db in
                try GRDB.Row.fetchAll(db, sql: "SELECT source AS s, COALESCE(SUM(cost_usd),0) AS c FROM usage_event WHERE ts >= ? GROUP BY s", arguments: [toolStartMs]).reduce(into: [String: Double]()) { map, r in
                    if let s: String = r["s"], let c: Double = r["c"], c > 0 { map[s] = c }
                }
            }
        }
        async let codexDetail = StatsService.toolDetail(source: "codex", sinceMs: toolStartMs)
        async let claudeDetail = StatsService.toolDetail(source: "claude-code", sinceMs: toolStartMs)
        // Keep both entries even when a tool has no sessions — the iOS detail
        // sheet falls back to an empty state instead of a dead tap.
        let detailItems = [await codexDetail, await claudeDetail]
        let toolTotal = toolMap.reduce(0.0) { $0 + $1.value }
        let enabledB = Set(IntegrationRegistry.balanceTrackedCostSources().compactMap { cs in
            if case .apiKey(let pid) = cs.kind { return pid }; return nil
        })
        // API spend for the current `days` range (for tool/repo scaling)
        let apiSpend = bm.filter {
            enabledB.contains($0.providerId) && $0.date.timeIntervalSince1970 >= rangeStart.timeIntervalSince1970
        }.reduce(0.0) { $0 + $1.spend }
        let subTotalAll = subAmort * Double(days)
        let scale = toolTotal > 0 ? apiSpend / toolTotal : 1.0
        let toolTokens = Dictionary(uniqueKeysWithValues: sourceAgg.map { ($0.s, $0.tok) })
        let toolCalls = Dictionary(uniqueKeysWithValues: sourceAgg.map { ($0.s, $0.cnt) })
        let rawTools = toolMap.compactMap { (key, cost) -> (String, String, Double)? in
            let scaled = ChartMath.finite(cost * scale, fallback: 0)
            guard scaled > 0.001 else { return nil }
            let label = IntegrationRegistry.toolDisplayName(for: key)
            return (key, label, scaled)
        }.sorted { $0.1 > $1.1 }
        let toolCosts: [NameCostItem] = rawTools.map {
            NameCostItem(name: $0.1, cost: $0.2, tokens: toolTokens[$0.0], calls: toolCalls[$0.0])
        }

        // Repos with subscription scaling
        let logTotal = rp.reduce(0.0) { $0 + $1.cost }
        // Guard the denominator: usage rows can carry a tool source without
        // any repo attribution, leaving logTotal == 0 while toolTotal > 0.
        // Dividing then yields +Inf and poisons every RepoItem cost.
        let repoScale = logTotal > 0 && toolTotal > 0 ? apiSpend / logTotal : 1.0
        let subScale = logTotal > 0 ? subTotalAll / logTotal : 0.0
        let repoTokenByName = StatsService.repoTokenByName(repoTokens.map { ($0.p, $0.tok) })
        let repoItems: [RepoItem] = rp.map { r in
            let scaledCost = ChartMath.finite(r.cost * repoScale + r.cost * subScale, fallback: 0)
            let totalChanges = Int64(r.added) + Int64(r.deleted)
            return RepoItem(name: r.repo, cost: scaledCost, added: r.added, deleted: r.deleted,
                            cpl: totalChanges > 0 ? scaledCost * 1000 / Double(totalChanges) : 0,
                            tokens: repoTokenByName[r.repo])
        }

        // Per-model attribution (BYOK mixes), sanitized by the pure helper.
        let modelItems = StatsService.modelBreakdown(rows: modelRows.map {
            (model: $0.m, providerId: $0.pid, toolId: $0.s.isEmpty ? nil : $0.s,
             tokens: $0.tok, calls: $0.cnt, cost: $0.c)
        })

        // Effective-price series: only tools whose balance provider is
        // exclusively theirs produce points — both coordinates stay facts.
        let exclusive = StatsService.exclusiveProviders(usageByTool: usageByTool)
        var providerTool: [String: String] = [:]
        for (tool, providers) in usageByTool {
            for provider in providers where exclusive.contains(provider) {
                providerTool[provider] = tool
            }
        }
        var dailyCostByProvider: [String: [Int64: Double]] = [:]
        for s in bm {
            let day = Int64(s.date.timeIntervalSince1970)
            dailyCostByProvider[s.providerId, default: [:]][day, default: 0] += s.spend
        }
        var sourceDailyByTool: [String: [Int64: Int64]] = [:]
        for row in sourceDaily {
            let daySec = row.day / 1000
            sourceDailyByTool[row.s, default: [:]][daySec] = row.tok
        }
        let rangeStartInterval = Int64(rangeStart.timeIntervalSince1970)
        let rangeEndInterval = Int64(todayStart.timeIntervalSince1970) + 86_400
        var rateSeries: [RateSeriesItem] = []
        for provider in providerTool.keys.sorted() {
            guard let tool = providerTool[provider],
                  let costs = dailyCostByProvider[provider],
                  let tokens = sourceDailyByTool[tool]
            else { continue }
            let points = costs.compactMap { day, cost -> RatePoint? in
                guard cost > 0, let tok = tokens[day], tok > 0,
                      day >= rangeStartInterval, day < rangeEndInterval
                else { return nil }
                return RatePoint(ts: Double(day), tokens: tok, cost: cost)
            }.sorted { $0.ts < $1.ts }
            if !points.isEmpty {
                rateSeries.append(RateSeriesItem(
                    toolId: tool,
                    label: IntegrationRegistry.toolDisplayName(for: tool),
                    points: points))
            }
        }

        // User-entered subscription cycle anchor (settings page).
        let defaults = UserDefaults.standard
        let subscriptionStart = defaults.object(forKey: "subscription_start") as? Date
        let subscriptionPeriodDays = defaults.object(forKey: "subscription_period_days") as? Int

        // Daily/balance trend points
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        let dailyPts = st.map { TrendPoint(ts: $0.date.timeIntervalSince1970, value: $0.cost, calls: Int64($0.calls), tokens: Int64($0.tokens), netLines: $0.netLines) }
        let codePts = cd.map { TrendPoint(ts: $0.date.timeIntervalSince1970, value: Double($0.added), calls: 0, tokens: 0, netLines: $0.added - $0.deleted, added: $0.added, deleted: $0.deleted) }
        let balPts = Dictionary(grouping: bl, by: { $0.date }).compactMap { d, v in TrendPoint(ts: d.timeIntervalSince1970, value: v.reduce(0) { $0 + $1.spend }, calls: 0, tokens: 0, netLines: 0) }
        let todayCall = Int64(st.reduce(0) { $0 + $1.calls })
        let todayTok = Int64(st.reduce(0) { $0 + $1.tokens })

        var snap = DashboardSnapshot(
            todayCost: tc, weekCost: wc, monthCost: mc,
            yesterdaySpend: yc, previousPeriodSpend: previousPeriodSpend,
            subDaily: subAmort, todayCalls: todayCall, todayTokens: todayTok,
            providerBreakdown: providers, toolBreakdown: toolCosts, topRepos: repoItems,
            prediction: PredictionItem(monthProjected: pr.monthProjected, dailyRate: pr.dailyRate, daysRemaining: pr.daysRemaining, monthSoFar: pr.monthSoFar),
            dailyStats: dailyPts, codeChanges: codePts, balanceDaily: balPts,
            remainingBalances: lb, quotaStatus: qs,
            modelBreakdown: modelItems, rateSeries: rateSeries,
            subscriptionStart: subscriptionStart,
            subscriptionPeriodDays: subscriptionPeriodDays,
            updatedAt: Date()
        )
        snap.toolDetails = detailItems
        snap.payloadVersion = CKSchema.payloadVersion
        snap.writerAppVersion = CKSchema.writerAppVersion
        // Sanitize at the source so every downstream consumer — local cache,
        // CloudKit sync, iOS/watchOS/widget decoders — can only ever receive
        // finite, non-negative values.
        return snap.sanitized()
    }

    // MARK: - Tool detail (conclusion card + session explorer)

    /// Period summary for one tool's dashboard conclusion card.
    static func toolConclusion(source: String, sinceMs: Int64) async -> ToolConclusion {
        let cal = Calendar.current
        let todayMs = Int64(cal.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        let toMs = todayMs + 86_400_000
        let rangeLen = toMs - sinceMs
        let prevSince = sinceMs - rangeLen

        let spend = await sourceSpend(source: source, sinceMs: sinceMs, toMs: toMs)
        let previous = await sourceSpend(source: source, sinceMs: prevSince, toMs: sinceMs)
        let rows = await sessionRows(source: source, sinceMs: sinceMs)
        let changes = await attributedChanges(source: source, sinceMs: sinceMs, toMs: toMs)

        let daysElapsed = max(1, Int((todayMs - sinceMs) / 86_400_000) + 1)
        let daysInMonth = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
        let totalLines = changes.added + changes.deleted
        let cpl = totalLines > 0 ? spend / Double(totalLines) * 1000 : 0
        let count = rows.count
        let otherSource = source == "codex" ? "claude-code" : "codex"
        let otherRows = await sessionRows(source: otherSource, sinceMs: sinceMs)
        let thisAvg = count > 0 ? spend / Double(count) : 0
        let otherAvg = otherRows.count > 0
            ? (await sourceSpend(source: otherSource, sinceMs: sinceMs, toMs: toMs)) / Double(otherRows.count)
            : 0

        return ToolConclusion(
            spend: spend,
            previousSpend: previous,
            deltaPct: SessionStats.deltaPct(current: spend, previous: previous),
            projectedMonth: SessionStats.projectMonth(
                spendSoFar: spend, daysElapsed: daysElapsed, daysInMonth: daysInMonth),
            sessionCount: count,
            commitCount: changes.commits,
            addedLines: changes.added,
            deletedLines: changes.deleted,
            avgCostPerSession: thisAvg,
            cpl: cpl,
            crossToolDeltaPct: otherAvg > 0 ? SessionStats.deltaPct(current: thisAvg, previous: otherAvg) : nil)
    }

    /// Sessions that had interactions in `[sinceMs, today+1d)`, newest-cost ordered.
    static func sessionRows(source: String, sinceMs: Int64) async -> [SessionRow] {
        let toMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000) + 86_400_000
        do {
            return try await AppDatabase.shared.read { db -> [SessionRow] in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT u.session_id AS sid,
                           MIN(u.ts) AS first_ts,
                           MAX(u.ts) AS last_ts,
                           (SELECT in_tokens FROM usage_event u3
                            WHERE u3.source = u.source AND u3.session_id = u.session_id
                            ORDER BY u3.ts DESC LIMIT 1) AS last_input,
                           COALESCE(SUM(u.cost_usd), 0) AS cost,
                           COALESCE((SELECT repo_path FROM usage_event u2
                                     WHERE u2.source = u.source AND u2.session_id = u.session_id
                                     ORDER BY u2.ts LIMIT 1), '') AS repo,
                           s.title AS title,
                           s.window_tokens AS window
                    FROM usage_event u
                    LEFT JOIN session_info s ON s.source = u.source AND s.session_id = u.session_id
                    WHERE u.source = ? AND u.ts >= ? AND u.ts < ? AND u.session_id IS NOT NULL
                    GROUP BY u.session_id
                    ORDER BY cost DESC
                    """, arguments: [source, sinceMs, toMs])
                // Batch-load all turns in the range, then aggregate per session
                // in Swift (30d ≈ 20k rows, millisecond-scale; keeps SQL simple
                // and the aggregation logic unit-testable via SessionStats.metrics).
                let turns = try Row.fetchAll(db, sql: """
                    SELECT session_id AS sid, in_tokens AS inT, cache_tokens AS cacheT
                    FROM usage_event
                    WHERE source = ? AND ts >= ? AND ts < ? AND session_id IS NOT NULL
                      AND (in_tokens + cache_tokens) > 0
                    ORDER BY ts
                    """, arguments: [source, sinceMs, toMs])
                var grouped: [String: [TurnPoint]] = [:]
                for turn in turns {
                    let sid: String = turn["sid"]
                    let input: Int = turn["inT"] ?? 0
                    let cache: Int = turn["cacheT"] ?? 0
                    let ctx = input + (source == "claude-code" ? cache : 0)
                    var list = grouped[sid] ?? []
                    list.append(TurnPoint(
                        index: list.count, ts: 0, inputTokens: input,
                        cacheTokens: cache, outTokens: 0, cost: 0, contextTokens: ctx))
                    grouped[sid] = list
                }
                return rows.map { row in
                    let repo: String? = row["repo"]
                    let title: String? = row["title"]
                    let window: Int? = row["window"]
                    let firstTs: Int? = row["first_ts"]
                    let lastTs: Int? = row["last_ts"]
                    let lastInput: Int? = row["last_input"]
                    let cost: Double = row["cost"] ?? 0
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
                        cost: cost,
                        windowTokens: window,
                        turnCount: m.turnCount,
                        avgOccupancy: m.avgOccupancy,
                        avgCacheRatio: m.avgCacheRatio,
                        compactionCount: m.compactionCount)
                }
            }
        } catch {
            Logger.error("StatsService.sessionRows failed: \(error)")
            return []
        }
    }

    /// One tool's detail block for the iOS detail panel: conclusion summary
    /// + session list with profile metrics.
    static func toolDetail(source: String, sinceMs: Int64) async -> ToolDetailItem {
        async let conclusion = toolConclusion(source: source, sinceMs: sinceMs)
        let rows = await sessionRows(source: source, sinceMs: sinceMs)
        let c = await conclusion
        return ToolDetailItem(
            source: source,
            conclusion: ToolConclusionItem(
                spend: c.spend,
                previousSpend: c.previousSpend,
                deltaPct: c.deltaPct,
                projectedMonth: c.projectedMonth,
                sessionCount: c.sessionCount,
                commitCount: c.commitCount,
                addedLines: c.addedLines,
                deletedLines: c.deletedLines,
                avgCostPerSession: c.avgCostPerSession,
                cpl: c.cpl,
                crossToolDeltaPct: c.crossToolDeltaPct),
            sessions: rows.map {
                ToolSessionItem(
                    sessionId: $0.sessionId,
                    title: $0.title,
                    repo: $0.repo,
                    firstTs: Int64($0.firstTs),
                    lastTs: Int64($0.lastTs),
                    cost: $0.cost,
                    windowTokens: $0.windowTokens,
                    lastInput: $0.lastInput,
                    turnCount: $0.turnCount,
                    avgOccupancy: $0.avgOccupancy,
                    avgCacheRatio: $0.avgCacheRatio,
                    compactionCount: $0.compactionCount)
            })
    }

    /// Full per-turn trajectory of one session (context trend chart data).
    static func turnSeries(source: String, sessionId: String) async -> ContextTrend {
        do {
            return try await AppDatabase.shared.read { db -> ContextTrend in
                let turns = try TurnPoint.fetchAll(db, sql: """
                    SELECT (ROW_NUMBER() OVER (ORDER BY ts)) AS turn_index,
                           ts, in_tokens AS inputTokens, cache_tokens AS cacheTokens,
                           out_tokens AS outTokens, COALESCE(cost_usd, 0) AS cost,
                           (in_tokens + CASE WHEN ? = 'claude-code' THEN cache_tokens ELSE 0 END) AS contextTokens
                    FROM usage_event
                    WHERE source = ? AND session_id = ? AND (in_tokens + cache_tokens) > 0
                    ORDER BY ts
                    """, arguments: [source, source, sessionId])
                let window: Int? = try Int.fetchOne(db, sql: """
                    SELECT window_tokens FROM session_info WHERE source = ? AND session_id = ?
                    """, arguments: [source, sessionId])
                let model: String? = try String.fetchOne(db, sql: """
                    SELECT MAX(model) FROM usage_event WHERE source = ? AND session_id = ? AND model IS NOT NULL
                    """, arguments: [source, sessionId])
                return ContextTrend(turns: turns, windowTokens: window, model: model)
            }
        } catch {
            Logger.error("StatsService.turnSeries failed: \(error)")
            return ContextTrend(turns: [], windowTokens: nil, model: nil)
        }
    }

    private static func sourceSpend(source: String, sinceMs: Int64, toMs: Int64) async -> Double {
        do {
            return try await AppDatabase.shared.read { db in
                try Double.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(cost_usd), 0) FROM usage_event
                    WHERE source = ? AND ts >= ? AND ts < ?
                    """, arguments: [source, sinceMs, toMs]) ?? 0
            }
        } catch {
            Logger.error("StatsService.sourceSpend failed: \(error)")
            return 0
        }
    }

    /// Commits / lines in repos the tool touched during the range (approximate
    /// attribution, same repo-level model as the dashboard CPL).
    private static func attributedChanges(source: String, sinceMs: Int64, toMs: Int64) async -> (commits: Int, added: Int, deleted: Int) {
        do {
            return try await AppDatabase.shared.read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT c.commit_hash) AS commits,
                           COALESCE(SUM(c.added), 0) AS added,
                           COALESCE(SUM(c.deleted), 0) AS deleted
                    FROM code_change c
                    WHERE c.repo_path IN (
                        SELECT DISTINCT u.repo_path FROM usage_event u
                        WHERE u.source = ? AND u.ts >= ? AND u.ts < ? AND u.repo_path IS NOT NULL
                    ) AND c.ts >= ? AND c.ts < ?
                    """, arguments: [source, sinceMs, toMs, sinceMs, toMs])
                let commits: Int = row?["commits"] ?? 0
                let added: Int = row?["added"] ?? 0
                let deleted: Int = row?["deleted"] ?? 0
                return (commits: commits, added: added, deleted: deleted)
            }
        } catch {
            Logger.error("StatsService.attributedChanges failed: \(error)")
            return (0, 0, 0)
        }
    }
}
