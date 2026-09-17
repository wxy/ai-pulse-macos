import XCTest
import GRDB
@testable import AIPulse

final class StatsServiceTests: XCTestCase {
    func testRepositoryTokenQuerySharesModelPeriodAndSyntheticExclusion() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            for (index, ts) in [99, 100, 199, 200].enumerated() {
                let event = UsageEvent(ts: ts, source: "aider", model: nil,
                                       inTokens: 10, outTokens: 2, cacheTokens: 0,
                                       repoPath: "/dev/project", sessionId: nil,
                                       dedupeKey: "repo-bound-\(index)")
                _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "deepseek")], nowMs: 200)
            }
            try db.execute(sql: """
                INSERT INTO usage_event (ts, source, model, in_tokens, out_tokens, cache_tokens, repo_path, dedupe_key)
                VALUES (150, 'aider', '<synthetic>', 900, 0, 0, '/dev/project', 'synthetic')
                """)
            let repos = try StatsService.repositoryTokenActivity(in: db, sinceMs: 100, beforeMs: 200)
            let models = try StatsService.modelActivity(in: db, sinceMs: 100, beforeMs: 200)
            XCTAssertEqual(repos.count, 1)
            XCTAssertEqual(repos.first?.path, "/dev/project")
            XCTAssertEqual(repos.first?.tokens, 24)
            XCTAssertEqual(repos.reduce(0) { $0 + $1.tokens }, models.reduce(0) { $0 + $1.tokens })
        }
    }

    func testRepositoryActivitiesKeepSameNamesSeparateAndIncludeCodeOnlyRoots() {
        let items = StatsService.repositoryActivities(
            tokensByRoot: ["/a/project": 100, "/b/project": 200],
            changes: [(repoPath: "/a/project", added: 10, deleted: 2, commitHash: "same"),
                      (repoPath: "/c/code-only", added: 20, deleted: 3, commitHash: "same")],
            commits: [(repoPath: "/a/project", commitHash: "same"),
                      (repoPath: "/c/code-only", commitHash: "same")])
        XCTAssertEqual(items.count, 3)
        let byRoot = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        XCTAssertEqual(byRoot["/a/project"]?.tokens, 100)
        XCTAssertEqual(byRoot["/b/project"]?.tokens, 200)
        XCTAssertEqual(byRoot["/a/project"]?.added, 10)
        XCTAssertEqual(byRoot["/b/project"]?.added, 0)
        XCTAssertEqual(byRoot["/c/code-only"]?.tokens, 0)
        XCTAssertEqual(items.reduce(0) { $0 + $1.commits }, 2)
    }

    func testSemanticCurrencyConversionHasProvenanceAndRejectsUnknownCurrency() {
        let cny = StatsService.semanticUSDConversion(currency: "CNY")
        XCTAssertEqual(cny?.rate, 0.14)
        XCTAssertEqual(cny?.source, "internal-static-approximation-v1")
        XCTAssertNil(StatsService.semanticUSDConversion(currency: "UNKNOWN"))
    }


    // MARK: - Methods that work without DB setup



    func testModelBreakdownSanitizesRows() {
        let rows = [
            (model: "deepseek-v4-pro", providerId: "deepseek", toolId: "claude-code", tokens: Int64(860_000), calls: 92),
            (model: "bad", providerId: "deepseek", toolId: "claude-code", tokens: Int64(-1), calls: -2),
        ]

        let items = StatsService.modelBreakdown(rows: rows)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].tokens, 860_000)
        XCTAssertEqual(items[0].calls, 92)
        XCTAssertEqual(items[1].tokens, 0)
        XCTAssertEqual(items[1].calls, 0)
    }



    func testRepositoryVisibilityIncludesUsageOnlyFacts() {
        XCTAssertTrue(DashboardView.shouldShowRepository(totalChanges: 0, tokens: 0, commits: 1))
        XCTAssertTrue(DashboardView.shouldShowRepository(totalChanges: 0, tokens: 1))
        XCTAssertTrue(DashboardView.shouldShowRepository(totalChanges: 12, tokens: 0))
        XCTAssertFalse(DashboardView.shouldShowRepository(totalChanges: 0, tokens: 0))
    }

    func testCommitOnlyRepositoryIsRetainedWithoutInventingCodeChanges() {
        let items = StatsService.repositoryActivities(tokensByRoot: [:], changes: [],
            commits: [(repoPath: "/a/empty", commitHash: "one"),
                      (repoPath: "/a/empty", commitHash: "one")])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.commits, 1)
        XCTAssertEqual(items.first?.totalChanges, 0)
        XCTAssertEqual(items.first?.tokens, 0)
    }

}
