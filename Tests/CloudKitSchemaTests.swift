import XCTest
import AIPulseShared

final class CloudKitSchemaTests: XCTestCase {
    func testDashboardContractUsesTheTwoPointZeroSeries() throws {
        XCTAssertEqual(CKSchema.recordType, "DashboardCache_v2")
        XCTAssertEqual(CKSchema.payloadVersion, "2.0.0")
        XCTAssertNotEqual(CKSchema.Subscription.dashboardChanges, "dashboard-changes")
        XCTAssertEqual(CKSchema.SpendAlert.recordType, "SpendAlert_v1")
    }

    func testDashboardSnapshotEmitsTheTwoPointZeroEnvelope() throws {
        var snapshot = DashboardSnapshot()
        snapshot.payloadVersion = CKSchema.payloadVersion
        snapshot.writerAppVersion = "2.0.0"

        let decoded = try JSONDecoder().decode(
            DashboardSnapshot.self,
            from: Data(snapshot.jsonString().utf8))

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.payloadVersion, "2.0.0")
        XCTAssertEqual(decoded.writerAppVersion, "2.0.0")
    }
}
