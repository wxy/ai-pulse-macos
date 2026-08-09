import XCTest
@testable import AIPulse

final class SessionInfoRecordTests: XCTestCase {
    func testMakeTitleTruncates() {
        let long = String(repeating: "a", count: 100)
        let title = SessionInfoRecord.makeTitle(long)
        XCTAssertEqual(title?.count, 60)
    }

    func testMakeTitleNilForEmpty() {
        XCTAssertNil(SessionInfoRecord.makeTitle(nil))
        XCTAssertNil(SessionInfoRecord.makeTitle(""))
        XCTAssertNil(SessionInfoRecord.makeTitle("   "))
    }

    func testMakeTitleCollapsesWhitespace() {
        XCTAssertEqual(SessionInfoRecord.makeTitle("  hello   world  "), "hello world")
    }
}
