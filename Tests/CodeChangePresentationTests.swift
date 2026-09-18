import XCTest
import AIPulseShared
@testable import AIPulse

final class CodeChangePresentationTests: XCTestCase {
    func testHeightRepresentsDeletedAboveAddedNotNetGrowth() {
        let composition = CodeChangeComposition(added: 75, deleted: 25)
        XCTAssertEqual(composition.total, 100)
        XCTAssertEqual(composition.deletedFraction, 0.25)
        XCTAssertEqual(composition.addedFraction, 0.75)
        XCTAssertEqual(CodeChangeComposition(added: 0, deleted: 100).deletedFraction, 1)
        XCTAssertEqual(CodeChangeComposition(added: 100, deleted: 0).addedFraction, 1)
    }

    func testNoChangesHaveNoInventedRatio() {
        let empty = CodeChangeComposition(added: 0, deleted: 0)
        XCTAssertNil(empty.deletedFraction)
        XCTAssertNil(empty.addedFraction)
        XCTAssertEqual(empty.total, 0)
        XCTAssertEqual(CodeChangeComposition(added: -1, deleted: -20), empty)
    }

    func testRepositorySharesCountBothDirectionsIgnoreTokensAndCommits() throws {
        let repos = [
            RepoItem(repoPath: "/dev/a", name: "a", added: 10, deleted: 40, tokens: 900_000, commits: 2),
            RepoItem(repoPath: "/dev/b", name: "b", added: 50, deleted: 0, tokens: 1, commits: 1),
            RepoItem(repoPath: "/dev/c", name: "c", added: 0, deleted: 0, tokens: 500_000, commits: 10),
        ]
        let values = CodeChangeComposition.repositories(repos)
        XCTAssertEqual(try XCTUnwrap(values["/dev/a"]).total, 50)
        XCTAssertEqual(try XCTUnwrap(values["/dev/b"]).total, 50)
        XCTAssertEqual(try XCTUnwrap(values["/dev/c"]).total, 0)
    }

    func testDuplicateCanonicalPathsAggregateButSameNamesStayDistinct() throws {
        let repos = [
            RepoItem(repoPath: "/dev/a", name: "same", added: 2, deleted: 3),
            RepoItem(repoPath: "/dev/a", name: "same", added: 4, deleted: 5),
            RepoItem(repoPath: "/dev/b", name: "same", added: 10, deleted: 0),
        ]
        let values = CodeChangeComposition.repositories(repos)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values["/dev/a"], CodeChangeComposition(added: 6, deleted: 8))
        XCTAssertEqual(try XCTUnwrap(values["/dev/b"]).total, 10)
    }

    func testExtremeCountsRemainFiniteAndLabelsCannotOverflow() throws {
        let result = CodeChangeComposition.sum([
            CodeChangeComposition(added: .max, deleted: .max),
            CodeChangeComposition(added: 100, deleted: 100),
        ])
        XCTAssertEqual(result.added, .max)
        XCTAssertEqual(result.deleted, .max)
        XCTAssertTrue(result.total.isFinite)
        XCTAssertEqual(try XCTUnwrap(result.deletedFraction), 0.5)
    }

    func testMissingAndFailedQueriesNeverBecomeConfirmedZeroChanges() {
        XCTAssertNil(CodeChangeComposition.period(in: nil))
        XCTAssertNil(CodeChangeComposition.repositoryTotals(in: nil))
        var snapshot = DashboardSnapshot()
        XCTAssertEqual(CodeChangeComposition.period(in: snapshot), CodeChangeComposition(added: 0, deleted: 0))
        XCTAssertTrue(CodeChangeComposition.repositoryTotals(in: snapshot)?.isEmpty == true)
        snapshot.readFailures = ["dashboardCodeChanges"]
        XCTAssertNil(CodeChangeComposition.period(in: snapshot))
        XCTAssertNotNil(CodeChangeComposition.repositoryTotals(in: snapshot))
        snapshot.readFailures = ["repositoryCode"]
        XCTAssertNil(CodeChangeComposition.repositoryTotals(in: snapshot))
        XCTAssertNotNil(CodeChangeComposition.period(in: snapshot))
        snapshot.readFailures = ["repoTokens", "repositoryCommits"]
        XCTAssertNotNil(CodeChangeComposition.repositoryTotals(in: snapshot), "Other failed signals cannot erase observed code changes")
    }
}
