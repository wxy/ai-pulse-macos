import AppKit
import XCTest
@testable import AIPulse
import AIPulseShared

final class DockManagerTests: XCTestCase {
    @MainActor
    func testStartAndStopDoesNotCrash() {
        DockManager.shared.start()
        DockManager.shared.start()
        DockManager.shared.stop()
    }

    func testBothSurfacesUseDistributedTierSegmentsNotBudgetProgress() {
        for (tier, count) in [(PulseTier.resting, 0), (.active, 4), (.elevated, 8), (.intense, 12)] {
            let appearance = PulseAppearance(tier: tier)
            XCTAssertEqual(appearance.litSegments, count)
            XCTAssertEqual((0..<12).filter { appearance.isLit($0) }.count, count)
            XCTAssertFalse(appearance.isLit(-1))
            XCTAssertFalse(appearance.isLit(12))
            XCTAssertEqual(StatusItemController.tintColor(for: tier), appearance.color)
        }
        XCTAssertTrue(PulseAppearance(tier: .active).isLit(9), "Lit marks span the whole ring")
        XCTAssertFalse(PulseAppearance(tier: .active).isLit(1))
    }

    func testUnavailableIsVisuallyDifferentFromRestingAndNeverGreen() {
        let unknown = PulseAppearance(tier: nil)
        let resting = PulseAppearance(tier: .resting)
        XCTAssertEqual(unknown.litSegments, 0)
        XCTAssertEqual(unknown.color, resting.color)
        XCTAssertNotEqual(unknown.opacity(at: 1), resting.opacity(at: 1))
        XCTAssertEqual(unknown.opacity(at: 0, beat: true), 1)
    }

    @MainActor
    func testSharedBeatGateCoalescesAndExpires() async throws {
        let feedback = PulseFeedbackController(loadSnapshot: { nil })
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(feedback.beat(at: now))
        XCTAssertTrue(feedback.isBeating)
        XCTAssertFalse(feedback.beat(at: now.addingTimeInterval(1)))
        XCTAssertFalse(feedback.beat(at: now.addingTimeInterval(-1)))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(feedback.isBeating)
        XCTAssertTrue(feedback.beat(at: now.addingTimeInterval(2)))
        feedback.stop()
        XCTAssertFalse(feedback.isBeating)
    }

    @MainActor
    func testRefreshAndStartupCannotCreateConsumptionBeat() {
        let feedback = PulseFeedbackController(loadSnapshot: { nil })
        feedback.start()
        NotificationCenter.default.post(name: .dataDidChange, object: nil)
        NotificationCenter.default.post(name: .pulseDidChange, object: nil)
        XCTAssertFalse(feedback.isBeating)
        feedback.stop()
    }
}
