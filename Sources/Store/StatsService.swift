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
    let costPerLine: Double                        // API-only CPL (denominator = totalChanges)
    let subscriptionSources: [CPLSource]            // editor→subscription CPLs (independent)
    var allSources: [CPLSource] {
        var srcs = [CPLSource(label: "API", cpl: costPerLine)]
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
    static func dailyStats(days: Int, sinceMs: Int64? = nil) async -> [DailyStat] {
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
            return result
        } catch {
            print("StatsService.dailyStats error: \(error)")
            return []
        }
    }

    // MARK: - Repo breakdown

    static func repoBreakdown(days: Int = 7, editorMappings: [EditorDetector.Mapping] = [], sinceMs: Int64? = nil) async -> [RepoBreakdown] {
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
                    SELECT repo_path AS p, COALESCE(SUM(cost_usd), 0) AS c
                    FROM usage_event WHERE repo_path IS NOT NULL AND ts >= ? AND ts < ?
                    GROUP BY p
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

            // Build repo path → subscription sources from certain editor detections
            let certainMappings = editorMappings.filter { $0.confidence == .certain && $0.dailySubscriptionCost > 0 }

            return costRows.compactMap { r in
                guard let p: String = r["p"], !p.isEmpty else { return nil }
                let c: Double = r["c"]
                let (a, d) = lineMap[p] ?? (0, 0)
                let total = a + d
                // CPL denominator = total changes (added + deleted), not net lines
                let cpl = total > 0 ? c * 1000 / Double(total) : 0.0

                // Collect all subscription sources matching this repo
                var subSources: [CPLSource] = []
                for m in certainMappings {
                    if p.hasSuffix(m.repoPath) || m.repoPath.hasSuffix(p) || p == m.repoPath {
                        // Subscription-only CPL: daily cost × days / totalChanges × 1000
                        let subCPL = total > 0 ? m.dailySubscriptionCost * Double(days) * 1000 / Double(total) : 0.0
                        if subCPL > 0 {
                            subSources.append(CPLSource(label: m.toolName, cpl: subCPL))
                        }
                    }
                }

                return RepoBreakdown(
                    repo: URL(fileURLWithPath: p).lastPathComponent,
                    cost: c, added: a, deleted: d, costPerLine: cpl,
                    subscriptionSources: subSources
                )
            }
        } catch { return [] }
    }

    // MARK: - Prediction

    /// Project this month's spending based on per-day rate so far.
    static func prediction() async -> Prediction {
        let cal = Calendar.current
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) else {
            return Prediction(monthProjected: 0, dailyRate: 0, daysRemaining: 0, monthSoFar: 0)
        }
        let todayStart = cal.startOfDay(for: Date())
        let daysElapsed = max(1, cal.dateComponents([.day], from: monthStart, to: todayStart).day ?? 1)
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
            return Prediction(monthProjected: 0, dailyRate: 0, daysRemaining: 0, monthSoFar: 0)
        }
    }

    // MARK: - Balance spend (daily deltas, top-up filtered)

    /// Daily spend from balance snapshots. Filters out top-ups (balance increases).
    /// Returns per-provider daily spend estimates.
    static func balanceDailySpend(days: Int, sinceMs: Int64? = nil) async -> [(providerId: String, date: Date, spend: Double)] {
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
                    SELECT provider_id, ts, balance FROM balance_snapshot
                    WHERE ts >= ? AND ts < ?
                    ORDER BY provider_id, ts
                    """, arguments: [startMs, todayMs + 86_400_000])
            }
            // Group by provider_id and compute positive deltas
            var results: [(String, Date, Double)] = []
            var currentPid: String? = nil
            var prevBalance: Double? = nil
            var prevTs: Int64? = nil
            for r in rows {
                let pid: String = r["provider_id"] ?? ""
                let ts: Int64 = r["ts"] ?? 0
                let balance: Double = r["balance"] ?? 0

                if pid == currentPid, let prev = prevBalance, balance < prev {
                    // Balance decreased → spend occurred
                    let spend = prev - balance
                    let date = cal.startOfDay(for: Date(timeIntervalSince1970: Double(ts) / 1000))
                    results.append((pid, date, spend))
                }
                currentPid = pid
                prevBalance = balance
                prevTs = ts
            }
            return results
        } catch { return [] }
    }

    // MARK: - Provider daily cost

    /// Daily cost grouped by provider_id for the cost chart.
    static func providerDailyCosts(days: Int) async -> [ProviderDailyCost] {
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
            return rows.compactMap { r in
                guard let day: Int64 = r["day_ts"],
                      let pid: String = r["pid"],
                      let c: Double = r["c"],
                      c > 0 else { return nil }
                let date = Date(timeIntervalSince1970: Double(day) / 1000)
                return ProviderDailyCost(date: date, providerId: pid, cost: c)
            }
        } catch {
            print("StatsService.providerDailyCosts error: \(error)")
            return []
        }
    }

    // MARK: - Daily code changes

    /// Daily added/deleted lines (separate, not net) for the code-change chart.
    static func dailyCodeChanges(days: Int) async -> [DailyCodeChange] {
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
            return rows.compactMap { r in
                guard let day: Int64 = r["day_ts"] else { return nil }
                let a: Int64 = r["a"] ?? 0
                let d: Int64 = r["d"] ?? 0
                let date = Date(timeIntervalSince1970: Double(day) / 1000)
                return DailyCodeChange(date: date, added: Int(a), deleted: Int(d))
            }
        } catch {
            print("StatsService.dailyCodeChanges error: \(error)")
            return []
        }
    }
}
