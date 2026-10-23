import XCTest
@testable import AIPulse

final class ApiPollerTests: XCTestCase {
    func testParseDoubleRejectsNonFiniteStrings() {
        XCTAssertNil(ApiPoller.parseDouble("nan"))
        XCTAssertNil(ApiPoller.parseDouble("inf"))
        XCTAssertNil(ApiPoller.parseDouble("-inf"))
        XCTAssertNil(ApiPoller.parseDouble("not-a-number"))
        XCTAssertEqual(ApiPoller.parseDouble("12.5") ?? -1, 12.5)
        XCTAssertEqual(ApiPoller.parseDouble(7) ?? -1, 7)
        XCTAssertEqual(ApiPoller.parseDouble(3.25) ?? -1, 3.25)
    }
}
// MARK: - 2026-10-23 review F09:观察变化入库与新基线,消费事件只认消费方向

final class ApiPollerBalanceBaselineTests: XCTestCase {
    func testFirstObservationIsBaselineNeverSpend() {
        let decision = ApiPoller.recordDecision(previous: nil, current: 100, isUsageType: false)
        XCTAssertTrue(decision.recordsBaseline)
        XCTAssertFalse(decision.isSpend)
    }

    func testPrepaidDecreaseRecordsBaselineAndIsSpend() {
        let decision = ApiPoller.recordDecision(previous: 100, current: 90, isUsageType: false)
        XCTAssertTrue(decision.recordsBaseline)
        XCTAssertTrue(decision.isSpend)
    }

    func testRechargeRecordsNewBaselineWithoutConsumption() {
        // 100 → 200 (充值):必须入库成为新基线,否则 200 → 190 会被
        // 差值系统当成 90 的消费。充值本身不是消费,不播铃声。
        let decision = ApiPoller.recordDecision(previous: 100, current: 200, isUsageType: false)
        XCTAssertTrue(decision.recordsBaseline)
        XCTAssertFalse(decision.isSpend)
    }

    func testUsageWindowResetRecordsNewBaselineWithoutConsumption() {
        // usage 型(累计用量)回落 = 滚动窗口重置:必须重置基线,不算消费。
        let decision = ApiPoller.recordDecision(previous: 10, current: 2, isUsageType: true)
        XCTAssertTrue(decision.recordsBaseline)
        XCTAssertFalse(decision.isSpend)
    }

    func testUsageGrowthIsSpend() {
        let decision = ApiPoller.recordDecision(previous: 10, current: 12, isUsageType: true)
        XCTAssertTrue(decision.recordsBaseline)
        XCTAssertTrue(decision.isSpend)
    }

    func testUnchangedBalanceRecordsNothing() {
        let decision = ApiPoller.recordDecision(previous: 100, current: 100, isUsageType: false)
        XCTAssertFalse(decision.recordsBaseline)
        XCTAssertFalse(decision.isSpend)
    }
}
