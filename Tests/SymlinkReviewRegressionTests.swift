import Foundation
import GRDB
import XCTest
@testable import AIPulse

final class SymlinkReviewRegressionTests: XCTestCase {
    private func directory(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func gitInit(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--quiet", url.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testExternalRepositoryStatisticsDiscoverOncePerReadAndRevoke() throws {
        let base = try directory(FileManager.default.temporaryDirectory, "pr93-stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let develop = try directory(base, "develop")
        let repo = try directory(base, "external/repo")
        let outside = try directory(base, "external/unselected")
        try gitInit(repo)
        try gitInit(outside)
        let alias = develop.appendingPathComponent("repo")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo)
        for index in 0..<80 { _ = try directory(develop, "noise-\(index)") }
        let count = 500
        let paths = try (0..<count).map { try directory(repo, "Sources/work-\($0)").path }
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            for (index, path) in (paths + [outside.path]).enumerated() {
                let event = UsageEvent(ts: 100, source: "codex", model: "gpt-5-codex",
                    inTokens: 10, outTokens: 5, cacheTokens: 0, repoPath: path,
                    sessionId: "s\(index)", dedupeKey: "stats-\(index)", reportedOutputTokens: 5)
                _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "openai")], nowMs: 200)
                try db.execute(sql: """
                    INSERT INTO code_change (repo_path, commit_hash, ts, added, deleted, is_merge)
                    VALUES (?, ?, 100, 2, 1, 0)
                    """, arguments: [path, "c\(index)"])
                try db.execute(sql: """
                    INSERT INTO git_commit (repo_path, commit_hash, ts, parent_count, author_email)
                    VALUES (?, ?, 100, 1, 'qa@example.invalid')
                    """, arguments: [path, "c\(index)"])
            }
        }
        let canonical = RepositoryScope.canonicalPath(repo.path)
        let started = Date()
        try queue.read { db in
            let rows = try StatsService.repositoryTokenActivity(in: db, sinceMs: 0, beforeMs: 200)
            var authorization = RepositoryScope.AuthorizedRootLookup(roots: [develop.path])
            let tokens = StatsService.authorizedRepositoryTokens(rows, using: &authorization)
            XCTAssertEqual(tokens, [canonical: Int64(count * 15)])
            XCTAssertEqual(authorization.linkedRootScanCount, 1)
            var detailAuthorization = RepositoryScope.AuthorizedRootLookup(roots: [develop.path])
            let summary = try StatsService.toolActivitySummary(in: db, source: "codex", sinceMs: 0,
                beforeMs: 200, sessionCount: count, using: &detailAuthorization)
            XCTAssertEqual(summary.sessionCount, count)
            XCTAssertEqual(summary.commitCount, count)
            XCTAssertEqual(summary.addedLines, count * 2)
            XCTAssertEqual(summary.deletedLines, count)
            XCTAssertEqual(detailAuthorization.linkedRootScanCount, 1,
                           "Usage, code and commits share one reachable-root discovery")
            var direct = RepositoryScope.AuthorizedRootLookup(roots: [repo.path])
            XCTAssertEqual(StatsService.authorizedRepositoryTokens(rows, using: &direct), tokens)
            XCTAssertEqual(direct.linkedRootScanCount, 1,
                           "Only the unselected external sibling needs the fallback")
            var insideOnly = RepositoryScope.AuthorizedRootLookup(roots: [repo.path])
            let insideRows = rows.filter { $0.path != outside.path }
            XCTAssertEqual(StatsService.authorizedRepositoryTokens(insideRows, using: &insideOnly), tokens)
            XCTAssertEqual(insideOnly.linkedRootScanCount, 0)
        }
        print("PR93_LINKED_STATS rows=\(count) elapsed_s=\(Date().timeIntervalSince(started))")
        try FileManager.default.removeItem(at: alias)
        try queue.read { db in
            var afterRemoval = RepositoryScope.AuthorizedRootLookup(roots: [develop.path])
            let rows = try StatsService.repositoryTokenActivity(in: db, sinceMs: 0, beforeMs: 200)
            XCTAssertTrue(StatsService.authorizedRepositoryTokens(rows, using: &afterRemoval).isEmpty)
            var detailAfterRemoval = RepositoryScope.AuthorizedRootLookup(roots: [develop.path])
            let summary = try StatsService.toolActivitySummary(in: db, source: "codex", sinceMs: 0,
                beforeMs: 200, sessionCount: count, using: &detailAfterRemoval)
            XCTAssertEqual(summary.commitCount, 0)
            XCTAssertEqual(summary.addedLines, 0)
            XCTAssertEqual(summary.deletedLines, 0)
            XCTAssertEqual(detailAfterRemoval.linkedRootScanCount, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_event"), count + 1)
        }
    }

    func testClaudeAliasBackfillUsesContentIdentityAndLogicalFallback() throws {
        let base = try directory(FileManager.default.temporaryDirectory, "pr93-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = try directory(base, "home")
        let projects = try directory(home, ".claude/projects/project")
        let target = base.appendingPathComponent("physical-journal.txt")
        let user = #"{"timestamp":"2026-10-22T00:00:00Z","type":"user","message":{"role":"user","content":[{"type":"text","text":"Keep the session title"}]}}"#
        let assistant = #"{"timestamp":"2026-10-22T00:00:01Z","sessionId":"actual-session","message":{"id":"m1","role":"assistant","usage":{"input_tokens":10,"output_tokens":2}}}"#
        try (user + "\n" + assistant + "\n").write(to: target, atomically: true, encoding: .utf8)
        for name in ["logical-session.jsonl", "second-alias.jsonl"] {
            try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent(name), withDestinationURL: target)
        }
        let oldTarget = base.appendingPathComponent("legacy-data.bin")
        try (user + "\n").write(to: oldTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent("legacy-session.jsonl"), withDestinationURL: oldTarget)
        var records: [SessionInfoRecord] = []
        SessionInfoBackfill.backfillClaude(home: home) { records.append($0) }
        XCTAssertEqual(Set(records.compactMap(\.sessionId)), ["actual-session", "legacy-session"])
        XCTAssertEqual(records.count, 2)
        let event = try XCTUnwrap(ClaudeCodeParser.parse(line: assistant))
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "anthropic")], nowMs: 1_800_000_000_000)
            for record in records {
                try db.execute(sql: """
                    INSERT INTO session_info (source, session_id, title, repo, first_ts, last_ts)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [record.source, record.sessionId, record.title, record.repo, record.firstTs, record.lastTs])
            }
            let rows = try StatsService.sessionRows(in: db, source: "claude-code", sinceMs: 0, beforeMs: Int64.max)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.sessionId, "actual-session")
            XCTAssertEqual(rows.first?.title, "Keep the session title")
        }
    }

    func testExpiredDeadlineIsReportedForDuplicateFileAndDirectoryAliases() throws {
        let base = try directory(FileManager.default.temporaryDirectory, "pr93-deadline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let targetDirectory = try directory(base, "target")
        let targetFile = base.appendingPathComponent("target.txt")
        try Data().write(to: targetFile)
        for target in [targetDirectory, targetFile] {
            let aliases = try directory(base, UUID().uuidString)
            for index in 0..<256 {
                try FileManager.default.createSymbolicLink(at: aliases.appendingPathComponent("alias-\(index)"), withDestinationURL: target)
            }
            var found: [URL] = []
            XCTAssertTrue(GitRepoScanner.enumerate(in: aliases, deadline: .distantPast) { found.append($0) })
            XCTAssertTrue(found.isEmpty)
        }
    }

    func testDeadlineExpiresInsideDuplicateDiscardLoop() throws {
        let base = try directory(FileManager.default.temporaryDirectory, "pr93-budget-loop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("file.txt")
        try Data().write(to: file)
        let aliases = try directory(base, "aliases")
        for index in 0..<256 {
            try FileManager.default.createSymbolicLink(at: aliases.appendingPathComponent("alias-\(index)"), withDestinationURL: file)
        }
        var checks = 0
        let walker = try XCTUnwrap(SymlinkFileTree.enumerator(at: aliases, includingPropertiesForKeys: nil,
            deadline: Date(timeIntervalSince1970: 1), now: {
                checks += 1
                return Date(timeIntervalSince1970: checks < 8 ? 0 : 2)
            }))
        XCTAssertNotNil(walker.nextObject())
        XCTAssertNil(walker.nextObject())
        XCTAssertTrue(walker.truncated)
        XCTAssertEqual(checks, 8, "Discarded aliases also consume the scan budget")
        let complete = try XCTUnwrap(SymlinkFileTree.enumerator(at: aliases, includingPropertiesForKeys: nil))
        XCTAssertEqual(complete.allObjects.count, 1)
        XCTAssertFalse(complete.truncated)
    }
}
