import Foundation
import GRDB

/// Period-level summary for one tool's dashboard conclusion card.
struct ToolConclusion {
    var spend: Double = 0
    var previousSpend: Double = 0
    var deltaPct: Double = 0
    var projectedMonth: Double = 0
    var sessionCount: Int = 0
    var commitCount: Int = 0
    var addedLines: Int = 0
    var deletedLines: Int = 0
    var avgCostPerSession: Double = 0
    var cpl: Double = 0
    var crossToolDeltaPct: Double? = nil
}

/// One session in the explorer list.
struct SessionRow: Identifiable, Equatable {
    var id: String { "\(source)|\(sessionId ?? "")" }
    let source: String
    let sessionId: String?
    let title: String?
    let repo: String?
    let firstTs: Int
    let lastTs: Int
    let lastInput: Int
    let cost: Double
    let windowTokens: Int?

    // Session profile metrics (computed by StatsService.sessionRows)
    var turnCount: Int = 0
    var avgOccupancy: Double? = nil
    var avgCacheRatio: Double? = nil
    var compactionCount: Int = 0

    /// Fraction (0-1) of the model context window the session's last turn used.
    var finalOccupancy: Double? {
        guard let w = windowTokens, w > 0 else { return nil }
        return Double(lastInput) / Double(w)
    }
}

/// Sessions grouped by repo for the explorer list.
struct RepoSessionGroup: Identifiable {
    var id: String { repo }
    let repo: String
    let totalCost: Double
    let sessions: [SessionRow]
}

/// One turn of a session: context size, cache, output and cost.
struct TurnPoint: Identifiable, Equatable, Decodable, FetchableRecord {
    var id: Int { index }
    let index: Int
    let ts: Int
    let inputTokens: Int
    let cacheTokens: Int
    let outTokens: Int
    let cost: Double
    /// Total prompt context at this turn: for Codex `inputTokens` already
    /// includes the cached portion; for Claude Code (BYOK gateways) it does
    /// not, so context = input + cache. Computed in the query.
    let contextTokens: Int

    enum CodingKeys: String, CodingKey {
        case index = "turn_index"
        case ts, inputTokens, cacheTokens, outTokens, cost, contextTokens
    }
}

/// Full per-turn trajectory of one session, with compaction marks.
struct ContextTrend {
    let turns: [TurnPoint]
    let windowTokens: Int?
    let model: String?
    var cacheTokensTotal: Int { turns.reduce(0) { $0 + $1.cacheTokens } }
    var totalCost: Double { turns.reduce(0) { $0 + $1.cost } }
    var finalOccupancy: Double? {
        guard let window = windowTokens, window > 0, let last = turns.last else { return nil }
        return Double(last.contextTokens) / Double(window)
    }
    var needsCompactionHint: Bool {
        guard let occupancy = finalOccupancy else { return false }
        return occupancy > 0.8
    }
    var compactionIndexes: Set<Int> { SessionStats.compactionMarks(turns) }

    /// True when the series looks like cumulative context growth (most turns
    /// grow or hold steady). Some providers report per-request token counts
    /// that oscillate wildly; for those the context-trend interpretation is
    /// invalid and compaction marks would be noise.
    var isContextLike: Bool {
        guard turns.count >= 3 else { return false }
        var growth = 0
        for i in 1..<turns.count where turns[i].contextTokens >= turns[i - 1].contextTokens {
            growth += 1
        }
        return Double(growth) / Double(turns.count - 1) >= 0.6
    }
}

/// Pure, testable session statistics.
enum SessionStats {
    /// Label used when a session has no repo; views localize it.
    static let noRepoKey = "（无仓库）"

    static func deltaPct(current: Double, previous: Double) -> Double {
        guard previous > 0 else { return 0 }
        return (current - previous) / previous * 100
    }

    static func projectMonth(spendSoFar: Double, daysElapsed: Int, daysInMonth: Int) -> Double {
        guard daysElapsed > 0 else { return 0 }
        return spendSoFar / Double(daysElapsed) * Double(daysInMonth)
    }

    /// Group sessions by repo; groups sorted by total cost descending,
    /// sessions within a group sorted by cost descending. Nil repo → `noRepoKey`.
    static func groupSessions(_ rows: [SessionRow]) -> [RepoSessionGroup] {
        var grouped: [String: [SessionRow]] = [:]
        for row in rows {
            let key = row.repo ?? SessionStats.noRepoKey
            grouped[key, default: []].append(row)
        }
        return grouped
            .map { key, sessions in
                RepoSessionGroup(
                    repo: key,
                    totalCost: sessions.reduce(0) { $0 + $1.cost },
                    sessions: sessions.sorted { $0.cost > $1.cost })
            }
            .sorted { $0.totalCost > $1.totalCost }
    }

    /// Turn indexes where the next turn's input dropped to < 70% of the previous
    /// (context was compacted or the conversation reset).
    static func compactionMarks(_ turns: [TurnPoint]) -> Set<Int> {
        var marks = Set<Int>()
        guard turns.count > 1 else { return marks }
        for i in 1..<turns.count {
            let prev = turns[i - 1].contextTokens
            let curr = turns[i].contextTokens
            if prev > 0, Double(curr) < Double(prev) * 0.7 {
                marks.insert(turns[i].index)
            }
        }
        return marks
    }

    static func cacheSavings(cacheTokens: Int, inPricePerMtok: Double, cachePricePerMtok: Double) -> Double {
        Double(cacheTokens) / 1_000_000 * (inPricePerMtok - cachePricePerMtok)
    }

    /// Aggregated per-session profile metrics for the iOS session card.
    struct SessionMetrics: Equatable {
        var turnCount: Int = 0
        var avgOccupancy: Double?
        var avgCacheRatio: Double?
        var compactionCount: Int = 0
    }

    static func metrics(turns: [TurnPoint], windowTokens: Int?) -> SessionMetrics {
        var m = SessionMetrics()
        m.turnCount = turns.count
        if let window = windowTokens, window > 0, !turns.isEmpty {
            m.avgOccupancy = turns.reduce(0.0) { $0 + Double($1.contextTokens) } / Double(turns.count * window)
        }
        let ratios = turns
            .filter { $0.contextTokens > 0 }
            .map { Double($0.cacheTokens) / Double($0.contextTokens) }
        if !ratios.isEmpty {
            m.avgCacheRatio = ratios.reduce(0.0, +) / Double(ratios.count)
        }
        m.compactionCount = compactionMarks(turns).count
        return m
    }
}
