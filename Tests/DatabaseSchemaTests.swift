import XCTest
import GRDB
@testable import AIPulse

final class DatabaseSchemaTests: XCTestCase {
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
}
