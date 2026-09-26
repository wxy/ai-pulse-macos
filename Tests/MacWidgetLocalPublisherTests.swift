import XCTest
import AIPulseShared
@testable import AIPulse

final class MacWidgetLocalPublisherTests: XCTestCase {
    func testReusesOnlyHealthyPreviousRanges() {
        let healthy = DashboardSnapshot(todayTokens: 8)
        var degraded = DashboardSnapshot(todayTokens: 0)
        degraded.readFailures = ["dashboard.today.dailyStats"]
        let previous = MacWidgetLocalPayload(
            writtenAt: Date(timeIntervalSince1970: 1_000),
            todaySnapshot: degraded,
            historySnapshot: healthy,
            pulseEnvelope: nil
        )

        XCTAssertNil(MacWidgetLocalPublisher.resolveSnapshots(
            today: nil, history: nil, previous: previous))

        let resolved = MacWidgetLocalPublisher.resolveSnapshots(
            today: healthy, history: nil, previous: previous)
        XCTAssertEqual(resolved?.today.todayTokens, 8)
        XCTAssertEqual(resolved?.history.todayTokens, 8)
    }

    func testRejectsDegradedNewSnapshotEvenWithHealthyPrevious() {
        let healthy = DashboardSnapshot(todayTokens: 8)
        var degraded = DashboardSnapshot(todayTokens: 0)
        degraded.readFailures = ["dashboard.today.dailyStats"]
        let previous = MacWidgetLocalPayload(
            writtenAt: Date(timeIntervalSince1970: 1_000),
            todaySnapshot: healthy,
            historySnapshot: healthy,
            pulseEnvelope: nil
        )

        let resolved = MacWidgetLocalPublisher.resolveSnapshots(
            today: degraded, history: healthy, previous: previous)
        XCTAssertEqual(resolved?.today.todayTokens, 8)
        XCTAssertEqual(resolved?.history.todayTokens, 8)
    }
}
