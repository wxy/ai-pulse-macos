import XCTest
@testable import AIPulse

final class AppHealthStatsTests: XCTestCase {
    func testSameNamedRepositoryRecoveryDoesNotClearAnotherGitScanFailure() {
        let monitor = AppHealthMonitor()
        let first = "Git.scan./development/first/app"
        let second = "Git.scan./development/second/app"
        monitor.reportIngestError("partial diff", source: first)
        monitor.reportIngestError("write failed", source: second)
        monitor.clearIngestError(source: first)
        XCTAssertEqual(monitor.failingIngestSources, [second])
        XCTAssertEqual(monitor.current.severity, .impaired)
        monitor.clearIngestError(source: second)
        XCTAssertEqual(monitor.current.severity, .nominal)
    }
    func testSuccessfulQueriesOrOtherBatchesCannotClearUnpersistedEvents() {
        let monitor = AppHealthMonitor()
        monitor.reportIngestError("not saved", source: "log.batch.a")
        monitor.clearStatsError(source: "today.tokens")
        monitor.clearIngestError(source: "log.batch.b")
        XCTAssertEqual(monitor.current.severity, .impaired)
        XCTAssertEqual(monitor.failingIngestSources, ["log.batch.a"])
        monitor.clearIngestError(source: "log.batch.a")
        XCTAssertEqual(monitor.current.severity, .nominal)
        XCTAssertTrue(monitor.current.messages.isEmpty)
    }
    func testOneQueryRecoveryCannotClearAnotherPeriodOrSourceFailure() {
        let monitor = AppHealthMonitor()
        monitor.reportStatsError("failed", source: "today.tokens")
        monitor.reportStatsError("failed", source: "week.code")
        monitor.clearStatsError(source: "month.models")
        XCTAssertTrue(monitor.current.hasStatsError)
        monitor.clearStatsError(source: "today.tokens")
        XCTAssertEqual(monitor.current.severity, .impaired)
        XCTAssertEqual(monitor.current.messages, ["week.code: failed"])
        monitor.clearStatsError(source: "week.code")
        XCTAssertEqual(monitor.current.severity, .nominal)
        XCTAssertTrue(monitor.current.messages.isEmpty)
    }

    func testResetClearsAllQueryKeys() {
        let monitor = AppHealthMonitor()
        monitor.reportStatsError("failed", source: "tokens")
        monitor.reset()
        XCTAssertFalse(monitor.current.hasStatsError)
        XCTAssertEqual(monitor.current.severity, .nominal)
    }
}
