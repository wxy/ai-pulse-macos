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

    func testMenuRobotAndDockLampUseOnePaletteWithoutProgress() {
        XCTAssertEqual(PulseAppearance(tier: .elevated).color, PulseAppearance(tier: .intense).color)
        XCTAssertNotEqual(PulseAppearance(tier: .active).color, PulseAppearance(tier: .intense).color)
        for tier in PulseTier.allCases {
            let appearance = PulseAppearance(tier: tier)
            XCTAssertEqual(StatusItemController.tintColor(for: tier), appearance.color)
            XCTAssertEqual(appearance.showsLamp(beat: false), tier != .resting)
            XCTAssertEqual(appearance.feedbackColor(beat: false), appearance.color)
            if tier != .resting { XCTAssertEqual(appearance.feedbackColor(beat: true), appearance.color) }
        }
    }

    func testHighActivityUsesYellowInsteadOfWarningRed() throws {
        let color = try XCTUnwrap(PulseAppearance(tier: .intense).color.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.greenComponent, 0.5)
        XCTAssertGreaterThan(color.redComponent, color.greenComponent)
        XCTAssertLessThan(color.blueComponent, color.greenComponent)
    }

    @MainActor
    func testDockMenuGroupsActionsAndLeavesQuitToTheSystem() {
        let menu = StatusItemController.shared.makeDockMenu()
        XCTAssertFalse(menu.items.contains { ($0.representedObject as? String) == "quit" })
        XCTAssertFalse(menu.items.last?.isSeparatorItem == true)
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 1)
        XCTAssertTrue(menu.items.allSatisfy { $0.isSeparatorItem || $0.action != nil }, "The context menu contains actions only")
        let labels = menu.items.map(\.title)
        let dashboard = labels.firstIndex(of: I18n.t("menu.dashboard_label") + "…")
        let settings = labels.firstIndex(of: I18n.t("menu.preferences"))
        XCTAssertNotNil(dashboard)
        XCTAssertEqual(settings, dashboard.map { $0 + 1 })
        for item in menu.items where item.action != nil {
            XCTAssertTrue(item.target === StatusItemController.shared)
        }
    }

    func testUnavailableAndRestingKeepRobotAndUseDistinctText() {
        let unknown = PulseAppearance(tier: nil)
        let resting = PulseAppearance(tier: .resting)
        XCTAssertEqual(unknown.color, resting.color)
        XCTAssertFalse(unknown.showsLamp(beat: false))
        XCTAssertFalse(resting.showsLamp(beat: false))
        XCTAssertNotEqual(unknown.label, resting.label)
        XCTAssertTrue(unknown.showsLamp(beat: true))
        XCTAssertEqual(unknown.feedbackColor(beat: true), PulseAppearance(tier: .active).color)
        XCTAssertNil(unknown.tier, "An observation flash must not manufacture token activity")
    }

    @MainActor
    func testDockPreservesBaseArtworkAndHasNoActivityPerimeter() throws {
        let base = try XCTUnwrap(AppIconLoader.load(healthDot: .nominal).tiffRepresentation)
        let resting = AppIconLoader.pulseIcon(appearance: PulseAppearance(tier: .resting), beat: false, healthDot: .nominal)
        let unknown = AppIconLoader.pulseIcon(appearance: PulseAppearance(tier: nil), beat: false, healthDot: .nominal)
        XCTAssertEqual(resting.tiffRepresentation, base)
        XCTAssertEqual(unknown.tiffRepresentation, base)
        let active = AppIconLoader.pulseIcon(appearance: PulseAppearance(tier: .intense), beat: false, healthDot: .nominal)
        let activeData = try XCTUnwrap(active.tiffRepresentation)
        XCTAssertNotEqual(activeData, base)
        let before = try XCTUnwrap(NSBitmapImageRep(data: base))
        let after = try XCTUnwrap(NSBitmapImageRep(data: activeData))
        XCTAssertEqual(before.pixelsWide, after.pixelsWide)
        for (x, y) in [(120, 512), (904, 512), (512, 120), (512, 904)] {
            let px = x * before.pixelsWide / 1024
            let py = y * before.pixelsHigh / 1024
            XCTAssertEqual(before.colorAt(x: px, y: py), after.colorAt(x: px, y: py), "Activity must not repaint the perimeter")
        }
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
