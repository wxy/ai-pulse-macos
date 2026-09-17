import XCTest
@testable import AIPulse

final class LogScanObservationTests: XCTestCase {
    func testNoScanIsUnknownRatherThanAvailableAndStopDoesNotReuseHistory() {
        let state = LogScanObservation()
        XCTAssertEqual(state.status(hasReadFailure: false), .inactive)
        state.begin()
        XCTAssertEqual(state.status(hasReadFailure: false), .scanning)
        state.finish()
        XCTAssertEqual(state.status(hasReadFailure: false), .available)
        state.stop()
        XCTAssertEqual(state.status(hasReadFailure: false), .inactive)
    }

    func testFailuresOverrideCompletionAndTimeNeverRefreshesTheObservation() {
        let state = LogScanObservation()
        let observed = Date(timeIntervalSince1970: 1000)
        state.begin()
        state.finish(at: observed)
        XCTAssertEqual(state.status(now: observed, hasReadFailure: true), .failed)
        XCTAssertEqual(state.status(now: observed, hasReadFailure: false), .available)
        XCTAssertEqual(state.status(now: observed.addingTimeInterval(121), hasReadFailure: false), .stale)
        XCTAssertEqual(state.status(now: observed.addingTimeInterval(-1), hasReadFailure: false), .stale)
        state.begin()
        XCTAssertEqual(state.status(now: observed, hasReadFailure: true), .failed)
    }
}
