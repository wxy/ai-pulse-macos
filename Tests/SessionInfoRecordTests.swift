import XCTest
@testable import AIPulse

final class SessionInfoRecordTests: XCTestCase {
    func testMakeTitleTruncates() {
        let long = String(repeating: "a", count: 100)
        let title = SessionInfoRecord.makeTitle(long)
        XCTAssertEqual(title?.count, 40)
    }

    func testMakeTitleNilForEmpty() {
        XCTAssertNil(SessionInfoRecord.makeTitle(nil))
        XCTAssertNil(SessionInfoRecord.makeTitle(""))
        XCTAssertNil(SessionInfoRecord.makeTitle("   "))
    }

    func testMakeTitleCollapsesWhitespace() {
        XCTAssertEqual(SessionInfoRecord.makeTitle("  hello   world  "), "hello world")
    }

    func testMakeTitleTakesFirstLine() {
        XCTAssertEqual(SessionInfoRecord.makeTitle("第一行内容\n第二行内容"), "第一行内容")
    }

    func testMakeTitleStopsAtSentenceEnd() {
        XCTAssertEqual(SessionInfoRecord.makeTitle("排查硬盘占用并给出方案。第二句内容"), "排查硬盘占用并给出方案。")
    }
}
