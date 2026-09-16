import XCTest
@testable import AIPulse
import AIPulseShared

final class ClosingBellTests: XCTestCase {
    func testSummaryKeepsNativeMoneyAndIncludesEveryAvailableFact() {
        let summary = ClosingBellSummary(
            tier: .elevated, reason: "token_rate_2_0x", activityTokens: 12_500,
            observedSpend: [ObservedSpendItem(
                providerId: "deepseek", amount: 8, currency: "CNY",
                convertedUSD: 1.12, observedAt: 100)],
            quotaPercent: 82, attributedLines: 41)

        let text = ClosingBell.body(summary)
        XCTAssertTrue(text.contains(I18n.t("pulse.tier.elevated")))
        XCTAssertTrue(text.contains("12.5K \(I18n.t("pulse.unit.tokens"))"))
        XCTAssertTrue(text.contains("2.0"))
        XCTAssertFalse(text.contains("token_rate_2_0x"))
        XCTAssertTrue(text.contains("CNY 8.00 \(I18n.t("pulse.fact.observed"))"))
        XCTAssertTrue(text.contains("\(I18n.t("pulse.fact.quota")) 82%"))
        XCTAssertTrue(text.contains("41 \(I18n.t("pulse.fact.attributed_lines"))"))
        XCTAssertFalse(text.contains("USD 1.12"))
    }

    func testSummaryDoesNotInventMoneyWhenNoObservedSpendExists() {
        let summary = ClosingBellSummary(
            tier: .active, reason: "recent_token_activity", activityTokens: 10,
            observedSpend: [], quotaPercent: nil, attributedLines: 0)
        XCTAssertFalse(ClosingBell.body(summary).contains("$"))
        XCTAssertTrue(summary.hasActivity)
    }

    func testSummaryFactsRoundTripForRelocalization() throws {
        let summary = ClosingBellSummary(
            tier: .active, reason: "recent_token_activity", activityTokens: 42,
            observedSpend: [], quotaPercent: 25, attributedLines: 3)

        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(ClosingBellSummary.self, from: data)

        XCTAssertEqual(decoded, summary)
        XCTAssertTrue(ClosingBell.body(decoded).contains(I18n.t("pulse.fact.quota")))
    }

    func testLegacyRenderedSummaryIsHiddenInsteadOfMixingLanguages() {
        let suite = "ClosingBellTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Active · 12.5M tokens", forKey: ClosingBell.lastSummaryKey)

        XCTAssertNil(ClosingBell.lastSummary(defaults: defaults))
    }

    func testStoredFactsRenderOnRead() throws {
        let suite = "ClosingBellTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let summary = ClosingBellSummary(
            tier: .elevated, reason: "recent_token_activity", activityTokens: 125,
            observedSpend: [], quotaPercent: nil, attributedLines: 0)
        defaults.set(try JSONEncoder().encode(summary), forKey: ClosingBell.lastSummaryDataKey)

        XCTAssertEqual(ClosingBell.lastSummary(defaults: defaults), ClosingBell.body(summary))
    }
}
