import XCTest
import GRDB
@testable import AIPulse

/// The migration test the review asked for: a synthetic old-schema database
/// (no new component columns, globally-unique commit hashes, legacy quota
/// table) migrates through `AppDatabase.setup(at:)` into the current schema
/// without touching historical facts — and a second run is a no-op. Runs
/// everywhere; the env-gated real-profile tests stay separate.
final class SyntheticMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "SyntheticMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The historical schema: what an early 1.x install looks like on disk.
    private func createOldSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE usage_event (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL, source TEXT NOT NULL, provider_id TEXT,
                model TEXT, in_tokens INTEGER DEFAULT 0, out_tokens INTEGER DEFAULT 0,
                cache_tokens INTEGER DEFAULT 0, cost_usd REAL,
                repo_path TEXT, session_id TEXT, dedupe_key TEXT UNIQUE,
                cost_source_id TEXT, cost_confidence TEXT DEFAULT 'estimated');
            CREATE TABLE code_change (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                commit_hash TEXT NOT NULL, ts INTEGER NOT NULL, repo_path TEXT NOT NULL,
                added INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0, is_merge BOOLEAN DEFAULT 0);
            CREATE UNIQUE INDEX code_change_hash_global ON code_change(commit_hash);
            CREATE TABLE quota_status (
                tool_id TEXT NOT NULL, utilization REAL NOT NULL, limit_status TEXT,
                reset_at INTEGER, updated_at INTEGER);
            CREATE TABLE git_commit_scan (
                repo_path TEXT PRIMARY KEY, head_hash TEXT, updated_at INTEGER NOT NULL,
                coverage_since INTEGER NOT NULL, author_email TEXT, status TEXT NOT NULL);
            """)
        // Old global uniqueness could hold a hash only once: a second repo
        // with the same commit was rejected at insert time. The migration
        // keeps that single row, and resets scan cursors so the composite
        // identity can recover the previously-dropped rows on the next poll.
        try db.execute(sql: """
            INSERT INTO usage_event (ts, source, model, in_tokens, out_tokens, dedupe_key)
            VALUES (1000, 'claude-code', 'claude-sonnet-4', 10, 5, 'k1');
            INSERT INTO code_change (commit_hash, ts, repo_path, added, deleted)
            VALUES ('abc', 2000, '/dev/one', 4, 1);
            INSERT INTO quota_status (tool_id, utilization, limit_status, reset_at, updated_at)
            VALUES ('claude-code', 0.5, 'ok', 9999, 1234);
            INSERT INTO git_commit_scan (repo_path, head_hash, updated_at, coverage_since, status)
            VALUES ('/dev/one', 'feed', 3000, 0, 'ready');
            """)
    }

    private func columnNames(_ db: Database, table: String) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { $0["name"] as String? })
    }

    func testOldSchemaMigratesToCurrentShapeWithoutLosingFacts() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aipulse-mig-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let legacyQueue = try DatabaseQueue(path: path)
        try legacyQueue.write { try createOldSchema($0) }
        try legacyQueue.close()

        let database = AppDatabase()
        try database.setup(at: path, defaults: defaults)

        let queue = try DatabaseQueue(path: path)
        try queue.read { db in
            // Additive component columns arrived.
            let usage = try columnNames(db, table: "usage_event")
            XCTAssertTrue(usage.contains("cache_creation_tokens"))
            XCTAssertTrue(usage.contains("reported_output_tokens"))
            XCTAssertTrue(usage.contains("reasoning_tokens"))

            // Code facts: composite identity in place, legacy row archived
            // intact, and the cursor reset so dropped cross-repo rows can be
            // re-observed on the next poll.
            let code = try columnNames(db, table: "code_change")
            XCTAssertTrue(code.contains("attributed_tool"))
            XCTAssertTrue(code.contains("attribution"))
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM code_change"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM code_change_legacy_raw"), 1)
            let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list(code_change)")
            let uniqueColumns = indexes
                .filter { ($0["unique"] as Int? ?? 0) == 1 }
                .map { index -> [String] in
                    let name: String = index["name"]
                    return try! Row.fetchAll(db, sql: "PRAGMA index_info('\(name.replacingOccurrences(of: "'", with: "''"))')")
                        .compactMap { $0["name"] as String? }
                }
            XCTAssertTrue(uniqueColumns.contains(["repo_path", "commit_hash"]),
                          "composite identity index must exist after migration")
            XCTAssertTrue(!uniqueColumns.contains(["commit_hash"]), "global hash uniqueness must be gone")

            // Legacy quota observation survived into the windowed table.
            let quota = try Row.fetchOne(db, sql: "SELECT * FROM quota_window_status WHERE window_id = 'legacy'")
            XCTAssertNotNil(quota)
            XCTAssertEqual(quota?["utilization"] as Double? ?? -1, 0.5, accuracy: 0.0001)

            // Scan cursors reset so re-polls rebuild with correct stats.
            let scan = try Row.fetchOne(db, sql: "SELECT head_hash, status FROM git_commit_scan")
            XCTAssertNil(scan?["head_hash"] as String?)
            XCTAssertEqual(scan?["status"] as String?, "partial")
        }
        try queue.close()
    }

    func testSecondSetupRunIsIdempotent() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aipulse-mig-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let legacyQueue = try DatabaseQueue(path: path)
        try legacyQueue.write { try createOldSchema($0) }
        try legacyQueue.close()

        let database = AppDatabase()
        try database.setup(at: path, defaults: defaults)
        try database.setup(at: path, defaults: defaults)

        let queue = try DatabaseQueue(path: path)
        try queue.read { db in
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM code_change"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM code_change_legacy_raw"), 1,
                           "the legacy archive must not duplicate on re-run")
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM quota_window_status"), 1)
        }
        try queue.close()
    }
}
