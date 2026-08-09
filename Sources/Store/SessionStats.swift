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

    enum CodingKeys: String, CodingKey {
        case index = "turn_index"
        case ts, inputTokens, cacheTokens, outTokens, cost
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
        return Double(last.inputTokens) / Double(window)
    }
    var needsCompactionHint: Bool {
        guard let occupancy = finalOccupancy else { return false }
        return occupancy > 0.8
    }
    var compactionIndexes: Set<Int> { SessionStats.compactionMarks(turns) }
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
            let prev = turns[i - 1].inputTokens
            let curr = turns[i].inputTokens
            if prev > 0, Double(curr) < Double(prev) * 0.7 {
                marks.insert(turns[i].index)
            }
        }
        return marks
    }

    static func cacheSavings(cacheTokens: Int, inPricePerMtok: Double, cachePricePerMtok: Double) -> Double {
        Double(cacheTokens) / 1_000_000 * (inPricePerMtok - cachePricePerMtok)
    }
}
