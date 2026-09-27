import XCTest
import GRDB
@testable import AIPulse

/// The raw-unit export must ship the stored facts untouched: no cost columns,
/// no cross-unit sums, and SQL NULL preserved as empty CSV cells / JSON null
/// so a missing component never decays into zero.
final class DataExportTests: XCTestCase {
    private func seed(_ db: Database) throws {
        try AppDatabase.createAllTables(db)
        try db.execute(sql: """
            INSERT INTO usage_event (ts, source, model, in_tokens, out_tokens, cache_tokens,
                                     cache_creation_tokens, reported_output_tokens, repo_path, session_id, dedupe_key)
            VALUES (1000, 'claude-code', 'claude,x "sonnet"', 10, 5, 2, NULL, NULL, '/dev/repo', 's1', 'k1')
            """)
        try db.execute(sql: """
            INSERT INTO balance_snapshot (ts, provider_id, balance, currency)
            VALUES (2000, 'deepseek', 12.5, 'CNY')
            """)
        try db.execute(sql: """
            INSERT INTO code_change (commit_hash, ts, repo_path, added, deleted, is_merge, attributed_tool, attribution)
            VALUES ('abc', 3000, '/dev/repo', 4, 1, 0, 'claude-code', 'trailer')
            """)
        try db.execute(sql: """
            INSERT INTO git_commit (repo_path, commit_hash, ts, parent_count, author_email, attributed_tool)
            VALUES ('/dev/repo', 'abc', 3000, 1, 'a@b.c', 'claude-code')
            """)
    }

    func testUsageCSVKeepsUnitsAndEscapingWithoutCostColumns() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try seed(db)
            let csv = DataExport.csv(try DataExport.usageEvents(in: db))
            XCTAssertTrue(csv.hasPrefix("ts,source,provider_id,model,"))
            XCTAssertFalse(csv.contains("cost"), "legacy estimated prices must not regain a surface")
            // The comma inside the model name forces RFC 4180 quoting.
            XCTAssertTrue(csv.contains("\"claude,x \"\"sonnet\"\"\""))
            // NULL cache_creation/reported_output/reasoning columns export as
            // three consecutive empty fields after cache_tokens "2".
            XCTAssertTrue(csv.contains("2,,,,/dev/repo"))
        }
    }

    func testJSONPayloadPreservesNullsAndSectionNames() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try seed(db)
            let sections = [
                try DataExport.usageEvents(in: db),
                try DataExport.balanceSnapshots(in: db),
                try DataExport.codeChanges(in: db),
                try DataExport.gitCommits(in: db),
            ]
            let data = try DataExport.jsonPayload(sections: sections, exportedAt: Date(timeIntervalSince1970: 0))
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(object?["format"] as? String, "aipulse-export-v1")
            let events = object?["usage_events"] as? [[String: Any]]
            XCTAssertEqual(events?.count, 1)
            XCTAssertTrue(events?[0]["cache_creation_tokens"] is NSNull, "NULL stays null in JSON")
            XCTAssertEqual(events?[0]["in_tokens"] as? Int, 10)
            XCTAssertEqual((object?["balance_snapshots"] as? [[String: Any]])?.count, 1)
            XCTAssertEqual((object?["code_changes"] as? [[String: Any]])?.count, 1)
            XCTAssertEqual((object?["git_commits"] as? [[String: Any]])?.count, 1)
        }
    }

    func testEmptyTableStillEmitsHeader() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            let csv = DataExport.csv(try DataExport.gitCommits(in: db))
            XCTAssertTrue(csv.hasPrefix("ts,repo_path,commit_hash,"))
            XCTAssertEqual(csv.split(separator: "\n").count, 1, "header only, no invented rows")
        }
    }
}
