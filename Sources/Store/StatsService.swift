import Foundation
import GRDB

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
            let costRows = try await AppDatabase.shared.read { db -> [Row] in
                try Row.fetchAll(db, sql: """
                    SELECT (ts / 86400000) * 86400000 AS day_ts,
                           COALESCE(SUM(cost_usd), 0) AS c,
                           COUNT(*) AS cnt,
                           COALESCE(SUM(in_tokens + out_tokens + cache_tokens), 0) AS tok
                    FROM usage_event
                    WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>')
                    GROUP BY day_ts ORDER BY day_ts
                    """, arguments: [startMs, todayMs + 86_400_000])
            }

            // Net lines per day
            let lineRows = try await AppDatabase.shared.read { db -> [Row] in
                try Row.fetchAll(db, sql: """
                    SELECT (ts / 86400000) * 86400000 AS day_ts,
                           COALESCE(SUM(added - deleted), 0) AS nl
                    FROM code_change
                    WHERE is_merge = 0 AND ts >= ? AND ts < ?
                    GROUP BY day_ts ORDER BY day_ts
                    """, arguments: [startMs, todayMs + 86_400_000])
            }

            // Merge cost + lines by day
            var lineMap = [Int64: Int]()
            for r in lineRows {
                let day: Int64 = r["day_ts"]; let nl: Int = r["nl"]
                lineMap[day] = nl
            }

            var result = [DailyStat]()
            for r in costRows {
                let day: Int64 = r["day_ts"]
                let c: Double = r["c"]; let cnt: Int = r["cnt"]; let tok: Int64 = r["tok"]
                let nl = lineMap[day] ?? 0
                let cpl = nl > 0 ? c * 1000 / Double(nl) : 0  // per 1K lines
                let date = Date(timeIntervalSince1970: Double(day) / 1000)
                result.append(DailyStat(date: date, cost: c, calls: cnt, tokens: Int(tok), netLines: nl, costPerLine: cpl))
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
            let costRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT repo_path AS p, source AS s, COALESCE(SUM(cost_usd), 0) AS c
                    FROM usage_event WHERE repo_path IS NOT NULL AND ts >= ? AND ts < ?
                    GROUP BY p, s
                    """, arguments: [startMs, todayMs + 86_400_000])
            }
            let lineRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT repo_path AS p,
                           COALESCE(SUM(added), 0) AS a,
                           COALESCE(SUM(deleted), 0) AS d
                    FROM code_change WHERE is_merge = 0 AND ts >= ? AND ts < ?
                    GROUP BY p
                    """, arguments: [startMs, todayMs + 86_400_000])
            }
            var lineMap = [String: (added: Int, deleted: Int)]()
            for r in lineRows {
                if let p: String = r["p"] {
                    let a: Int64 = r["a"] ?? 0; let d: Int64 = r["d"] ?? 0
                    lineMap[p] = (Int(a), Int(d))
                }
            }

            // Build repo path → [(source, cost)] from per-source rows
            var costMap = [String: [(source: String, cost: Double)]]()
            for r in costRows {
                guard let p: String = r["p"], !p.isEmpty else { continue }
                let s: String = r["s"] ?? "unknown"
                let c: Double = r["c"]
                costMap[p, default: []].append((s, c))
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
                let tsRows: [Row] = try await AppDatabase.shared.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT repo_path, MAX(ts) AS latest
                        FROM usage_event WHERE repo_path IS NOT NULL
                        GROUP BY repo_path
                    """)
                }
                for r in tsRows {
                    if let path: String = r["repo_path"], let ts: Int64 = r["latest"] {
                        latestEventMs[URL(fileURLWithPath: path).lastPathComponent] = ts
                    }
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
        let rollingStart = cal.date(byAdding: .day, value: -29, to: todayStart)!
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
            let rows = try await AppDatabase.shared.read { db -> [Row] in
                try Row.fetchAll(db, sql: """
                    SELECT provider_id, ts, balance, currency FROM balance_snapshot
                    WHERE ts >= ? AND ts < ?
                    ORDER BY provider_id, ts
                    """, arguments: [startMs, todayMs + 86_400_000])
            }
            // Group by provider_id and compute positive deltas, converting to USD
            var results: [(String, Date, Double)] = []
            var currentPid: String? = nil
            var prevBalance: Double? = nil
            for r in rows {
                let pid: String = r["provider_id"] ?? ""
                let ts: Int64 = r["ts"] ?? 0
                let balance: Double = r["balance"] ?? 0
                let currency: String = r["currency"] ?? "USD"

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
        let rows = try await AppDatabase.shared.read { db -> [Row] in
            try Row.fetchAll(db, sql: """
                SELECT bs.provider_id, bs.balance, bs.currency
                FROM balance_snapshot bs
                INNER JOIN (
                    SELECT provider_id, MAX(ts) AS max_ts
                    FROM balance_snapshot
                    WHERE ts >= ?
                    GROUP BY provider_id
                ) latest ON bs.provider_id = latest.provider_id AND bs.ts = latest.max_ts
                """, arguments: [sinceMs])
        }
        let names = Dictionary(uniqueKeysWithValues: IntegrationRegistry.all.map { ($0.id, $0.displayName) })
        return rows.compactMap { row in
            guard let pid: String = row["provider_id"],
                  let storedBal: Double = row["balance"],
                  let cur: String = row["currency"],
                  balanceTrackedIds.contains(pid)
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

    // MARK: - Provider daily cost

    /// Daily cost grouped by provider_id for the cost chart.
    static func providerDailyCosts(days: Int) async throws -> [ProviderDailyCost] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return [] }
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let todayMs  = Int64(todayStart.timeIntervalSince1970 * 1000)

        do {
            let rows = try await AppDatabase.shared.read { db -> [Row] in
                try Row.fetchAll(db, sql: """
                    SELECT (ts / 86400000) * 86400000 AS day_ts,
                           COALESCE(provider_id, 'unknown') AS pid,
                           COALESCE(SUM(cost_usd), 0) AS c
                    FROM usage_event
                    WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>')
                    GROUP BY day_ts, pid ORDER BY day_ts, c DESC
                    """, arguments: [startMs, todayMs + 86_400_000])
            }
            let result: [ProviderDailyCost] = rows.compactMap { r in
                guard let day: Int64 = r["day_ts"],
                      let pid: String = r["pid"],
                      let c: Double = r["c"],
                      c > 0 else { return nil }
                let date = Date(timeIntervalSince1970: Double(day) / 1000)
                return ProviderDailyCost(date: date, providerId: pid, cost: c)
            }
            AppHealthMonitor.shared.clearStatsError()
            return result
        } catch {
            Logger.error("StatsService.providerDailyCosts error: \(error)")
            AppHealthMonitor.shared.reportStatsError("providerDailyCosts: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Claude Code detail

    struct ClaudeCodeStats {
        var sessionCount: Int = 0
        var avgCostPerSession: Double = 0
        var topSessionId: String = ""
        var topSessionRepo: String = ""
        var topSessionCost: Double = 0
        var modelBreakdown: [ModelDetail] = []

        struct ModelDetail {
            var model: String = ""
            var cost: Double = 0
            var pct: Double = 0
            var cacheRate: Double = 0
            var cacheSavings: Double = 0
        }
    }

    static func claudeCodeStats(sinceMs: Int64) async -> ClaudeCodeStats {
        let todayMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        var stats = ClaudeCodeStats()

        do {
            // Session count + avg cost
            let sessionRows = try await AppDatabase.shared.read { db -> [Row] in
                try Row.fetchAll(db, sql: """
                    SELECT COUNT(DISTINCT session_id) AS cnt,
                           COALESCE(SUM(cost_usd), 0) AS total
                    FROM usage_event
                    WHERE source = 'claude-code' AND (model IS NULL OR model != '<synthetic>') AND ts >= ? AND ts < ?
                    """, arguments: [sinceMs, todayMs + 86_400_000])
            }
            if let row = sessionRows.first {
                let cnt: Int = row["cnt"] ?? 0
                let total: Double = row["total"] ?? 0
                stats.sessionCount = cnt
                stats.avgCostPerSession = cnt > 0 ? total / Double(cnt) : 0
            }
            guard stats.sessionCount > 0 else { return stats }

            // Most expensive session
            let topRows = try await AppDatabase.shared.read { db -> [Row] in
                try Row.fetchAll(db, sql: """
                    SELECT session_id, COALESCE(repo_path, '') AS repo,
                           COALESCE(SUM(cost_usd), 0) AS cost
                    FROM usage_event
                    WHERE source = 'claude-code' AND session_id IS NOT NULL
                      AND ts >= ? AND ts < ?
                    GROUP BY session_id ORDER BY cost DESC LIMIT 1
                    """, arguments: [sinceMs, todayMs + 86_400_000])
            }
            if let tr = topRows.first {
                let sid: String = tr["session_id"] ?? ""
                let repo: String = tr["repo"] ?? ""
                let cost: Double = tr["cost"] ?? 0
                stats.topSessionId = String(sid.prefix(8))
                stats.topSessionRepo = URL(fileURLWithPath: repo).lastPathComponent
                stats.topSessionCost = cost
            }

            // Per-model breakdown with cache stats
            let modelRows = try await AppDatabase.shared.read { db -> [Row] in
                try Row.fetchAll(db, sql: """
                    SELECT COALESCE(model, 'unknown') AS m,
                           COALESCE(SUM(cost_usd), 0) AS c,
                           COALESCE(SUM(in_tokens), 0) AS ins,
                           COALESCE(SUM(cache_tokens), 0) AS cache
                    FROM usage_event
                    WHERE source = 'claude-code' AND (model IS NULL OR model != '<synthetic>') AND ts >= ? AND ts < ?
                    GROUP BY m ORDER BY c DESC
                    """, arguments: [sinceMs, todayMs + 86_400_000])
            }
            let totalModelCost = modelRows.reduce(0.0) { $0 + (($1["c"] as? Double) ?? 0) }
            let pricing = PricingManager.shared
            stats.modelBreakdown = modelRows.compactMap { r in
                let model: String = r["m"] ?? "unknown"
                let cost: Double = r["c"] ?? 0
                let ins: Int64 = r["ins"] ?? 0
                let cache: Int64 = r["cache"] ?? 0
                let pct = totalModelCost > 0 ? cost / totalModelCost : 0
                let totalInput = Double(ins + cache)
                let cacheRate = totalInput > 0 ? Double(cache) / totalInput : 0
                let pricing2 = pricing.pricing(for: model)
                let inPrice = pricing2?.inPricePerMtok ?? 3.0
                let cachePrice = pricing2?.cachePricePerMtok ?? 0.3
                let savings = Double(cache) / 1_000_000 * (inPrice - cachePrice)
                return ClaudeCodeStats.ModelDetail(
                    model: modelDisplayName(model), cost: cost, pct: pct,
                    cacheRate: cacheRate, cacheSavings: savings
                )
            }
        } catch {
            Logger.error("StatsService.claudeCodeStats: query failed — \(error)")
        }
        return stats
    }

    private static func modelDisplayName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
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
            let rows = try await AppDatabase.shared.read { db -> [Row] in
                try Row.fetchAll(db, sql: """
                    SELECT (ts / 86400000) * 86400000 AS day_ts,
                           COALESCE(SUM(added), 0) AS a,
                           COALESCE(SUM(deleted), 0) AS d
                    FROM code_change
                    WHERE is_merge = 0 AND ts >= ? AND ts < ?
                    GROUP BY day_ts ORDER BY day_ts
                    """, arguments: [startMs, todayMs + 86_400_000])
            }
            AppHealthMonitor.shared.clearStatsError()
            return rows.compactMap { r in
                guard let day: Int64 = r["day_ts"] else { return nil }
                let a: Int64 = r["a"] ?? 0
                let d: Int64 = r["d"] ?? 0
                let date = Date(timeIntervalSince1970: Double(day) / 1000)
                return DailyCodeChange(date: date, added: Int(a), deleted: Int(d))
            }
        } catch {
            Logger.error("StatsService.dailyCodeChanges error: \(error)")
            AppHealthMonitor.shared.reportStatsError("dailyCodeChanges: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Full snapshot builder (shared by DashboardView and Phase 4 timer)

    /// Computes everything needed for a complete DashboardSnapshot for `days`.
    /// Used by both live Dashboard loading and background cache refresh.
    static func dashboardSnapshot(days: Int) async -> DashboardSnapshot {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let rangeStart = cal.date(byAdding: .day, value: -(days - 1), to: todayStart)!
        let rangeStartMs = Int64(rangeStart.timeIntervalSince1970 * 1000)
        let todayStartMs = Int64(todayStart.timeIntervalSince1970 * 1000)
        // 30-day window + 14d lookback for correct balance delta computation.
        let monthStart = cal.date(byAdding: .day, value: -29, to: todayStart)!
        let monthStartMs = Int64(monthStart.timeIntervalSince1970 * 1000)
        let lookbackStart = cal.date(byAdding: .day, value: -14, to: monthStart)!
        let lookbackStartMs = Int64(lookbackStart.timeIntervalSince1970 * 1000)

        // Monday of this week (for unified week cost)
        let mondayStartMs = Int64(Calendar.mondayOfWeek().timeIntervalSince1970 * 1000)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        let yesterdayStartMs = Int64(yesterdayStart.timeIntervalSince1970 * 1000)
        // Previous 30-day window for period-over-period comparison
        let prevPeriodStart = cal.date(byAdding: .day, value: -30, to: todayStart)!

        //
        // ── Unified cost computation: all three ranges use combinedSpend ──
        // combinedSpend = balance API (with 14d lookback) + subscription × days
        async let todayCombined = StatsService.combinedSpend(sinceMs: todayStartMs)
        async let weekCombined = StatsService.combinedSpend(sinceMs: mondayStartMs)
        async let monthCombined = StatsService.combinedSpend(sinceMs: monthStartMs)
        async let yesterdayCombined = StatsService.combinedSpend(sinceMs: yesterdayStartMs)
        async let stats = StatsService.dailyStats(days: days)
        async let bal = StatsService.balanceDailySpend(days: days, sinceMs: rangeStartMs)
        // Query full 30 days of balance data + 14d lookback for provider breakdown
        async let balMonth = StatsService.balanceDailySpend(days: 44, sinceMs: lookbackStartMs)
        async let code = StatsService.dailyCodeChanges(days: days)
        async let repos = StatsService.repoBreakdown(days: days)
        async let pred = StatsService.prediction()
        async let latestBals = StatsService.latestRemainingBalances(sinceMs: lookbackStartMs)

        let (tc, wc, mc, yc, st, bl, bm, cd, rp, pr, lb) = await (
            todayCombined, weekCombined, monthCombined, yesterdayCombined,
            (try? stats) ?? [], (try? bal) ?? [],
            (try? balMonth) ?? [],
            (try? code) ?? [],
            (try? repos) ?? [], pred,
            (try? latestBals) ?? []
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
        let providers = provTotals.map { ProviderItem(providerId: $0.key, name: $0.value.name, cost: $0.value.cost) }.sorted { $0.cost > $1.cost }

        // Tool costs from usage_event source aggregation
        let toolStartMs = rangeStartMs
        let toolRows: [GRDB.Row] = (try? await AppDatabase.shared.read { db in
            try GRDB.Row.fetchAll(db, sql: "SELECT source AS s, COALESCE(SUM(cost_usd),0) AS c FROM usage_event WHERE ts >= ? GROUP BY s", arguments: [toolStartMs])
        }) ?? []
        var toolMap: [String: Double] = [:]
        for r in toolRows {
            if let s: String = r["s"], let c: Double = r["c"], c > 0 { toolMap[s] = c }
        }
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
        let rawTools = toolMap.compactMap { (key, cost) -> (String, Double)? in
            guard cost * scale > 0.001 else { return nil }
            let label = IntegrationRegistry.toolDisplayName(for: key)
            return (label, cost * scale)
        }.sorted { $0.1 > $1.1 }
        let toolCosts: [NameCostItem] = rawTools.map { NameCostItem(name: $0.0, cost: $0.1) }

        // Repos with subscription scaling
        let logTotal = rp.reduce(0.0) { $0 + $1.cost }
        let repoScale = toolTotal > 0 ? apiSpend / logTotal : 1.0
        let subScale = logTotal > 0 ? subTotalAll / logTotal : 0.0
        let repoItems: [RepoItem] = rp.map { r in
            let scaledCost = r.cost * repoScale + r.cost * subScale
            return RepoItem(name: r.repo, cost: scaledCost, added: r.added, deleted: r.deleted,
                            cpl: (r.added + r.deleted) > 0 ? scaledCost * 1000 / Double(r.added + r.deleted) : 0)
        }

        // Daily/balance trend points
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        let dailyPts = st.map { TrendPoint(ts: $0.date.timeIntervalSince1970, value: $0.cost, calls: $0.calls, tokens: $0.tokens, netLines: $0.netLines) }
        let codePts = cd.map { TrendPoint(ts: $0.date.timeIntervalSince1970, value: Double($0.added), calls: 0, tokens: 0, netLines: $0.added - $0.deleted, added: $0.added, deleted: $0.deleted) }
        let balPts = Dictionary(grouping: bl, by: { $0.date }).compactMap { d, v in TrendPoint(ts: d.timeIntervalSince1970, value: v.reduce(0) { $0 + $1.spend }, calls: 0, tokens: 0, netLines: 0) }
        let todayCall = Int64(st.reduce(0) { $0 + $1.calls })
        let todayTok = Int64(st.reduce(0) { $0 + $1.tokens })

        return DashboardSnapshot(
            todayCost: tc, weekCost: wc, monthCost: mc,
            yesterdaySpend: yc, previousPeriodSpend: previousPeriodSpend,
            subDaily: subAmort, todayCalls: todayCall, todayTokens: todayTok,
            providerBreakdown: providers, toolBreakdown: toolCosts, topRepos: repoItems,
            prediction: PredictionItem(monthProjected: pr.monthProjected, dailyRate: pr.dailyRate, daysRemaining: pr.daysRemaining, monthSoFar: pr.monthSoFar),
            dailyStats: dailyPts, codeChanges: codePts, balanceDaily: balPts,
            remainingBalances: lb,
            updatedAt: Date()
        )
    }
}
