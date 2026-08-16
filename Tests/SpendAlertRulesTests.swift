import XCTest
import AIPulseShared

final class SpendAlertRulesTests: XCTestCase {
    private let thresholds = SpendAlertThresholds.standard

    func testMedianForOddCount() {
        XCTAssertEqual(SpendAlertRules.median([1, 3, 2]), 2, accuracy: 0.0001)
    }

    func testMedianForEvenCount() {
        XCTAssertEqual(SpendAlertRules.median([1, 2, 3, 4]), 2.5, accuracy: 0.0001)
    }

    func testMedianForEmptyInputIsZero() {
        XCTAssertEqual(SpendAlertRules.median([]), 0, accuracy: 0.0001)
    }

    func testSpendRateRejectsSmallAbsoluteJumpEvenAtHighMultiplier() {
        // $0.50 is 5× a $0.10 baseline but below the $1 floor.
        XCTAssertNil(SpendAlertRules.levelForSpendRate(
            current: 0.50, baseline: 0.10, thresholds: thresholds))
    }

    func testSpendRateReturnsReminderAtDoubleBaseline() {
        XCTAssertEqual(SpendAlertRules.levelForSpendRate(
            current: 2, baseline: 0.5, thresholds: thresholds), .reminder)
    }

    func testSpendRateReturnsWarningAtFiveTimesBaseline() {
        XCTAssertEqual(SpendAlertRules.levelForSpendRate(
            current: 5, baseline: 1, thresholds: thresholds), .warning)
    }

    func testSpendRateReturnsCriticalAtTenTimesBaseline() {
        XCTAssertEqual(SpendAlertRules.levelForSpendRate(
            current: 10, baseline: 1, thresholds: thresholds), .critical)
    }

    func testSpendRatePicksHighestLevelWhenMultipleApply() {
        XCTAssertEqual(SpendAlertRules.levelForSpendRate(
            current: 20, baseline: 1, thresholds: thresholds), .critical)
    }

    func testBalanceDropMapsToLevels() {
        XCTAssertNil(SpendAlertRules.levelForBalanceDrop(dropUSD: 10, thresholds: thresholds))
        XCTAssertEqual(SpendAlertRules.levelForBalanceDrop(dropUSD: 30, thresholds: thresholds), .reminder)
        XCTAssertEqual(SpendAlertRules.levelForBalanceDrop(dropUSD: 80, thresholds: thresholds), .warning)
        XCTAssertEqual(SpendAlertRules.levelForBalanceDrop(dropUSD: 250, thresholds: thresholds), .critical)
    }

    func testShouldFireRespectsCooldown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SpendAlertRules.shouldFire(lastFiredAt: nil, cooldown: 3600, now: now))
        XCTAssertFalse(SpendAlertRules.shouldFire(
            lastFiredAt: now.addingTimeInterval(-1800), cooldown: 3600, now: now))
        XCTAssertTrue(SpendAlertRules.shouldFire(
            lastFiredAt: now.addingTimeInterval(-3601), cooldown: 3600, now: now))
    }
}
