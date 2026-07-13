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
                // Find repos associated with this subscription tool via usage_event
                let repos: [String]
                do {
                    repos = try await AppDatabase.shared.read { db in
                        try String.fetchAll(db, sql: """
                            SELECT DISTINCT repo_path FROM usage_event
                            WHERE source = ? AND repo_path IS NOT NULL
                            AND ts >= ? AND ts < ?
                            """, arguments: [toolId, startMs, todayMs + 86_400_000])
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

    /// Project this month's spending based on per-day rate so far.
    static func prediction() async -> Prediction {
        let cal = Calendar.current
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) else {
            return Prediction(monthProjected: 0, dailyRate: 0, daysRemaining: 0, monthSoFar: 0)
        }
        let todayStart = cal.startOfDay(for: Date())
        let daysElapsed = max(1, (cal.dateComponents([.day], from: monthStart, to: todayStart).day ?? 0) + 1)
        let range = cal.range(of: .day, in: .month, for: Date())
        let totalDays = range?.count ?? 30
        let daysRemaining = totalDays - daysElapsed

        let ms = Int64(monthStart.timeIntervalSince1970 * 1000)
        do {
            let spent: Double = try await AppDatabase.shared.read { db in
                try Double.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(cost_usd), 0) FROM usage_event
                    WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')
                    """, arguments: [ms]) ?? 0
            }
            let dailyRate = spent / Double(daysElapsed)
            let projected = spent + dailyRate * Double(daysRemaining)
            return Prediction(monthProjected: projected, dailyRate: dailyRate, daysRemaining: daysRemaining, monthSoFar: spent)
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
}
