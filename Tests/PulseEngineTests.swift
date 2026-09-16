import XCTest
@testable import AIPulse
import AIPulseShared

final class PulseEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_300_800) // exact hour

    private func signal(
        _ kind: PulseSignalKind,
        score: Double,
        reason: String,
        freshness: PulseFreshness = .fresh
    ) -> PulseSignal {
        PulseSignal(kind: kind, rawValue: 1, unit: "test", baseline: 1,
                    normalized: score, freshness: freshness,
                    completeness: .complete, observedAt: now, reason: reason)
    }

    func testTierThresholds() {
        XCTAssertEqual(PulseEngine.tier(score: 0), .resting)
        XCTAssertEqual(PulseEngine.tier(score: 0.149), .resting)
        XCTAssertEqual(PulseEngine.tier(score: 0.15), .active)
        XCTAssertEqual(PulseEngine.tier(score: 1.49), .active)
        XCTAssertEqual(PulseEngine.tier(score: 1.5), .elevated)
        XCTAssertEqual(PulseEngine.tier(score: 2.99), .elevated)
        XCTAssertEqual(PulseEngine.tier(score: 3), .intense)
        XCTAssertEqual(PulseEngine.tier(score: .nan), .resting)
    }

    func testSignalsAreComparedInsteadOfSummed() {
        let snapshot = PulseEngine.buildSnapshot(signals: [
            signal(.activity, score: 1.4, reason: "tokens"),
            signal(.observedSpend, score: 1.4, reason: "money")
        ], now: now)

        XCTAssertEqual(snapshot.tier, .active,
                       "two unlike 1.4 signals must not add into an elevated 2.8")
        XCTAssertTrue([PulseSignalKind.activity, .observedSpend]
            .contains(snapshot.primarySignal))
    }

    func testStrongestFreshSignalOwnsTierAndReason() {
        let snapshot = PulseEngine.buildSnapshot(signals: [
            signal(.activity, score: 1.2, reason: "token_rate_1_2x"),
            signal(.quota, score: 3.5, reason: "quota_97_percent"),
            signal(.observedSpend, score: 8, reason: "stale_money", freshness: .stale)
        ], now: now)

        XCTAssertEqual(snapshot.tier, .intense)
        XCTAssertEqual(snapshot.primarySignal, .quota)
        XCTAssertEqual(snapshot.reason, "quota_97_percent")
    }

    func testTokenOnlySpikeCanBecomeIntenseWithoutPricing() {
        let samples = [
            PulseSample(timestamp: now.addingTimeInterval(-7_200), value: 1_000),
            PulseSample(timestamp: now, value: 4_000)
        ]
        let activity = PulseEngine.rateSignal(
            kind: .activity, samples: samples, unit: "tokens/h",
            completeness: .complete, now: now,
            ratioReason: "token_rate", fallbackReason: "recent_token_activity")
        let snapshot = PulseEngine.buildSnapshot(signals: [activity], now: now)

        XCTAssertEqual(activity.baseline, 1_000)
        XCTAssertEqual(snapshot.tier, .intense)
        XCTAssertEqual(snapshot.primarySignal, .activity)
        XCTAssertTrue(snapshot.reason.hasPrefix("token_rate_"))
    }

    func testColdStartTokenSpikeCanBecomeIntenseWithoutHistory() {
        let activity = PulseEngine.rateSignal(
            kind: .activity,
            samples: [PulseSample(timestamp: now, value: 12_000)],
            unit: "tokens/h", completeness: .complete, now: now,
            ratioReason: "token_rate", fallbackReason: "recent_token_activity")

        XCTAssertNil(activity.baseline)
        XCTAssertEqual(PulseEngine.buildSnapshot(signals: [activity], now: now).tier, .intense)
        XCTAssertEqual(activity.reason, "token_rate_cold_start_3_6x")
    }

    func testRecentActivityNaturallyDecaysToRestingWithoutNewRows() {
        let sample = PulseSample(timestamp: now, value: 1_000)
        let fresh = PulseEngine.rateSignal(
            kind: .activity, samples: [sample], unit: "tokens/h",
            completeness: .complete, now: now,
            ratioReason: "token_rate", fallbackReason: "recent_token_activity")
        let later = now.addingTimeInterval(30 * 60)
        let decayed = PulseEngine.rateSignal(
            kind: .activity, samples: [sample], unit: "tokens/h",
            completeness: .complete, now: later,
            ratioReason: "token_rate", fallbackReason: "recent_token_activity")

        XCTAssertEqual(PulseEngine.buildSnapshot(signals: [fresh], now: now).tier, .active)
        XCTAssertEqual(PulseEngine.buildSnapshot(signals: [decayed], now: later).tier, .resting)
        XCTAssertLessThan(decayed.normalized, fresh.normalized)
    }

    func testQuotaPressureUsesFreshProviderWindowAndExpires() {
        let item = QuotaStatusItem(
            toolId: "claude-code", windowId: "5h", utilization: 96,
            limitStatus: "allowed", resetAt: now.timeIntervalSince1970 + 1_000,
            windowSeconds: 18_000, updatedAt: now.timeIntervalSince1970)

        let fresh = PulseEngine.quotaSignal(items: [item], now: now)
        let stale = PulseEngine.quotaSignal(
            items: [item], now: now.addingTimeInterval(PulseEngine.quotaMaxAge + 1))

        XCTAssertEqual(fresh.normalized, 3.5)
        XCTAssertEqual(fresh.reason, "quota_96_percent")
        XCTAssertEqual(stale.normalized, 0)
        XCTAssertEqual(stale.freshness, .stale)
    }

}
