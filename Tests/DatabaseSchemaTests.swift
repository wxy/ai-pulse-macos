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

    func testKnownProviderAttributionBackfillRunsOncePerKey() throws {
        let dbQueue = try DatabaseQueue()
        let suiteName = "backfill-once-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
            try db.execute(sql: """
                INSERT INTO usage_event
                  (ts, source, provider_id, model, in_tokens, out_tokens, cache_tokens,
                   dedupe_key, cost_confidence)
                VALUES (?, 'codex', 'unknown', 'glm-5.3-flash', 1, 2, 0, 'dedupe-1', 'incomplete')
                """, arguments: [1])

            try AppDatabase.backfillKnownProviderAttributionIfNeeded(db, defaults: defaults)
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT provider_id FROM usage_event WHERE dedupe_key = 'dedupe-1'"), "zhipu")
        }
        // The completion key belongs after the database transaction commits.
        defaults.set(true, forKey: "known_provider_attribution_backfilled_v1")
        try dbQueue.write { db in

            // Simulate a row that will never match the catalog, then confirm
            // the once-key prevents the launch-time rescan/cache-wipe cycle.
            try db.execute(sql: "UPDATE usage_event SET provider_id = 'unknown' WHERE dedupe_key = 'dedupe-1'")
            try db.execute(sql: "INSERT INTO dashboard_cache (time_range, json, updated_at) VALUES ('today', '{}', CURRENT_TIMESTAMP)")
            try AppDatabase.backfillKnownProviderAttributionIfNeeded(db, defaults: defaults)

            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT provider_id FROM usage_event WHERE dedupe_key = 'dedupe-1'"), "unknown")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dashboard_cache"), 1)
        }
    }

    func testKnownProviderAttributionRetriesAfterTransactionRollback() throws {
        let dbQueue = try DatabaseQueue()
        let suiteName = "backfill-rollback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
            try db.execute(sql: """
                INSERT INTO usage_event
                  (ts, source, provider_id, model, in_tokens, out_tokens, cache_tokens,
                   dedupe_key, cost_confidence)
                VALUES (1, 'codex', 'unknown', 'glm-5.3-flash', 1, 2, 0, 'dedupe-rollback', 'incomplete')
                """)
        }

        enum SimulatedFailure: Error { case laterMigration }
        XCTAssertThrowsError(try dbQueue.write { db in
            try AppDatabase.backfillKnownProviderAttributionIfNeeded(db, defaults: defaults)
            throw SimulatedFailure.laterMigration
        })
        XCTAssertFalse(defaults.bool(forKey: "known_provider_attribution_backfilled_v1"))
        try dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT provider_id FROM usage_event WHERE dedupe_key = 'dedupe-rollback'
                """), "unknown")
        }
        try dbQueue.write { db in
            try AppDatabase.backfillKnownProviderAttributionIfNeeded(db, defaults: defaults)
        }
        defaults.set(true, forKey: "known_provider_attribution_backfilled_v1")
        try dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT provider_id FROM usage_event WHERE dedupe_key = 'dedupe-rollback'
                """), "zhipu")
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

    func testGitLineStatsInvalidationClearsWindowAndResetsCursors() throws {
        let dbQueue = try DatabaseQueue()
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
            let windowStartMs = Int(calendar.date(byAdding: .day, value: -29,
                to: calendar.startOfDay(for: now))!.timeIntervalSince1970 * 1000)
            // One derived row inside the coverage window, one older than it,
            // and a scan cursor that must be released for a rebuild.
            try db.execute(sql: """
                INSERT INTO code_change (commit_hash, ts, repo_path, added, deleted, is_merge)
                VALUES ('in-window', ?, '/a', 90, 0, 0)
                """, arguments: [windowStartMs + 1_000])
            try db.execute(sql: """
                INSERT INTO code_change (commit_hash, ts, repo_path, added, deleted, is_merge)
                VALUES ('out-of-window', ?, '/a', 5, 2, 0)
                """, arguments: [windowStartMs - 86_400_000])
            try db.execute(sql: """
                INSERT INTO git_commit_scan (repo_path, head_hash, updated_at, coverage_since, status)
                VALUES ('/a', 'abc', 0, 0, 'complete')
                """)
            try db.execute(sql: "INSERT INTO dashboard_cache (time_range, json, updated_at) VALUES ('today', '{}', CURRENT_TIMESTAMP)")

            try AppDatabase.invalidateGitLineStats(db, now: now, calendar: calendar)

            XCTAssertNil(try String.fetchOne(db, sql: """
                SELECT commit_hash FROM code_change WHERE commit_hash = 'in-window'
                """))
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT added FROM code_change WHERE commit_hash = 'out-of-window'
                """), 5)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT head_hash FROM git_commit_scan"))
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM dashboard_cache
                """), 0)
        }
    }
}
