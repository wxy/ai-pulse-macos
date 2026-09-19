import AppKit
import XCTest
@testable import AIPulse
import AIPulseShared

final class DockManagerTests: XCTestCase {
    private func components(
        _ color: NSColor,
        appearance name: NSAppearance.Name = .aqua
    ) throws -> (CGFloat, CGFloat, CGFloat) {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var converted: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            converted = color.usingColorSpace(.sRGB)
        }
        let srgb = try XCTUnwrap(converted)
        return (srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
    }

    private func assertSameColor(
        _ lhs: NSColor,
        _ rhs: NSColor,
        appearance: NSAppearance.Name = .aqua,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let left = try components(lhs, appearance: appearance)
        let right = try components(rhs, appearance: appearance)
        XCTAssertEqual(left.0, right.0, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(left.1, right.1, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(left.2, right.2, accuracy: 0.001, file: file, line: line)
    }

    @MainActor
    func testStartAndStopDoesNotCrash() {
        DockManager.shared.start()
        DockManager.shared.start()
        DockManager.shared.stop()
    }

    func testMenuRobotAndDockLampUseOnePaletteWithoutProgress() throws {
        var lightColors: [(CGFloat, CGFloat, CGFloat)] = []
        for tier in PulseTier.allCases {
            let appearance = PulseAppearance(tier: tier)
            try assertSameColor(StatusItemController.tintColor(for: tier), appearance.color)
            try assertSameColor(
                StatusItemController.tintColor(for: tier),
                appearance.color,
                appearance: .darkAqua
            )
            lightColors.append(try components(appearance.color))
            XCTAssertEqual(appearance.showsLamp(beat: false), tier != .resting)
            try assertSameColor(appearance.feedbackColor(beat: false), appearance.color)
            if tier != .resting {
                try assertSameColor(appearance.feedbackColor(beat: true), appearance.color)
            }
        }
        XCTAssertEqual(Set(lightColors.map { "\($0.0),\($0.1),\($0.2)" }).count, PulseTier.allCases.count)
    }

    func testActivityColorsBecomeBrighterWithinEachHueFamily() throws {
        let resting = try components(PulseAppearance(tier: .resting).color)
        let active = try components(PulseAppearance(tier: .active).color)
        let elevated = try components(PulseAppearance(tier: .elevated).color)
        let intense = try components(PulseAppearance(tier: .intense).color)
        XCTAssertGreaterThan(active.1, resting.1)
        XCTAssertGreaterThan(intense.0, elevated.0)
        XCTAssertGreaterThan(resting.1, resting.0)
        XCTAssertGreaterThan(active.1, active.0)
        XCTAssertGreaterThan(elevated.0, elevated.1)
        XCTAssertGreaterThan(intense.0, intense.1)
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

    func testUnavailableAndRestingKeepRobotAndUseDistinctText() throws {
        let unknown = PulseAppearance(tier: nil)
        let resting = PulseAppearance(tier: .resting)
        let unknownColor = try components(unknown.color)
        let restingColor = try components(resting.color)
        XCTAssertNotEqual(unknownColor.0, restingColor.0)
        XCTAssertNotEqual(unknownColor.1, restingColor.1)
        XCTAssertFalse(unknown.showsLamp(beat: false))
        XCTAssertFalse(resting.showsLamp(beat: false))
        XCTAssertNotEqual(unknown.label, resting.label)
        XCTAssertTrue(unknown.showsLamp(beat: true))
        try assertSameColor(unknown.feedbackColor(beat: true), PulseAppearance(tier: .active).color)
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
