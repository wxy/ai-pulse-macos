import XCTest
import GRDB
import AIPulseShared
@testable import AIPulse

final class RobotTokenCompositionTests: XCTestCase {
    func testCompositionUsesDisjointCacheAndHalfOpenPeriod() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            // Codex input includes cache; Claude input excludes cache reads and writes.
            try db.execute(sql: """
                INSERT INTO usage_event (ts, source, in_tokens, cache_tokens, cache_creation_tokens, out_tokens, reported_output_tokens, dedupe_key)
                VALUES (100, 'codex', 100, 40, 0, 20, 20, 'codex'),
                       (199, 'claude-code', 30, 50, 10, 15, 15, 'claude'),
                       (200, 'codex', 999, 0, 0, 999, 999, 'excluded')
                """)
            let parts = try StatsService.tokenComposition(in: db, sinceMs: 100, beforeMs: 200)
            XCTAssertEqual(parts.nonCachedInput, 100)
            XCTAssertEqual(parts.cachedInput, 90)
            XCTAssertEqual(parts.output, 35)
            XCTAssertFalse(parts.isPartial)
            XCTAssertEqual(parts.nonCachedInput + parts.cachedInput + parts.output, 225)
        }
    }

    func testLegacySnapshotWithoutCompositionRemainsDecodable() throws {
        let original = DashboardSnapshot()
        let decoded = try JSONDecoder().decode(DashboardSnapshot.self, from: Data(original.jsonString().utf8))
        XCTAssertNil(decoded.tokenComposition)
    }

    func testMissingOutputIsPartialRatherThanFabricated() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            try db.execute(sql: """
                INSERT INTO usage_event (ts, source, in_tokens, cache_tokens, out_tokens, dedupe_key)
                VALUES (100, 'codex', 100, 40, 999, 'old')
                """)
            let parts = try StatsService.tokenComposition(in: db, sinceMs: 100, beforeMs: 200)
            XCTAssertEqual(parts.output, 0)
            XCTAssertTrue(parts.isPartial)
        }
    }
}
