import XCTest
import GRDB
@testable import AIPulse

final class TokenAccountingTests: XCTestCase {
    func testCodexReportedOutputExcludesDuplicateReasoningInSQLAndSwift() throws {
        let line = #"{"timestamp":"2026-09-17T00:00:00.000Z","type":"token_count","payload":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":20,"reasoning_output_tokens":8,"total_tokens":220}}}"#
        let event = try XCTUnwrap(CodexParser.parse(line: line, cwd: nil, model: nil))
        XCTAssertEqual(event.reportedOutputTokens, 20)
        XCTAssertEqual(event.reasoningTokens, 8)
        XCTAssertEqual(TokenAccounting.observedTotal(event: event), 220)
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "openai")], nowMs: Int64(event.ts))
            try db.execute(sql: "UPDATE usage_event SET out_tokens = 28")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT \(TokenAccounting.observedTotalSQL) FROM usage_event"), 220)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT out_tokens FROM usage_event"), 28)
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT \(TokenAccounting.missingComponentsSQL) FROM usage_event"), false)
        }
    }

    func testUnrecoverableOldCodexOutputIsUnknownRatherThanCountedAsObserved() throws {
        let event = UsageEvent(ts: 1, source: "codex", model: nil, inTokens: 200,
                              outTokens: 28, cacheTokens: 100, repoPath: nil, sessionId: nil, dedupeKey: "old")
        XCTAssertEqual(TokenAccounting.observedTotal(event: event), 200)
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "openai")], nowMs: 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT \(TokenAccounting.observedTotalSQL) FROM usage_event"), 200)
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT \(TokenAccounting.missingComponentsSQL) FROM usage_event"), true)
        }
    }

    func testCodexReplayOnlyResetsRolloutPositionsWithinSessionDirectory() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            let paths = ["/test/.codex/sessions/2026/09/rollout-a.jsonl",
                         "/test/.codex/sessions-other/rollout-a.jsonl", "/test/.codex/sessions/notes.jsonl"]
            for path in paths {
                try db.execute(sql: "INSERT INTO logwatcher_position (file_path, byte_offset) VALUES (?, 1)", arguments: [path])
            }
            try AppDatabase.invalidateCodexOutputPositions(db, sessionDirectory: "/test/.codex/sessions")
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT file_path FROM logwatcher_position ORDER BY file_path"), Array(paths.dropFirst()).sorted())
        }
    }

    func testDSHOutputSubsetAndDisjointCacheMatchSQLWithoutRewritingLegacyOutput() throws {
        let line = #"{"type":"assistant/message","time":1,"data":{"usage":{"inputTokens":100,"outputTokens":50,"reasoningTokens":20,"cacheReadTokens":200,"cacheWriteTokens":25}}}"#
        let event = try XCTUnwrap(DeepSeekHarnessParser.parse(line: line, cwd: nil, model: nil, sessionId: "s"))
        XCTAssertEqual(TokenAccounting.observedTotal(event: event), 375)
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "deepseek")], nowMs: 1)
            try db.execute(sql: "UPDATE usage_event SET out_tokens = 70")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT \(TokenAccounting.observedTotalSQL) FROM usage_event"), 375)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT out_tokens FROM usage_event"), 70)
        }
    }

    func testOpenCodeIncludesSeparateReasoningAndCacheAndKeepsCacheOnlyActivity() throws {
        let event = try XCTUnwrap(OpenCodeParser.parse(json: ["role": "assistant", "id": "m",
            "tokens": ["input": 100, "output": 50, "reasoning": 20, "cache": ["read": 200, "write": 25]]], cwd: nil))
        XCTAssertEqual(TokenAccounting.observedTotal(event: event), 395)
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "unknown")], nowMs: Int64(event.ts))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT \(TokenAccounting.observedTotalSQL) FROM usage_event"), 395)
        }
        XCTAssertNotNil(OpenCodeParser.parse(json: ["role": "assistant", "id": "cache-only",
            "tokens": ["input": 0, "output": 0, "cache": ["read": 20]]], cwd: nil))
    }

    func testClaudeRawComponentsAndCreationAreCountedOnceInSwiftAndSQL() throws {
        let line = #"{"timestamp":"2026-09-17T00:00:00Z","sessionId":"s","message":{"id":"m","role":"assistant","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":200,"cache_creation_input_tokens":25}}}"#
        let event = try XCTUnwrap(ClaudeCodeParser.parse(line: line))
        XCTAssertEqual(event.inTokens, 100)
        XCTAssertEqual(event.cacheCreationTokens, 25)
        XCTAssertEqual(TokenAccounting.observedTotal(event: event), 375)
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "anthropic")], nowMs: Int64(event.ts))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT \(TokenAccounting.observedTotalSQL) FROM usage_event"), 375)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT \(TokenAccounting.inputSQL(alias: "u")) FROM usage_event u"), 325)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT in_tokens FROM usage_event"), 100)
        }
    }

    func testCodexInputAlreadyIncludesCacheAndDoesNotAddCreationAgain() {
        let event = UsageEvent(ts: 1, source: "codex", model: nil, inTokens: 1_000,
                              outTokens: 200, cacheTokens: 800, repoPath: nil,
                              sessionId: nil, dedupeKey: "c", cacheCreationTokens: 50, reportedOutputTokens: 200)
        XCTAssertEqual(TokenAccounting.observedTotal(event: event), 1_200)
    }

    func testCopilotInputAlreadyIncludesCachedTokens() {
        let event = UsageEvent(
            ts: 1, source: "copilot", model: nil, inTokens: 1_000,
            outTokens: 200, cacheTokens: 800, repoPath: nil,
            sessionId: nil, dedupeKey: "copilot", cacheCreationTokens: 50,
            reportedOutputTokens: 200, reasoningTokens: 25)

        XCTAssertEqual(TokenAccounting.observedTotal(event: event), 1_200)
        XCTAssertEqual(TokenAccounting.breakdown(
            input: event.inTokens, output: event.outTokens, cachedInput: event.cacheTokens).total, 1_200)
    }

    func testMissingClaudeCreationRemainsUnknownAndReplayEnrichesOnlyObservedMetadata() throws {
        let queue = try DatabaseQueue()
        var event = UsageEvent(ts: 1, source: "claude-code", model: nil, inTokens: 100,
                               outTokens: 50, cacheTokens: 200, repoPath: nil, sessionId: nil, dedupeKey: "m")
        XCTAssertNil(event.cacheCreationTokens)
        XCTAssertEqual(TokenAccounting.observedTotal(event: event), 350)
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "anthropic")], nowMs: 1)
            event.cacheCreationTokens = 25
            XCTAssertEqual(try LogWatcher.persistObservedEvents(in: db, rows: [(event, "anthropic")], nowMs: 1), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT \(TokenAccounting.observedTotalSQL) FROM usage_event"), 375)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT in_tokens FROM usage_event"), 100)
        }
    }

    func testClaudeComponentAdditionSaturatesAndClampsInvalidValues() {
        XCTAssertEqual(TokenAccounting.observedInput(source: "claude-code", input: Int.max,
                        cacheRead: 1, cacheCreation: 1), Int.max)
        XCTAssertEqual(TokenAccounting.observedInput(source: "claude-code", input: -1,
                        cacheRead: 2, cacheCreation: -1), 2)
    }

    func testCreationReplayResetsOnlyClaudeJSONLPositionsAndPreservesRawFacts() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            let paths = ["/test/.claude/projects/repo/s.jsonl", "/test/.claude/projects-other/s.jsonl",
                         "/test/.codex/s.jsonl", "/test/.claude/projects/repo/notes.txt"]
            for path in paths {
                try db.execute(sql: "INSERT INTO logwatcher_position (file_path, byte_offset) VALUES (?, 10)", arguments: [path])
            }
            let event = UsageEvent(ts: 1, source: "claude-code", model: nil, inTokens: 100,
                                  outTokens: 50, cacheTokens: 200, repoPath: nil, sessionId: nil, dedupeKey: "old")
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "anthropic")], nowMs: 1)
            try AppDatabase.invalidateClaudeCacheCreationPositions(db, projectDirectory: "/test/.claude/projects")
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT file_path FROM logwatcher_position ORDER BY file_path"), Array(paths.dropFirst()).sorted())
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT in_tokens FROM usage_event"), 100)
        }
    }
    func testObservedTotalDoesNotAddCachedInputTwice() {
        let result = TokenAccounting.breakdown(input: 1_000, output: 200, cachedInput: 800)

        XCTAssertEqual(result.nonCachedInput, 200)
        XCTAssertEqual(result.cachedInput, 800)
        XCTAssertEqual(result.output, 200)
        XCTAssertEqual(result.total, 1_200)
    }

    func testBreakdownClampsCorruptValues() {
        let result = TokenAccounting.breakdown(input: 100, output: -2, cachedInput: 500)

        XCTAssertEqual(result.nonCachedInput, 0)
        XCTAssertEqual(result.cachedInput, 100)
        XCTAssertEqual(result.output, 0)
        XCTAssertEqual(result.total, 100)
    }
}
