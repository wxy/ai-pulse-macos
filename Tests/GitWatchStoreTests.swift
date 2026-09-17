import XCTest
import GRDB
@testable import AIPulse

final class GitWatchStoreTests: XCTestCase {
    private enum Failure: Error { case injected }

    func testLatestWatchSetRemovesStaleRowsWithoutRewritingRetainedMetadata() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            try db.execute(sql: "INSERT INTO gitmonitor_state (repo_path,last_commit) VALUES ('/keep','retained'),('/removed','old')")
            try db.execute(sql: "INSERT INTO git_commit (repo_path,commit_hash,ts,parent_count,author_email) VALUES ('/removed','history',1,0,'local@example.invalid')")
            try db.execute(sql: "INSERT INTO git_commit_scan (repo_path,head_hash,updated_at,coverage_since,status) VALUES ('/removed','history',2,1,'complete')")
            try GitWatchStore.synchronize(in: db, repositories: ["/keep", "/new"])
            try GitWatchStore.synchronize(in: db, repositories: ["/keep", "/new"])
        }
        XCTAssertEqual(try queue.read { try String.fetchAll($0, sql: "SELECT repo_path FROM gitmonitor_state ORDER BY repo_path") }, ["/keep", "/new"])
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT last_commit FROM gitmonitor_state WHERE repo_path='/keep'") }, "retained")
        try queue.write { try GitWatchStore.synchronize(in: $0, repositories: []) }
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM gitmonitor_state") }, 0)
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT commit_hash FROM git_commit WHERE repo_path='/removed'") }, "history")
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT head_hash FROM git_commit_scan WHERE repo_path='/removed'") }, "history")
    }

    func testFailedSynchronizationRollsBackAndCanBeRetried() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            try GitWatchStore.synchronize(in: db, repositories: ["/old"])
        }
        XCTAssertThrowsError(try queue.write { db in
            try GitWatchStore.synchronize(in: db, repositories: ["/new"])
            throw Failure.injected
        })
        XCTAssertEqual(try queue.read { try String.fetchAll($0, sql: "SELECT repo_path FROM gitmonitor_state") }, ["/old"])
        try queue.write { try GitWatchStore.synchronize(in: $0, repositories: ["/new"]) }
        XCTAssertEqual(try queue.read { try String.fetchAll($0, sql: "SELECT repo_path FROM gitmonitor_state") }, ["/new"])
    }
}
