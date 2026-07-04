import XCTest
@testable import AIPulse

final class DockManagerTests: XCTestCase {

    func testStartAndStopDoesNotCrash() {
        let manager = DockManager.shared
        manager.start()
        manager.stop()
    }
}
