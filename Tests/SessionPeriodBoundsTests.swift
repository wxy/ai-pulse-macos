import XCTest
import GRDB
@testable import AIPulse

final class SessionPeriodBoundsTests: XCTestCase {
    func testCacheCreationOnlyInputAndOutputOnlyFactsHaveSeparateCoverage() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            let input = UsageEvent(ts: 100, source: "claude-code", model: "m",
                                   inTokens: 0, outTokens: 2, cacheTokens: 0,
                                   repoPath: nil, sessionId: "coverage", dedupeKey: "creation-only",
                                   cacheCreationTokens: 30)
            let output = UsageEvent(ts: 150, source: "claude-code", model: "m",
                                    inTokens: 0, outTokens: 7, cacheTokens: 0,
                                    repoPath: nil, sessionId: "coverage", dedupeKey: "output-only",
                                    cacheCreationTokens: 0)
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(input, "anthropic"), (output, "anthropic")], nowMs: 199)
            let trend = try StatsService.turnSeries(in: db, source: "claude-code", sessionId: "coverage", beforeMs: 200)
            XCTAssertEqual(trend.turns.count, 1)
            XCTAssertEqual(trend.turns.first?.contextTokens, 30)
            XCTAssertEqual(trend.observedOutputTokens, 9)
            XCTAssertEqual(trend.observationCount, 2)
            XCTAssertEqual(trend.incompleteEvents, 0)
            let sessions = try StatsService.sessionRows(in: db, source: "claude-code", sinceMs: 0, beforeMs: 200)
            XCTAssertEqual(sessions.first?.observedTokens, 39)
            XCTAssertEqual(sessions.first?.turnCount, 1)
        }
    }

    func testFullTrajectoryFiltersFutureAndSyntheticAndUsesLatestModel() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            let facts = [(99, "z-old", "aider"), (150, "a-current", "aider"),
                         (175, "<synthetic>", "aider"), (200, "future", "aider"),
                         (160, "other-tool", "codex")]
            for (ts, model, source) in facts {
                let event = UsageEvent(ts: ts, source: source, model: model,
                                       inTokens: 10, outTokens: 2, cacheTokens: 0,
                                       repoPath: nil, sessionId: "same", dedupeKey: "trajectory-\(ts)")
                _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "deepseek")], nowMs: 199)
            }
            let trend = try StatsService.turnSeries(in: db, source: "aider", sessionId: "same", beforeMs: 200)
            XCTAssertEqual(trend.turns.map(\.ts), [99, 150], "Full trajectory includes pre-period history but not future facts")
            XCTAssertEqual(trend.model, "a-current", "Latest observed model, not lexical MAX")
            XCTAssertEqual(trend.turns.reduce(0) { $0 + $1.outTokens }, 4)
        }
    }

    func testMissingSchemaIsAReadFailureNotSuccessfulEmptyActivity() throws {
        let queue = try DatabaseQueue()
        try queue.read { db in
            XCTAssertThrowsError(try StatsService.sessionRows(in: db, source: "aider", sinceMs: 0, beforeMs: 100))
            XCTAssertThrowsError(try StatsService.turnSeries(in: db, source: "aider", sessionId: "same", beforeMs: 100))
        }
        try queue.write { db in try AppDatabase.createAllTables(db) }
        try queue.read { db in
            XCTAssertTrue(try StatsService.sessionRows(in: db, source: "aider", sinceMs: 0, beforeMs: 100).isEmpty)
        }
    }
    func testSessionContextAndRepositoryUseSameNonSyntheticPeriodAsTotals() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            let facts: [(Int, String, Int, String)] = [
                (99, "m", 900, "/old/repo"),
                (100, "m", 10, "/current/repo"),
                (150, "m", 20, "/current/repo"),
                (175, "<synthetic>", 800, "/synthetic/repo"),
                (200, "m", 700, "/future/repo")
            ]
            for (ts, model, input, path) in facts {
                let event = UsageEvent(ts: ts, source: "aider", model: model,
                                       inTokens: input, outTokens: 2, cacheTokens: 0,
                                       repoPath: path, sessionId: "same", dedupeKey: "session-\(ts)")
                _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "deepseek")], nowMs: 199)
            }
            let rows = try StatsService.sessionRows(in: db, source: "aider", sinceMs: 100, beforeMs: 200)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.observedTokens, 34)
            XCTAssertEqual(rows.first?.lastInput, 20)
            XCTAssertEqual(rows.first?.repo, "/current/repo")
            XCTAssertEqual(rows.first?.firstTs, 100)
            XCTAssertEqual(rows.first?.lastTs, 150)
            XCTAssertEqual(rows.first?.turnCount, 2)
        }
    }
}
