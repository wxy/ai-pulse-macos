import XCTest
import AIPulseShared
@testable import AIPulse

final class PulseObservationHealthTests: XCTestCase {
    private enum Failure: Error { case unavailable }
    private actor Source {
        var fails = false
        func setFailure(_ value: Bool) { fails = value }
        func read(now: Date) throws -> PulseSnapshot {
            if fails { throw Failure.unavailable }
            return PulseSnapshot(tier: .active, primarySignal: .activity, reason: "test", signals: [], asOf: now)
        }
    }

    func testFailedReadKeepsOnlyUnexpiredObservationAndReportsIndependentHealth() async {
        let health = AppHealthMonitor()
        let source = Source()
        let engine = PulseEngine(healthMonitor: health) { try await source.read(now: $0) }
        let now = Date(timeIntervalSince1970: 1000)
        let initial = await engine.snapshot(now: now)
        XCTAssertEqual(initial?.asOf, now)
        await source.setFailure(true)
        let fallback = await engine.snapshot(now: now.addingTimeInterval(16))
        XCTAssertEqual(fallback?.asOf, now, "Failure must not refresh the cached observation timestamp")
        XCTAssertTrue(health.current.hasStatsError)
        let expired = await engine.snapshot(now: now.addingTimeInterval(61))
        XCTAssertNil(expired, "An expired failed read is unknown, not a fabricated resting pulse")
        health.reportStatsError("other query", source: "dashboard.week.tokens")
        await source.setFailure(false)
        let recovered = await engine.snapshot(now: now.addingTimeInterval(62))
        XCTAssertEqual(recovered?.asOf, now.addingTimeInterval(62))
        XCTAssertEqual(health.current.messages, ["dashboard.week.tokens: other query"])
    }

    func testSwallowedComponentFailureCannotBecomeSuccessfulRestingPulse() async {
        let health = AppHealthMonitor()
        let engine = PulseEngine(healthMonitor: health) { now in
            await StatsService.observationFailures?.record("quotaStatus")
            return PulseSnapshot(tier: .resting, primarySignal: nil, reason: "test", signals: [], asOf: now)
        }
        let result = await engine.snapshot(now: Date(timeIntervalSince1970: 1000))
        XCTAssertNil(result)
        XCTAssertTrue(health.current.hasStatsError)
    }
}
