import XCTest
import AIPulseShared

final class ActivityCoverageTests: XCTestCase {
    func testUnknownIsNotHealthyZeroAndInvalidCountersStayUnknown() {
        XCTAssertNil(ActivityCoverage().isPartial)
        XCTAssertEqual(ActivityCoverage(observedEvents: 0, incompleteEvents: 0).isPartial, false)
        XCTAssertEqual(ActivityCoverage(observedEvents: 10, incompleteEvents: 2).isPartial, true)
        XCTAssertNil(ActivityCoverage(observedEvents: 1, incompleteEvents: 2).isPartial)
        XCTAssertNil(ActivityCoverage(observedEvents: -1, incompleteEvents: 0).isPartial)
    }

    func testCoverageRoundTripsAndOldDerivedSnapshotWithoutCoverageIsRejected() throws {
        var snapshot = DashboardSnapshot()
        snapshot.activityCoverage = ActivityCoverage(observedEvents: 10, incompleteEvents: 2)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(DashboardSnapshot.self, from: data).activityCoverage, snapshot.activityCoverage)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "activityCoverage")
        XCTAssertThrowsError(try JSONDecoder().decode(DashboardSnapshot.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
