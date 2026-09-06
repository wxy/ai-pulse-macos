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
