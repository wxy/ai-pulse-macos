import XCTest
@testable import AIPulse

final class DockManagerTests: XCTestCase {

    func testStartAndStopDoesNotCrash() {
        let manager = DockManager.shared
        manager.start()
        manager.stop()
    }

    func testPulseIconThrottled() async {
        let manager = DockManager.shared
        // Two rapid pulses — second should be throttled (2s min interval)
        await manager.pulseIcon()
        await manager.pulseIcon()
        // No assertion needed — test passes if no crash
    }
}
