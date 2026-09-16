import XCTest
@testable import AIPulse

final class TokenAccountingTests: XCTestCase {
    func testObservedTotalDoesNotAddCachedInputTwice() {
        let result = TokenAccounting.breakdown(input: 1_000, output: 200, cachedInput: 800)

        XCTAssertEqual(result.nonCachedInput, 200)
        XCTAssertEqual(result.cachedInput, 800)
        XCTAssertEqual(result.output, 200)
        XCTAssertEqual(result.total, 1_200)
    }

    func testBreakdownClampsCorruptValues() {
        let result = TokenAccounting.breakdown(input: 100, output: -2, cachedInput: 500)

        XCTAssertEqual(result.nonCachedInput, 0)
        XCTAssertEqual(result.cachedInput, 100)
        XCTAssertEqual(result.output, 0)
        XCTAssertEqual(result.total, 100)
    }
}
