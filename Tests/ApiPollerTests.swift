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
