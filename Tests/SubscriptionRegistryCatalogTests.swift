import XCTest
@testable import AIPulse

/// WI-8 零配置: the public plan-price catalog lives in `SubscriptionRegistry`
/// (in-code, like the original pricing catalog). Zero-config prefill picks the
/// FIRST tier of an installed tool — these tests pin the catalog's integrity.
final class SubscriptionRegistryCatalogTests: XCTestCase {

    func testEveryToolHasAtLeastOnePositiveTier() {
        XCTAssertFalse(SubscriptionRegistry.tools.isEmpty)
        for tool in SubscriptionRegistry.tools {
            XCTAssertFalse(tool.tiers.isEmpty, "\(tool.name) needs a default tier for zero-config prefill")
            for tier in tool.tiers {
                XCTAssertGreaterThan(tier.fee, 0, "\(tool.name)/\(tier.label) fee must be positive")
                XCTAssertEqual(tier.currency, "USD")
            }
        }
    }

    func testKeyToolsResolveByBundleId() {
        XCTAssertNotNil(SubscriptionRegistry.tool(forBundleId: "com.todesktop.230313mzl4w4u92"),
                        "Cursor must resolve (EditorDetector + prefill both use bundle ids)")
        XCTAssertNotNil(SubscriptionRegistry.tool(forName: "Claude Code"))
    }

    func testStandardPrefillPlanIsTheFirstTier() {
        // prefillSubscriptionTiers() picks tiers.first — pin the expected
        // standard plans so catalog reordering is a conscious change.
        XCTAssertEqual(SubscriptionRegistry.tool(forName: "Cursor")?.tiers.first?.label, "Pro")
        XCTAssertEqual(SubscriptionRegistry.tool(forName: "Cursor")?.tiers.first?.fee, 20)
        XCTAssertEqual(SubscriptionRegistry.tool(forName: "Claude Code")?.tiers.first?.label, "Pro")
        XCTAssertEqual(SubscriptionRegistry.tool(forName: "Claude Code")?.tiers.first?.fee, 20)
    }

    func testParseHMMatchesSettingsParser() {
        // SoundSettings.parseHM is the canonical "HH:mm" parser; the closing
        // bell (WI-7) reuses it for closing_bell_time.
        XCTAssertEqual(SoundSettings.parseHM("21:30"), 21 * 60 + 30)
    }
}
