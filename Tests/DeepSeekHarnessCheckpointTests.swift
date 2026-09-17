import XCTest
import GRDB
@testable import AIPulse

final class DeepSeekHarnessCheckpointTests: XCTestCase {
    private enum Failure: Error { case injected }

    private func compressedJournal() throws -> Data {
        let lines = (1...600).map { index in
            "{\"type\":\"assistant/chunk\",\"time\":\(index),\"data\":{\"turn\":\(index),\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":1,\"outputTokens\":2}}}}\n"
        }.joined()
        let input = Data(lines.utf8)
        // A valid zstd frame containing one raw block. Production bundles only
        // the decoder; this fixture does not introduce a compressor dependency.
        XCTAssertLessThan(input.count, 128 << 10)
        let blockHeader = (input.count << 3) | 1 // final block, raw type
        return Data([0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x58,
            UInt8(truncatingIfNeeded: blockHeader),
            UInt8(truncatingIfNeeded: blockHeader >> 8),
            UInt8(truncatingIfNeeded: blockHeader >> 16)]) + input
    }

    func testFailedTailKeepsCheckpointAndReplayDeduplicatesCommittedBatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aipulse-dsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl.zstd")
        let bytes = try compressedJournal()
        try bytes.write(to: file)
        let queue = try DatabaseQueue()
        try queue.write { try AppDatabase.createAllTables($0) }
        var checkpoint = 0
        var batches = 0
        let persist: ([UsageEvent]) throws -> Void = { events in
            try queue.write { db in
                _ = try LogWatcher.persistObservedEvents(in: db, rows: events.map { ($0, "deepseek") }, nowMs: 1000000)
            }
        }
        XCTAssertThrowsError(try {
            _ = try LogWatcher.parseDeepSeekHarnessStream(at: file) { events in
                batches += 1
                if batches == 2 { throw Failure.injected }
                try persist(events)
            }
            checkpoint = bytes.count
        }())
        XCTAssertEqual(checkpoint, 0)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_event") }, 512)
        let result = try LogWatcher.parseDeepSeekHarnessStream(at: file, persist: persist)
        checkpoint = bytes.count
        XCTAssertEqual(result.parsedCount, 600)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(checkpoint, bytes.count)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_event") }, 600)

        try bytes.dropLast().write(to: file)
        XCTAssertThrowsError(try LogWatcher.parseDeepSeekHarnessStream(at: file, persist: persist))
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_event") }, 600)
    }
}
