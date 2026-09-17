import XCTest
import GRDB
@testable import AIPulse

final class LogCheckpointStoreTests: XCTestCase {
    private enum Failure: Error { case injected }

    func testReliableReplayPreparationIsOncePerDatabaseAndPreservesRawMoneyHistory() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            try db.execute(sql: "INSERT INTO usage_event(ts, source, in_tokens, out_tokens, cache_tokens, cost_usd, dedupe_key) VALUES (1, 'aider', 2, 3, 0, 4.5, 'history')")
            try LogCheckpointStore.save(["one": 100], in: db)
            XCTAssertTrue(try LogCheckpointStore.prepareReliableReplay(in: db))
            XCTAssertEqual(try LogCheckpointStore.load(in: db), ["one": 0])
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT cost_usd FROM usage_event"), 4.5)
            try LogCheckpointStore.save(["one": 50], in: db)
            XCTAssertFalse(try LogCheckpointStore.prepareReliableReplay(in: db))
            XCTAssertEqual(try LogCheckpointStore.load(in: db), ["one": 50])
        }
    }

    func testFailedReplayPreparationRollsBackMarkerAndOffsetsTogether() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            try LogCheckpointStore.save(["one": 100], in: db)
        }
        XCTAssertThrowsError(try queue.write { db in
            _ = try LogCheckpointStore.prepareReliableReplay(in: db)
            throw Failure.injected
        })
        try queue.write { db in
            XCTAssertEqual(try LogCheckpointStore.load(in: db), ["one": 100])
            XCTAssertTrue(try LogCheckpointStore.prepareReliableReplay(in: db))
        }
    }

    func testHistoricalRecoveryDoesNotProduceLiveConsumptionTokens() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            let rows = [8000, 9500].map {
                (UsageEvent(ts: $0, source: "aider", model: "m", inTokens: 10, outTokens: 2,
                            cacheTokens: 0, repoPath: nil, sessionId: nil, dedupeKey: "live-\($0)"), "deepseek")
            }
            XCTAssertEqual(try LogWatcher.persistObservedEvents(in: db, rows: rows, nowMs: 10000, liveSinceMs: 9000), 12)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event"), 2)
            XCTAssertEqual(try LogWatcher.persistObservedEvents(in: db, rows: rows, nowMs: 10000, liveSinceMs: 9000), 0)
        }
    }
    func testCheckpointCanRegressAfterFileRotationWithoutDeletingOtherFiles() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            try LogCheckpointStore.save(["one": 100, "two": 200], in: db)
            try LogCheckpointStore.save(["one": 5], in: db)
            XCTAssertEqual(try LogCheckpointStore.load(in: db), ["one": 5, "two": 200])
        }
    }

    func testInvalidOffsetsFailWithoutUnsignedConversionCrash() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            try db.execute(sql: "INSERT INTO logwatcher_position VALUES ('broken', -1)")
            XCTAssertThrowsError(try LogCheckpointStore.load(in: db))
            XCTAssertThrowsError(try LogCheckpointStore.save(["overflow": UInt64.max], in: db))
        }
    }

    func testFailedSaveTransactionRetainsPreviousCheckpoint() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            try LogCheckpointStore.save(["one": 10], in: db)
        }
        XCTAssertThrowsError(try queue.write { db in
            try LogCheckpointStore.save(["one": 20], in: db)
            try LogCheckpointStore.save(["overflow": UInt64.max], in: db)
        })
        XCTAssertEqual(try queue.read { try LogCheckpointStore.load(in: $0) }, ["one": 10])
    }
}
