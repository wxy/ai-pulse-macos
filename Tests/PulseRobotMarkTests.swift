import SwiftUI
import XCTest
import AIPulseShared

final class PulseRobotMarkTests: XCTestCase {
    func testEveryObservedTierHasDistinctLightAndDarkColors() {
        for dark in [false, true] {
            let colors = PulseTier.allCases.compactMap { PulseRobotPalette.rgb(for: $0, dark: dark) }
            XCTAssertEqual(colors.count, PulseTier.allCases.count)
            XCTAssertEqual(Set(colors.map { "\($0.red),\($0.green),\($0.blue)" }).count, colors.count)
        }
        XCTAssertNil(PulseRobotPalette.rgb(for: nil, dark: false))
        XCTAssertNil(PulseRobotPalette.rgb(for: nil, dark: true))
    }

    func testColorsBecomeBrighterWithinGreenAndRedFamilies() throws {
        for dark in [false, true] {
            let resting = try XCTUnwrap(PulseRobotPalette.rgb(for: .resting, dark: dark))
            let active = try XCTUnwrap(PulseRobotPalette.rgb(for: .active, dark: dark))
            let elevated = try XCTUnwrap(PulseRobotPalette.rgb(for: .elevated, dark: dark))
            let intense = try XCTUnwrap(PulseRobotPalette.rgb(for: .intense, dark: dark))
            XCTAssertGreaterThan(active.green, resting.green)
            XCTAssertGreaterThan(intense.red, elevated.red)
        }
    }

    func testMouthShapesKeepTheThreeApprovedGroups() {
        let rect = CGRect(x: 0, y: 0, width: 18, height: 18)
        let unknown = elements(PulseRobotMark(tier: nil).path(in: rect))
        let resting = elements(PulseRobotMark(tier: .resting).path(in: rect))
        let active = elements(PulseRobotMark(tier: .active).path(in: rect))
        let elevated = elements(PulseRobotMark(tier: .elevated).path(in: rect))
        let intense = elements(PulseRobotMark(tier: .intense).path(in: rect))
        XCTAssertEqual(unknown, resting)
        XCTAssertNotEqual(resting, active)
        XCTAssertNotEqual(active, elevated)
        XCTAssertEqual(elevated, intense)
    }

    private func elements(_ path: Path) -> [String] {
        var result: [String] = []
        path.forEach { result.append(String(describing: $0)) }
        return result
    }
}