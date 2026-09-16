import XCTest
import GRDB
@testable import AIPulse

final class DatabaseSchemaTests: XCTestCase {
    func testDebugAppDatabaseIsIsolatedFromRelease() {
        XCTAssertEqual(AppDatabase.databaseDirectoryName, "AIPulseDebug")
    }

    func testSessionInfoTableCreated() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
        }
        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("session_info"))
            let cols = try db.columns(in: "session_info").map(\.name)
            XCTAssertTrue(cols.contains("source"))
            XCTAssertTrue(cols.contains("session_id"))
            XCTAssertTrue(cols.contains("title"))
            XCTAssertTrue(cols.contains("repo"))
            XCTAssertTrue(cols.contains("first_ts"))
            XCTAssertTrue(cols.contains("last_ts"))
            XCTAssertTrue(cols.contains("completed"))
            XCTAssertTrue(cols.contains("window_tokens"))
        }
    }

    func testQuotaWindowTableSupportsMultipleWindowsPerTool() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
            for window in ["5h", "7d"] {
                try db.execute(sql: """
                    INSERT INTO quota_window_status
                      (tool_id, window_id, utilization, updated_at)
                    VALUES ('claude-code', ?, 50, 1)
                    """, arguments: [window])
            }
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM quota_window_status WHERE tool_id = 'claude-code'")
            XCTAssertEqual(count, 2)
        }
    }

    func testLegacyQuotaMigrationIsIdempotent() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
            try db.execute(sql: """
                INSERT INTO quota_status
                  (tool_id, utilization, limit_status, reset_at, window_seconds, updated_at)
                VALUES ('claude-code', 42, 'normal', 100, 18000, 10)
                """)

            try AppDatabase.migrateLegacyQuotaStatus(db)
            try AppDatabase.migrateLegacyQuotaStatus(db)

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM quota_window_status")
            let window = try String.fetchOne(
                db, sql: "SELECT window_id FROM quota_window_status WHERE tool_id = 'claude-code'")
            XCTAssertEqual(count, 1)
            XCTAssertEqual(window, "legacy")
        }
    }

    func testAttributionNormalizationPreservesToolAndRows() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
            try db.execute(sql: """
                INSERT INTO code_change
                  (commit_hash, ts, repo_path, added, deleted, attributed_tool, attribution)
                VALUES ('abc', 1, '/repo', 2, 1, 'Claude', 'exact')
                """)

            try AppDatabase.normalizeCodeAttributionConfidence(db)

            let row = try Row.fetchOne(db, sql: "SELECT * FROM code_change WHERE commit_hash = 'abc'")!
            XCTAssertEqual(row["attributed_tool"] as String?, "Claude")
            XCTAssertEqual(row["attribution"] as String?, "uncertain")
        }
    }

    func testKnownProviderAttributionBackfill() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
            try db.execute(sql: """
                INSERT INTO usage_event
                  (ts, source, provider_id, model, in_tokens, out_tokens, cache_tokens,
                   cost_usd, repo_path, session_id, dedupe_key, cost_source_id, cost_confidence)
                VALUES (?, 'codex', 'unknown', 'glm-5.3-flash', 1, 2, 0,
                        NULL, NULL, 'session-1', 'dedupe-1', 'unattributed', 'incomplete')
                """, arguments: [1])
            try db.execute(sql: """
                INSERT INTO dashboard_cache (time_range, json, updated_at)
                VALUES ('today', '{}', CURRENT_TIMESTAMP)
                """)

            try AppDatabase.backfillKnownProviderAttribution(db)

            let provider = try String.fetchOne(
                db, sql: "SELECT provider_id FROM usage_event WHERE dedupe_key = 'dedupe-1'")
            XCTAssertEqual(provider, "zhipu")
            let cacheCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dashboard_cache")
            XCTAssertEqual(cacheCount, 0)
        }
    }

    func testDeepSeekHarnessPositionInvalidationReplaysOnlyDshJournals() throws {
        let home = "/tmp/aipulse-test-home"
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
            try db.execute(sql: """
                INSERT INTO logwatcher_position (file_path, byte_offset) VALUES (?, ?)
                """, arguments: ["\(home)/.dsh/sessions/session-1/session.jsonl.zstd", 128])
            try db.execute(sql: """
                INSERT INTO logwatcher_position (file_path, byte_offset) VALUES (?, ?)
                """, arguments: ["\(home)/.codex/sessions/session.jsonl", 256])
            try db.execute(sql: """
                INSERT INTO dashboard_cache (time_range, json, updated_at)
                VALUES ('today', '{}', CURRENT_TIMESTAMP)
                """)

            try AppDatabase.invalidateDeepSeekHarnessPositions(db, homeDirectory: home)

            let dshPositions = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM logwatcher_position WHERE file_path LIKE ?",
                arguments: ["\(home)/.dsh/%"])
            let otherPositions = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM logwatcher_position WHERE file_path LIKE ?",
                arguments: ["\(home)/.codex/%"])
            let cacheCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dashboard_cache")
            XCTAssertEqual(dshPositions, 0)
            XCTAssertEqual(otherPositions, 1)
            XCTAssertEqual(cacheCount, 0)
        }
    }
}
