import XCTest
@testable import AIPulse
import AIPulseShared

final class ClosingBellTests: XCTestCase {
    @MainActor func testCompetingDailyClaimsOnlyOneWinsWithoutPlayingSound() async {
        let domain = "ClosingBellClaims.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 22))!
        let day = calendar.startOfDay(for: now)
        let capturedCalendar = calendar
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask { @MainActor in
                    ClosingBell.claimDailyDelivery(for: day, at: now, calendar: capturedCalendar,
                                                   defaults: UserDefaults(suiteName: domain)!)
                }
            }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        XCTAssertEqual(winners, 1)
    }

    @MainActor func testStaleDayOrChangedClosingSettingsDoNotClaimDelivery() {
        let domain = "ClosingBellBoundaries.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 22))!
        let day = calendar.startOfDay(for: now)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: now)!
        XCTAssertFalse(ClosingBell.claimDailyDelivery(for: day, at: nextDay, calendar: calendar, defaults: defaults))
        defaults.set("23:00", forKey: "closing_bell_time")
        XCTAssertFalse(ClosingBell.claimDailyDelivery(for: day, at: now, calendar: calendar, defaults: defaults))
        defaults.set("21:30", forKey: "closing_bell_time")
        defaults.set(false, forKey: "closing_bell_enabled")
        XCTAssertFalse(ClosingBell.claimDailyDelivery(for: day, at: now, calendar: calendar, defaults: defaults))
        XCTAssertNil(defaults.string(forKey: "closing_bell_last_fired"))
        defaults.set(true, forKey: "closing_bell_enabled")
        XCTAssertTrue(ClosingBell.claimDailyDelivery(for: day, at: now, calendar: calendar, defaults: defaults))
    }

    func testCommitOnlyOutputIsActivityWithoutInventingTokensOrAIAttribution() {
        let summary = ClosingBellSummary(tier: .resting, reason: "no_recent_signal",
                                         activityTokens: nil, observedSpend: [], quotaPercent: nil,
                                         changedLines: 0, commits: 2)
        XCTAssertTrue(summary.hasActivity)
        let text = ClosingBell.body(summary)
        XCTAssertTrue(text.contains("2 \(I18n.t("menu.commits"))"))
        XCTAssertFalse(text.contains(I18n.t("pulse.unit.tokens")))
        XCTAssertFalse(text.contains(I18n.t("pulse.fact.attributed_lines")))
    }

    func testUnknownReadIsNotEncodedAsHealthyZero() throws {
        let summary = ClosingBellSummary(tier: .resting, reason: "no_recent_signal",
                                         activityTokens: nil, observedSpend: [], quotaPercent: nil,
                                         changedLines: nil)
        XCTAssertFalse(summary.hasActivity)
        let decoded = try JSONDecoder().decode(ClosingBellSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertNil(decoded.activityTokens)
        XCTAssertNil(decoded.changedLines)
        XCTAssertNil(decoded.commits)
    }

    func testSummaryKeepsNativeMoneyAndIncludesEveryAvailableFact() {
        let summary = ClosingBellSummary(
            tier: .elevated, reason: "token_rate_2_0x", activityTokens: 12_500,
            observedSpend: [ObservedSpendItem(
                providerId: "deepseek", amount: 8, currency: "CNY",
                convertedUSD: 1.12, observedAt: 100)],
            quotaPercent: 82, changedLines: 41)

        let text = ClosingBell.body(summary)
        XCTAssertTrue(text.contains(I18n.t("pulse.tier.elevated")))
        XCTAssertTrue(text.contains("12.5K \(I18n.t("pulse.unit.tokens"))"))
        XCTAssertTrue(text.contains("2.0"))
        XCTAssertFalse(text.contains("token_rate_2_0x"))
        XCTAssertTrue(text.contains("CNY 8.0 \(I18n.t("pulse.fact.observed"))"))
        XCTAssertTrue(text.contains("\(I18n.t("pulse.fact.quota")) 82%"))
        XCTAssertTrue(text.contains("41 \(I18n.t("pulse.fact.code_changes"))"))
        XCTAssertFalse(text.contains("USD 1.12"))
    }

    func testSummaryDoesNotInventMoneyWhenNoObservedSpendExists() {
        let summary = ClosingBellSummary(
            tier: .active, reason: "recent_token_activity", activityTokens: 10,
            observedSpend: [], quotaPercent: nil, changedLines: 0)
        XCTAssertFalse(ClosingBell.body(summary).contains("$"))
        XCTAssertTrue(summary.hasActivity)
    }

    func testSummaryFactsRoundTripForRelocalization() throws {
        let summary = ClosingBellSummary(
            tier: .active, reason: "recent_token_activity", activityTokens: 42,
            observedSpend: [], quotaPercent: 25, changedLines: 3)

        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(ClosingBellSummary.self, from: data)

        XCTAssertEqual(decoded, summary)
        XCTAssertTrue(ClosingBell.body(decoded).contains(I18n.t("pulse.fact.quota")))
    }

    func testLegacyRenderedSummaryIsHiddenInsteadOfMixingLanguages() {
        let suite = "ClosingBellTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Active · 12.5M tokens", forKey: "closing_bell_last_summary")

        XCTAssertNil(ClosingBell.lastSummary(defaults: defaults))
    }

    func testStoredFactsRenderOnRead() throws {
        let suite = "ClosingBellTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let summary = ClosingBellSummary(
            tier: .elevated, reason: "recent_token_activity", activityTokens: 125,
            observedSpend: [], quotaPercent: nil, changedLines: 0)
        defaults.set(try JSONEncoder().encode(summary), forKey: ClosingBell.lastSummaryDataKey)

        XCTAssertEqual(ClosingBell.lastSummary(defaults: defaults), ClosingBell.body(summary))
    }
}
