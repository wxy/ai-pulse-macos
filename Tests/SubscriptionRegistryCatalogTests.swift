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

    func testAllSupportedSubscriptionToolsResolveIncludingCodexAlias() {
        for id in ["claude-code", "codex", "cursor", "copilot", "windsurf", "opencode"] {
            let name = IntegrationRegistry.toolDisplayName(for: id)
            XCTAssertFalse(SubscriptionRegistry.tool(forName: name)?.tiers.isEmpty ?? true, name)
        }
        XCTAssertEqual(SubscriptionRegistry.tool(forName: "Codex")?.name, "ChatGPT")
        XCTAssertEqual(SubscriptionRegistry.tool(forName: "Codex")?.tiers.first { $0.label == "Pro 5x" }?.fee, 100)
        XCTAssertEqual(SubscriptionRegistry.tool(forName: "Cursor")?.tiers.first { $0.label == "Pro+" }?.fee, 60)
        XCTAssertEqual(SubscriptionRegistry.tool(forName: "GitHub Copilot")?.tiers.first { $0.label == "Max" }?.fee, 100)
    }

    func testExistingDeclaredPlansKeepTheirOriginalAmounts() {
        for (name, label, fee) in [("Codex", "Pro", 200.0), ("Cursor", "Business", 40.0), ("Windsurf", "Pro", 15.0)] {
            let tier = SubscriptionRegistry.tool(forName: name)?.tiers.first { $0.label == label }
            XCTAssertEqual(tier?.fee, fee)
            XCTAssertEqual(tier?.isLegacy, true)
        }
    }

    func testOpenCodeGoDeclarationProducesAFixedCostSource() {
        let old = IntegrationRegistry.config(for: "opencode")
        defer { IntegrationRegistry.setConfig(for: "opencode", old) }
        var selected = old
        selected.subscriptionTier = "Go"
        IntegrationRegistry.setConfig(for: "opencode", selected)
        let sources = OpenCodeIntegration().costSources
        XCTAssertEqual(sources.count, 1)
        if case let .subscription(toolId, tierLabel, monthlyFee) = sources.first?.kind {
            XCTAssertEqual(toolId, "opencode")
            XCTAssertEqual(tierLabel, "Go")
            XCTAssertEqual(monthlyFee, 10)
        } else { XCTFail("Declared Go must reach the fixed-cost data source") }
    }

    func testParseHMMatchesSettingsParser() {
        // SoundSettings.parseHM is the canonical "HH:mm" parser; the closing
        // bell (WI-7) reuses it for closing_bell_time.
        XCTAssertEqual(SoundSettings.parseHM("21:30"), 21 * 60 + 30)
    }
}
