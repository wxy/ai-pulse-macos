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

struct ModelBreakdown: Identifiable {
    var id: String { model }
    let model: String
    let cost: Double
    let calls: Int
}

struct RepoBreakdown: Identifiable {
    var id: String { repo }
    let repo: String
    let cost: Double
    let netLines: Int
    let costPerLine: Double
}

struct Prediction {
    let monthProjected: Double
    let dailyRate: Double
    let daysRemaining: Int
    let monthSoFar: Double
}

/// Pre-aggregated stats service for the Dashboard.
enum StatsService {

    // MARK: - Daily trend

    /// Daily cost + netLines for the last `days` calendar days.
    static func dailyStats(days: Int) async -> [DailyStat] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return [] }
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
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

    // MARK: - Model breakdown (this week)

    static func modelBreakdown() async -> [ModelBreakdown] {
        let cal = Calendar.current
        let weekStart = Int64(cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!.timeIntervalSince1970 * 1000)
        do {
            let rows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT COALESCE(model, 'unknown') AS m,
                           COALESCE(SUM(cost_usd), 0) AS c,
                           COUNT(*) AS cnt
                    FROM usage_event
                    WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')
                    GROUP BY m ORDER BY c DESC
                    """, arguments: [weekStart])
            }
            return rows.map { r in
                let c: Int64 = r["cnt"]
                return ModelBreakdown(model: (r["m"] as String?) ?? "?", cost: (r["c"] as Double?) ?? 0, calls: Int(c))
            }
        } catch { return [] }
    }

    // MARK: - Repo breakdown (this week)

    static func repoBreakdown() async -> [RepoBreakdown] {
        let cal = Calendar.current
        let weekStart = Int64(cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!.timeIntervalSince1970 * 1000)
        do {
            let costRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT repo_path AS p, COALESCE(SUM(cost_usd), 0) AS c
                    FROM usage_event WHERE repo_path IS NOT NULL AND ts >= ?
                    GROUP BY p
                    """, arguments: [weekStart])
            }
            let lineRows: [Row] = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT repo_path AS p, COALESCE(SUM(added - deleted), 0) AS nl
                    FROM code_change WHERE is_merge = 0 AND ts >= ?
                    GROUP BY p
                    """, arguments: [weekStart])
            }
            var lineMap = [String: Int]()
            for r in lineRows { if let p: String = r["p"] { let nl: Int64 = r["nl"]; lineMap[p] = Int(nl) } }

            return costRows.compactMap { r in
                guard let p: String = r["p"], !p.isEmpty else { return nil }
                let c: Double = r["c"]; let nl = lineMap[p] ?? 0
                // Show repos even if netLines is 0 or negative (still tracks AI cost)
                return RepoBreakdown(repo: URL(fileURLWithPath: p).lastPathComponent, cost: c, netLines: nl, costPerLine: nl > 0 ? c * 1000 / Double(nl) : 0)
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
}
