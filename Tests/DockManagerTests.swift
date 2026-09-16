import XCTest
@testable import AIPulse
import AIPulseShared

final class DockManagerTests: XCTestCase {

    func testStartAndStopDoesNotCrash() {
        let manager = DockManager.shared
        manager.start()
        manager.stop()
    }

    func testDockRingUsesPulseScoreInsteadOfMoney() {
        let signal = PulseSignal(
            kind: .activity, rawValue: 50_000, unit: "tokens/h", baseline: 25_000,
            normalized: 2, freshness: .fresh, completeness: .complete,
            observedAt: Date(), reason: "token_rate_2_0x")
        let pulse = PulseSnapshot(tier: .elevated, primarySignal: .activity,
                                  reason: signal.reason, signals: [signal], asOf: Date())
        XCTAssertEqual(DockManager.pulseFillFraction(pulse), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(DockManager.pulseFillFraction(nil), 0)
    }

    func testDockRingKeepsGapAtVeryHighPressure() {
        let signal = PulseSignal(
            kind: .activity, rawValue: 250_000, unit: "tokens/h", baseline: 25_000,
            normalized: 10, freshness: .fresh, completeness: .complete,
            observedAt: Date(), reason: "token_rate_10_0x")
        let pulse = PulseSnapshot(tier: .intense, primarySignal: .activity,
                                  reason: signal.reason, signals: [signal], asOf: Date())
        XCTAssertEqual(DockManager.pulseFillFraction(pulse), 0.92, accuracy: 1e-9)
    }
}
