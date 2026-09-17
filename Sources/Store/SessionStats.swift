import Foundation
import GRDB

/// Local output in repositories touched by a tool, not AI authorship.
struct ToolActivitySummary: Sendable {
    let sessionCount: Int
    let commitCount: Int
    let addedLines: Int
    let deletedLines: Int
}

/// One session in the explorer list.
struct SessionRow: Identifiable, Equatable, Sendable {
    var id: String { "\(source)|\(sessionId ?? "")" }
    let source: String
    let sessionId: String?
    let title: String?
    var repo: String?
    let firstTs: Int
    let lastTs: Int
    let lastInput: Int
    let windowTokens: Int?

    // Session profile metrics (computed by StatsService.sessionRows)
    var turnCount: Int = 0
    /// Observed input + output in the selected period, not context capacity.
    var observedTokens: Int64 = 0
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
    var observedTokens: Int64 { sessions.reduce(0) { $0 + max($1.observedTokens, 0) } }
    let sessions: [SessionRow]
}

/// One turn of observed input context, its cached subset, and output.
struct TurnPoint: Identifiable, Equatable, Decodable, FetchableRecord {
    var id: Int { index }
    let index: Int
    let ts: Int
    let inputTokens: Int
    let cacheTokens: Int
    let outTokens: Int
    /// Computed from the source's actual input/cache representation.
    let contextTokens: Int

    enum CodingKeys: String, CodingKey {
        case index = "turn_index"
        case ts, inputTokens, cacheTokens, outTokens, contextTokens
    }
}

/// Full per-turn trajectory of one session, with compaction marks.
struct ContextTrend {
    let turns: [TurnPoint]
    let windowTokens: Int?
    let model: String?
    /// All valid observations, including output-only events excluded from the
    /// input-context plot. nil means no independent output query was supplied.
    var observedOutputTokens: Int? = nil
    var observationCount: Int? = nil
    var incompleteEvents: Int? = nil
    var cacheTokensTotal: Int { turns.reduce(0) { $0 + $1.cacheTokens } }
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



    /// Group by repository identity; rank by observed tokens, not estimated money.
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
                    sessions: sessions.sorted {
                        if $0.observedTokens != $1.observedTokens { return $0.observedTokens > $1.observedTokens }
                        if $0.lastTs != $1.lastTs { return $0.lastTs > $1.lastTs }
                        return $0.id < $1.id
                    })
            }
            .sorted {
                if $0.observedTokens != $1.observedTokens { return $0.observedTokens > $1.observedTokens }
                return $0.repo < $1.repo
            }
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
            // Multiply in Double so extreme window sizes can never overflow Int.
            let denominator = Double(turns.count) * Double(window)
            guard denominator > 0 else { return m }
            m.avgOccupancy = turns.reduce(0.0) { $0 + Double($1.contextTokens) } / denominator
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
