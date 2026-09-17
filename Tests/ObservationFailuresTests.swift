import XCTest
import AIPulseShared
@testable import AIPulse

final class ObservationFailuresTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    func testMenuObservationDistinguishesFailedReadFromSuccessfulEmptyRead() async {
        let failed: [Int]? = await StatsService.observedValue(source: "test.menu.observation") {
            await StatsService.resultOrLog("observedSpend", []) { throw Failure.unavailable }
        }
        XCTAssertNil(failed)
        let empty: [Int]? = await StatsService.observedValue(source: "test.menu.observation") { [] }
        XCTAssertEqual(empty, [])
        XCTAssertNil(StatusItemController.observedSpendLine([]))
        XCTAssertNotNil(StatusItemController.observedSpendLine(nil))
    }

    func testFailuresSurviveSanitizingAndPayloadRoundTrip() throws {
        var snapshot = DashboardSnapshot()
        snapshot.readFailures = ["dashboardUsageStats", "repositoryCode"]
        let data = try JSONEncoder().encode(snapshot.sanitized())
        let decoded = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
        XCTAssertEqual(decoded.readFailures, snapshot.readFailures)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "readFailures")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(DashboardSnapshot.self, from: oldData),
                             "Old derived payloads must rebuild instead of claiming successful reads")
    }

    func testStructuredQueriesRecordFailuresButNotEmptySuccess() async {
        let failures = ObservationFailures()
        await StatsService.$observationFailures.withValue(failures) {
            async let first: [Int] = StatsService.resultOrLog("usage", []) { throw Failure.unavailable }
            async let second: [Int] = StatsService.resultOrLog("code", []) { throw Failure.unavailable }
            async let empty: [Int] = StatsService.resultOrLog("models", []) { [] }
            _ = await (first, second, empty)
        }
        let labels = await failures.snapshot()
        XCTAssertEqual(labels, ["code", "usage"])
    }

    func testConcurrentPeriodFailuresCannotPolluteEachOther() async {
        let today = ObservationFailures()
        let month = ObservationFailures()
        async let first: Int = StatsService.$observationFailures.withValue(today) {
            await StatsService.resultOrLog("today", 0) { throw Failure.unavailable }
        }
        async let second: Int = StatsService.$observationFailures.withValue(month) {
            await StatsService.resultOrLog("month", 0) { throw Failure.unavailable }
        }
        _ = await (first, second)
        let todayLabels = await today.snapshot()
        let monthLabels = await month.snapshot()
        XCTAssertEqual(todayLabels, ["today"])
        XCTAssertEqual(monthLabels, ["month"])
        XCTAssertNil(StatsService.observationFailures)
    }
}
