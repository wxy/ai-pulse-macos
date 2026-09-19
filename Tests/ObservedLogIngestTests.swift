import XCTest
import GRDB
@testable import AIPulse

final class ObservedLogIngestTests: XCTestCase {
    func testOnlyNewRecentActivityGeneratesConsumptionAndNoCatalogAmountIsStored() throws {
        let queue = try DatabaseQueue()
        let now: Int64 = 1_000_000
        func row(_ key: String, ts: Int) -> (event: UsageEvent, providerId: String) {
            (UsageEvent(ts: ts, source: "codex", model: "gpt-5", inTokens: 100, outTokens: 10,
                cacheTokens: 20, repoPath: nil, sessionId: "s", dedupeKey: key, reportedOutputTokens: 10), "openai")
        }
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            let rows = [row("fresh", ts: Int(now)), row("history", ts: 1), row("future", ts: Int(now + 1))]
            XCTAssertEqual(try LogWatcher.persistObservedEvents(in: db, rows: rows, nowMs: now), 110)
            XCTAssertEqual(try LogWatcher.persistObservedEvents(in: db, rows: rows, nowMs: now), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event WHERE cost_usd IS NOT NULL"), 0)
            try db.execute(sql: "UPDATE usage_event SET cost_usd = 42 WHERE dedupe_key = 'fresh'")
            XCTAssertEqual(try LogWatcher.persistObservedEvents(in: db, rows: rows, nowMs: now), 0)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT cost_usd FROM usage_event WHERE dedupe_key = 'fresh'"), 42)
        }
    }

    func testCopilotJournalReplayUpdatesLatestCountersWithoutCreatingAnotherRow() throws {
        let queue = try DatabaseQueue()
        let first = UsageEvent(
            ts: 100, source: "copilot", model: "gpt-5", inTokens: 100, outTokens: 10,
            cacheTokens: 20, repoPath: "/repo", sessionId: "s", dedupeKey: "copilot|s|r",
            cacheCreationTokens: 5, reportedOutputTokens: 10, reasoningTokens: 2)
        let final = UsageEvent(
            ts: 101, source: "copilot", model: "gpt-5.6-sol", inTokens: 250, outTokens: 40,
            cacheTokens: 120, repoPath: "/repo", sessionId: "s", dedupeKey: "copilot|s|r",
            cacheCreationTokens: 15, reportedOutputTokens: 40, reasoningTokens: 8)

        try queue.write { db in
            try AppDatabase.createAllTables(db)
            XCTAssertEqual(try LogWatcher.persistObservedEvents(
                in: db, rows: [(first, "openai")], nowMs: 100), 110)
            XCTAssertEqual(try LogWatcher.persistObservedEvents(
                in: db, rows: [(final, "github-copilot")], nowMs: 101), 0)

            let row = try Row.fetchOne(db, sql: """
                SELECT ts, provider_id, model, in_tokens, out_tokens, cache_tokens,
                       cache_creation_tokens, reported_output_tokens, reasoning_tokens
                FROM usage_event WHERE dedupe_key = 'copilot|s|r'
                """)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event"), 1)
            XCTAssertEqual(row?["ts"], 101)
            XCTAssertEqual(row?["provider_id"], "github-copilot")
            XCTAssertEqual(row?["model"], "gpt-5.6-sol")
            XCTAssertEqual(row?["in_tokens"], 250)
            XCTAssertEqual(row?["out_tokens"], 40)
            XCTAssertEqual(row?["cache_tokens"], 120)
            XCTAssertEqual(row?["cache_creation_tokens"], 15)
            XCTAssertEqual(row?["reported_output_tokens"], 40)
            XCTAssertEqual(row?["reasoning_tokens"], 8)
        }
    }

    func testNonCopilotReplayKeepsOriginalTokenCounters() throws {
        let queue = try DatabaseQueue()
        let original = UsageEvent(ts: 1, source: "codex", model: "m", inTokens: 100,
                                  outTokens: 10, cacheTokens: 20, repoPath: nil,
                                  sessionId: "s", dedupeKey: "stable", reportedOutputTokens: 10)
        let replay = UsageEvent(ts: 2, source: "codex", model: "m2", inTokens: 999,
                                outTokens: 99, cacheTokens: 88, repoPath: nil,
                                sessionId: "s", dedupeKey: "stable", reportedOutputTokens: 99)
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(original, "openai")], nowMs: 1)
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(replay, "openai")], nowMs: 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT ts FROM usage_event"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT in_tokens FROM usage_event"), 100)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT out_tokens FROM usage_event"), 10)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT cache_tokens FROM usage_event"), 20)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT reported_output_tokens FROM usage_event"), 99)
        }
    }
}
