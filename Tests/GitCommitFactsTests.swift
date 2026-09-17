import XCTest
import GRDB
@testable import AIPulse

final class GitCommitFactsTests: XCTestCase {
    func testCodeFactsWithSameHashRemainSeparateAndIdempotent() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            for repo in ["/a", "/b", "/a"] {
                let change = CodeChange(commitHash: "same", ts: 100, repoPath: repo,
                                        added: 10, deleted: 2, isMerge: false)
                _ = try GitMonitor.persistBatch(in: db, repo: repo, commits: [], changes: [change],
                                               headHash: "same", coverageSince: 0, authorEmail: nil, complete: true)
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM code_change"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(added) FROM code_change"), 20)
        }
    }

    func testCodeIdentityMigrationPreservesRawHistoryAndResetsOnlyDerivedCursor() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE code_change (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, commit_hash TEXT NOT NULL UNIQUE,
                  ts INTEGER NOT NULL, repo_path TEXT NOT NULL, added INTEGER, deleted INTEGER,
                  is_merge BOOLEAN, attributed_tool TEXT, attribution TEXT);
                INSERT INTO code_change VALUES (7, 'same', 100, '/a', 10, 2, 0, 'Claude', 'trailer');
                """)
            try AppDatabase.createAllTables(db)
            _ = try GitMonitor.persistBatch(in: db, repo: "/a", commits: [], changes: [],
                                           headHash: "same", coverageSince: 50, authorEmail: nil, complete: true)
            try AppDatabase.migrateRepositoryCodeIdentity(db)
            try AppDatabase.migrateRepositoryCodeIdentity(db)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT id FROM code_change"), 7)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT added FROM code_change_legacy_raw"), 10)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT attributed_tool FROM code_change"), "Claude")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT head_hash FROM git_commit_scan"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT coverage_since FROM git_commit_scan"), 50)
            let change = CodeChange(commitHash: "same", ts: 100, repoPath: "/b", added: 3, deleted: 1, isMerge: false)
            _ = try GitMonitor.persistBatch(in: db, repo: "/b", commits: [], changes: [change],
                                           headHash: "same", coverageSince: 50, authorEmail: nil, complete: true)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM code_change"), 2)
        }
    }

    func testZeroLineCommitsAreIndependentAndIdempotentAcrossRepositories() throws {
        let queue = try DatabaseQueue()
        let commits = [GitCommitSummary(hash: "empty", ts: 1, parentCount: 1, message: "empty", authorEmail: "a@test"),
                       GitCommitSummary(hash: "merge", ts: 2, parentCount: 2, message: "merge", authorEmail: "a@test")]
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            XCTAssertTrue(try GitMonitor.persistBatch(in: db, repo: "/a", commits: commits, changes: [],
                headHash: "merge", coverageSince: 0, authorEmail: nil, complete: true))
            XCTAssertFalse(try GitMonitor.persistBatch(in: db, repo: "/a", commits: commits, changes: [],
                headHash: "merge", coverageSince: 0, authorEmail: nil, complete: true))
            XCTAssertTrue(try GitMonitor.persistBatch(in: db, repo: "/b", commits: commits, changes: [],
                headHash: "merge", coverageSince: 0, authorEmail: nil, complete: true))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM git_commit"), 4)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM code_change"), 0)
        }
    }

    func testFailedTransactionDoesNotAdvanceCursorOrLeaveCommitFacts() throws {
        let queue = try DatabaseQueue()
        try queue.write { try AppDatabase.createAllTables($0) }
        XCTAssertThrowsError(try queue.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_scan BEFORE INSERT ON git_commit_scan BEGIN SELECT RAISE(ABORT, 'test'); END")
            _ = try GitMonitor.persistBatch(in: db, repo: "/a",
                commits: [GitCommitSummary(hash: "one", ts: 1, parentCount: 0, message: "", authorEmail: "")],
                changes: [], headHash: "one", coverageSince: 0, authorEmail: nil, complete: true)
        })
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM git_commit"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM git_commit_scan"), 0)
        }
    }

    func testCodeMigrationFailureDoesNotAlterHistory() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE code_change (id INTEGER PRIMARY KEY, commit_hash TEXT UNIQUE,
                  ts INTEGER, repo_path TEXT, added INTEGER, deleted INTEGER, is_merge BOOLEAN,
                  attributed_tool TEXT, attribution TEXT);
                INSERT INTO code_change VALUES (7, 'same', 100, '/a', 10, 2, 0, NULL, NULL);
                CREATE TABLE code_change_legacy_raw (marker TEXT);
                INSERT INTO code_change_legacy_raw VALUES ('keep');
                """)
        }
        XCTAssertThrowsError(try queue.write { try AppDatabase.migrateRepositoryCodeIdentity($0) })
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT added FROM code_change"), 10)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT marker FROM code_change_legacy_raw"), "keep")
        }
    }

    func testHumanCoauthorIsNotAIToolAttribution() {
        XCTAssertNil(GitMonitor.attributedToolFromTrailer("Co-authored-by: Alice <alice@test>"))
        XCTAssertNil(GitMonitor.attributedToolFromTrailer("Generated-with: Something Unknown"))
    }

    func testLogReadsMoreThanTwentyCommitsAndUsesCapturedHeadAsCursor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try git(["init", "-q"])
        try git(["config", "user.name", "Test"])
        try git(["config", "user.email", "test@local"])
        for index in 0..<25 { try git(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "empty \(index)"]) }
        GitRepo.setup()
        defer { GitRepo.teardown() }
        let repo = GitRepo(path: root.path)
        let batch = try repo.log(since: nil)
        XCTAssertEqual(batch.commits.count, 25)
        XCTAssertEqual(batch.headHash, batch.commits.first?.hash)
        XCTAssertEqual(try repo.log(since: batch.headHash).commits.count, 0)
        try git(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "next"])
        XCTAssertEqual(try repo.log(since: batch.headHash).commits.count, 1)
    }
}
