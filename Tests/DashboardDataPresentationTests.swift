import XCTest
import AIPulseShared
@testable import AIPulse

final class DashboardDataPresentationTests: XCTestCase {
    func testRepositoryTotalsIncludeFoldedRows() {
        let repos = (1...8).map {
            RepoItem(repoPath: "/dev/\($0)", name: "repo-\($0)", added: $0 * 1000, deleted: $0 * 500, tokens: Int64($0 * 100), commits: $0)
        }
        let totals = RepositoryTableTotals(repositories: repos)
        XCTAssertEqual(totals.added, 36_000)
        XCTAssertEqual(totals.deleted, 18_000)
        XCTAssertEqual(totals.tokens, 3_600)
        XCTAssertEqual(totals.commits, 36)
        XCTAssertNotEqual(totals.added, RepositoryTableTotals(repositories: Array(repos.prefix(5))).added)
    }

    func testUnknownRepositoryTokensAreNotReportedAsKnownZero() {
        let totals = RepositoryTableTotals(repositories: [
            RepoItem(repoPath: "/a", name: "a", added: 1, deleted: 2, tokens: 10, commits: 1),
            RepoItem(repoPath: "/b", name: "b", added: 3, deleted: 4, tokens: nil, commits: 2)
        ])
        XCTAssertNil(totals.tokens)
        XCTAssertEqual(totals.added, 4)
        XCTAssertEqual(totals.deleted, 6)
        XCTAssertEqual(totals.commits, 3)
    }

    func testRepositoryTotalsSaturateWithoutOverflow() {
        let huge = RepoItem(repoPath: "/a", name: "a", added: Int.max, deleted: Int.max, tokens: Int64.max, commits: Int.max)
        let totals = RepositoryTableTotals(repositories: [huge, huge])
        XCTAssertEqual(totals.added, Int64.max)
        XCTAssertEqual(totals.deleted, Int64.max)
        XCTAssertEqual(totals.commits, Int64.max)
        XCTAssertEqual(totals.tokens, Int64.max)
    }

    func testWeekHasFourteenContextSlotsAndSevenUnchangedDailyValues() {
        let values: [Double] = [0, 10, 20, 30, 40, 50, 60]
        let slots = DashboardDataPresentation.rhythmSlots(values: values, count: 7, surroundingWeeks: true)
        XCTAssertEqual(slots.count, 21)
        XCTAssertTrue(slots.prefix(7).allSatisfy { $0 == nil })
        XCTAssertEqual(slots[7..<14].compactMap { $0 }, values)
        XCTAssertTrue(slots.suffix(7).allSatisfy { $0 == nil })
        XCTAssertEqual(slots.compactMap { $0 }.reduce(0, +), values.reduce(0, +))
    }

    func testOtherPeriodsKeepTheirOriginalSlotCountAndEmptyDaysAreNotContext() {
        for count in [24, 30] {
            let slots = DashboardDataPresentation.rhythmSlots(values: [3], count: count, surroundingWeeks: false)
            XCTAssertEqual(slots.count, count)
            XCTAssertEqual(slots.first!, 3)
            XCTAssertEqual(slots.last!, 0)
            XCTAssertFalse(slots.contains { $0 == nil })
        }
    }

    func testInvalidValuesCannotProduceInvalidGeometryAndExcessValuesAreExcluded() {
        let slots = DashboardDataPresentation.rhythmSlots(values: [.nan, .infinity, -2, 9], count: 3, surroundingWeeks: false)
        XCTAssertEqual(slots, [0, 0, 0])
        XCTAssertTrue(DashboardDataPresentation.rhythmSlots(values: [], count: -1, surroundingWeeks: false).isEmpty)
    }

    func testDataBarsUseExactLinearProportionsIncludingZero() {
        XCTAssertEqual(DashboardDataPresentation.barFraction(value: 100, maximum: 100), 1)
        XCTAssertEqual(DashboardDataPresentation.barFraction(value: 50, maximum: 100), 0.5)
        XCTAssertEqual(DashboardDataPresentation.barFraction(value: 30, maximum: 100), 0.3)
        XCTAssertEqual(DashboardDataPresentation.barFraction(value: 0, maximum: 100), 0)
        XCTAssertEqual(DashboardDataPresentation.barFraction(value: 200, maximum: 100), 1)
    }

    func testUnavailableAndInvalidBarsAreNotDrawn() {
        XCTAssertNil(DashboardDataPresentation.barFraction(value: nil, maximum: 100))
        XCTAssertNil(DashboardDataPresentation.barFraction(value: .nan, maximum: 100))
        XCTAssertNil(DashboardDataPresentation.barFraction(value: -1, maximum: 100))
        XCTAssertNil(DashboardDataPresentation.barFraction(value: 0, maximum: 0))
        XCTAssertNil(DashboardDataPresentation.barFraction(value: 1, maximum: .infinity))
        XCTAssertEqual(DashboardDataPresentation.barFraction(value: Double(Int64.max), maximum: Double(Int64.max)), 1)
    }
}
