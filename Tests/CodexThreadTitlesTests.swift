import XCTest
import GRDB
@testable import AIPulse

final class CodexThreadTitlesTests: XCTestCase {
    func testReadTitlesSkipsEmpty() throws {
        let path = NSTemporaryDirectory() + "codex-threads-\(UUID().uuidString).sqlite"
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '')")
            try db.execute(sql: "INSERT INTO threads (id, title) VALUES ('t1', '排查硬盘占用')")
            try db.execute(sql: "INSERT INTO threads (id, title) VALUES ('t2', '')")
            try db.execute(sql: "INSERT INTO threads (id, title) VALUES ('t3', '   ')")
        }
        let map = CodexThreadTitles.readTitles(from: path)
        XCTAssertEqual(map["t1"], "排查硬盘占用")
        XCTAssertNil(map["t2"])
        XCTAssertNil(map["t3"])
        XCTAssertEqual(map.count, 1)
        try? FileManager.default.removeItem(atPath: path)
    }

    func testMissingFileReturnsEmpty() {
        XCTAssertTrue(CodexThreadTitles.readTitles(from: "/nonexistent/state_5.sqlite").isEmpty)
    }
}
