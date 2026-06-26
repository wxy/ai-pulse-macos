import XCTest
@testable import AIPulse

final class AiderParserTests: XCTestCase {
    func testParseJSONLWithAllFields() {
        let json = """
        {"model":"gpt-4o","input_tokens":1500,"output_tokens":800,"cost":0.0315,"timestamp":"2026-06-26T10:00:00Z"}
        """
        let event = AiderParser.parseJSONL(line: json, cwd: "/Users/test/repo")
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.source, "aider")
        XCTAssertEqual(event?.model, "gpt-4o")
        XCTAssertEqual(event?.inTokens, 1500)
        XCTAssertEqual(event?.outTokens, 800)
        XCTAssertEqual(event?.repoPath, "/Users/test/repo")
    }

    func testParseJSONLWithMissingFields() {
        let json = """
        {"model":"gpt-4o","input_tokens":100}
        """
        let event = AiderParser.parseJSONL(line: json, cwd: "/repo")
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.outTokens, 0)
    }

    func testDedupeKeyBasedOnTimestamp() {
        let json = """
        {"model":"gpt-4o","input_tokens":1,"timestamp":"2026-06-26T10:00:00Z"}
        """
        let event = AiderParser.parseJSONL(line: json, cwd: "/repo")
        XCTAssertTrue(event?.dedupeKey.contains("aider|2026-06-26T10:00:00Z") ?? false)
    }
}
