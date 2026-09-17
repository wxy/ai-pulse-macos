import XCTest
import GRDB
@testable import AIPulse

final class SessionRepositoryScopeTests: XCTestCase {
    func testRepeatedPathsResolveOncePerReadButNeverAcrossReads() {
        let rows = (0..<20000).map { index in
            SessionRow(source: "codex", sessionId: "s\(index)", title: nil,
                       repo: index % 2 == 0 ? "/known" : "/unknown",
                       firstTs: 1, lastTs: 2, lastInput: 1, windowTokens: nil, observedTokens: 1)
        }
        var calls: [String: Int] = [:]
        let first = StatsService.authorizedSessionRepositories(rows, roots: []) { path in
            calls[path, default: 0] += 1
            return path == "/known" ? "/authorized/root" : nil
        }
        XCTAssertEqual(calls, ["/known": 1, "/unknown": 1])
        XCTAssertEqual(first.filter { $0.repo != nil }.count, 10000)
        XCTAssertEqual(first.reduce(0) { $0 + $1.observedTokens }, 20000)
        let second = StatsService.authorizedSessionRepositories(rows, roots: []) { path in
            calls[path, default: 0] += 1
            return nil // authorization changed before this read
        }
        XCTAssertEqual(calls, ["/known": 2, "/unknown": 2])
        XCTAssertTrue(second.allSatisfy { $0.repo == nil })
        XCTAssertEqual(second.map(\.id), rows.map(\.id))
    }

    func testSameTimestampRepositoryAndLastInputUseStableObservationOrder() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            for (input, path) in [(10, "/first"), (20, "/second")] {
                let event = UsageEvent(ts: 100, source: "aider", model: "m", inTokens: input,
                    outTokens: 1, cacheTokens: 0, repoPath: path, sessionId: "same", dedupeKey: path)
                _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "deepseek")], nowMs: 200)
            }
            let sessions = try StatsService.sessionRows(in: db, source: "aider", sinceMs: 0, beforeMs: 200)
            XCTAssertEqual(sessions.first?.repo, "/first")
            XCTAssertEqual(sessions.first?.lastInput, 20)
        }
    }

    func testDetailRepositoryAttributionKeepsSessionsButOnlyGroupsAuthorizedGitRoots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aipulse-session-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let development = directory.appendingPathComponent("development")
        let inside = development.appendingPathComponent("app")
        let outside = directory.appendingPathComponent("outside/app")
        let workspace = development.appendingPathComponent("workspace")
        for repo in [inside, outside] {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["init", "--quiet", repo.path]
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0)
        }
        let nested = inside.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let paths: [String?] = [inside.path, nested.path, outside.path, workspace.path, nil]
        let original = paths.enumerated().map { index, path in
            SessionRow(source: "codex", sessionId: "s\(index)", title: nil, repo: path,
                       firstTs: 1, lastTs: 2, lastInput: 10, windowTokens: nil, observedTokens: 10)
        }
        let result = StatsService.authorizedSessionRepositories(original, roots: [development.path])
        let canonical = RepositoryScope.canonicalPath(inside.path)
        XCTAssertEqual(result.map(\.repo), [canonical, canonical, nil, nil, nil])
        XCTAssertEqual(result.map(\.id), original.map(\.id))
        XCTAssertEqual(result.reduce(0) { $0 + $1.observedTokens }, 50)
        XCTAssertEqual(original[1].repo, nested.path, "Read attribution must not rewrite historical paths")
        let groups = SessionStats.groupSessions(result)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first(where: { $0.repo == canonical })?.sessions.count, 2)
        XCTAssertEqual(groups.first(where: { $0.repo == SessionStats.noRepoKey })?.sessions.count, 3)
    }
}
