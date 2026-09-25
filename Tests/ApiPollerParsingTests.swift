import XCTest
@testable import AIPulse

/// Table-driven coverage for the provider balance parsers — these numbers
/// are shown to the user as money, and the parsers are pure functions, so
/// every shape a provider can legally send is cheap to pin down here.
final class ApiPollerParsingTests: XCTestCase {
    // MARK: - deepseek (simple parser: balance_infos array)

    func testDeepSeekParsesBalanceInfos() {
        let json: [String: Any] = [
            "balance_infos": [[
                "currency": "CNY",
                "total_balance": "110.20",
                "granted_balance": "10.00",
                "topped_up_balance": "100.20",
            ]]
        ]
        let entries = ApiPoller.simpleParser(for: "deepseek")(json)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].currency, "CNY")
        XCTAssertEqual(entries[0].totalBalance, 110.20, accuracy: 0.0001)
        XCTAssertEqual(entries[0].grantedBalance, 10.00, accuracy: 0.0001)
        XCTAssertEqual(entries[0].toppedUpBalance, 100.20, accuracy: 0.0001)
    }

    func testDeepSeekMissingFieldsFallBackToZero() {
        let entries = ApiPoller.simpleParser(for: "deepseek")(["balance_infos": [[:]]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].totalBalance, 0, accuracy: 0.0001)
        XCTAssertEqual(entries[0].currency, "CNY")
    }

    func testDeepSeekNonFiniteStringsBecomeZero() {
        let entries = ApiPoller.simpleParser(for: "deepseek")([
            "balance_infos": [["total_balance": "nan", "granted_balance": "inf"]],
        ])
        XCTAssertEqual(entries[0].totalBalance, 0, accuracy: 0.0001)
        XCTAssertEqual(entries[0].grantedBalance, 0, accuracy: 0.0001)
    }

    // MARK: - moonshot (simple parser: nested data object)

    func testMoonshotReadsNestedDataObject() {
        let entries = ApiPoller.simpleParser(for: "moonshot")([
            "data": ["available_balance": 14.7286],
        ])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].totalBalance, 14.7286, accuracy: 0.0001)
    }

    func testMoonshotFallsBackToTopLevelBalance() {
        let entries = ApiPoller.simpleParser(for: "moonshot")(["balance": "3.5"])
        XCTAssertEqual(entries[0].totalBalance, 3.5, accuracy: 0.0001)
    }

    func testUnknownProviderParsesNothing() {
        XCTAssertTrue(ApiPoller.simpleParser(for: "not-a-provider")(["anything": 1]).isEmpty)
    }

    // MARK: - zhipu (query-customer-account-report)

    func testZhipuReadsBalanceObject() {
        let entries = ApiPoller.zhipuParser([
            "balance": ["availableBalance": "88.8", "balance": "100"],
        ])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].currency, "CNY")
        XCTAssertEqual(entries[0].totalBalance, 88.8, accuracy: 0.0001)
    }

    func testZhipuFallsBackToDataObjectThenZero() {
        XCTAssertEqual(ApiPoller.zhipuParser([
            "data": ["availableBalance": 42],
        ])[0].totalBalance, 42, accuracy: 0.0001)
        XCTAssertEqual(ApiPoller.zhipuParser([:]) [0].totalBalance, 0, accuracy: 0.0001)
    }

    // MARK: - parseDouble

    func testParseDoubleAcceptsStringNumberAndNSNumber() {
        XCTAssertEqual(ApiPoller.parseDouble("1.5")!, 1.5, accuracy: 0.0001)
        XCTAssertEqual(ApiPoller.parseDouble(2.5)!, 2.5, accuracy: 0.0001)
        XCTAssertEqual(ApiPoller.parseDouble(NSNumber(value: 3))!, 3, accuracy: 0.0001)
        XCTAssertNil(ApiPoller.parseDouble(nil))
        XCTAssertNil(ApiPoller.parseDouble("abc"))
        XCTAssertNil(ApiPoller.parseDouble(Double.nan))
        XCTAssertNil(ApiPoller.parseDouble(Double.infinity))
    }
}
