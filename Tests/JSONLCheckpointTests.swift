import XCTest
import GRDB
@testable import AIPulse

final class JSONLCheckpointTests: XCTestCase {
    private enum Failure: Error { case injected }

    private func fixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aipulse-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("events.jsonl"))
    }

    func testFailedLaterBatchRetainsCursorAndDatabaseReplayDeduplicates() throws {
        try fixture { url in
            let bytes = Data((1...600).map { "\($0)\n" }.joined().utf8)
            try bytes.write(to: url)
            let queue = try DatabaseQueue()
            try queue.write { db in try AppDatabase.createAllTables(db) }
            let parse: (String) -> UsageEvent? = { line in
                Int(line).map { UsageEvent(ts: $0, source: "aider", model: "m", inTokens: 1,
                    outTokens: 1, cacheTokens: 0, repoPath: nil, sessionId: "checkpoint", dedupeKey: "row-\($0)") }
            }
            var checkpoint: UInt64 = 0
            var batches = 0
            XCTAssertThrowsError(checkpoint = try JSONLCheckpoint.read(at: url, from: checkpoint,
                fileSize: UInt64(bytes.count), parse: parse, persist: { events in
                    batches += 1
                    if batches == 2 { throw Failure.injected }
                    try queue.write { db in
                        _ = try LogWatcher.persistObservedEvents(in: db, rows: events.map { ($0, "deepseek") }, nowMs: 1000000)
                    }
                }))
            XCTAssertEqual(checkpoint, 0)
            XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_event") }, 512)
            checkpoint = try JSONLCheckpoint.read(at: url, from: checkpoint, fileSize: UInt64(bytes.count),
                parse: parse, persist: { events in
                    try queue.write { db in
                        _ = try LogWatcher.persistObservedEvents(in: db, rows: events.map { ($0, "deepseek") }, nowMs: 1000000)
                    }
                })
            XCTAssertEqual(checkpoint, UInt64(bytes.count))
            XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_event") }, 600)
        }
    }

    func testIncompleteUTF8LineRemainsBeforeCursorAcrossReaderRestart() throws {
        try fixture { url in
            var bytes = Data("1\n".utf8) + Data([0xe8, 0xaf])
            try bytes.write(to: url)
            var observed: [String] = []
            let checkpoint = try JSONLCheckpoint.read(at: url, from: 0, fileSize: UInt64(bytes.count),
                parse: { $0 }, persist: { observed += $0 })
            XCTAssertEqual(checkpoint, 2)
            XCTAssertEqual(observed, ["1"])
            bytes += Data([0x8d, 0x0a])
            try bytes.write(to: url)
            let final = try JSONLCheckpoint.read(at: url, from: checkpoint, fileSize: UInt64(bytes.count),
                parse: { $0 }, persist: { observed += $0 })
            XCTAssertEqual(final, UInt64(bytes.count))
            XCTAssertEqual(observed, ["1", "词"])
        }
    }

    func testShortReadNeverReturnsAdvertisedEndPosition() throws {
        try fixture { url in
            try Data("1\n".utf8).write(to: url)
            XCTAssertThrowsError(try JSONLCheckpoint.read(at: url, from: 0, fileSize: 100,
                parse: { $0 }, persist: { _ in }))
        }
    }
}
