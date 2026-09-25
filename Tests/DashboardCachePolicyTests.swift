import XCTest
@testable import AIPulse
import AIPulseShared

/// Degraded snapshots (partially failing reads) must never be cached,
/// served from cache, or synced — a transient source failure would
/// otherwise present empty data for the whole cache TTL.
final class DashboardCachePolicyTests: XCTestCase {
    func testHealthySnapshotIsCacheable() {
        var snap = DashboardSnapshot()
        XCTAssertFalse(snap.readFailures.contains("stats"))
        XCTAssertTrue(DashboardCache.isCacheable(snap))
    }

    func testDegradedSnapshotIsNotCacheable() {
        var snap = DashboardSnapshot()
        snap.readFailures = ["dashboard.today.dailyStats"]
        XCTAssertFalse(DashboardCache.isCacheable(snap))
    }
}
