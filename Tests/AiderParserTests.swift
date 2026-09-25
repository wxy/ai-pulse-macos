import XCTest
@testable import AIPulse

final class AiderParserTests: XCTestCase {
    func testParseJSONLWithAllFields() {
        // Real aider output uses datetime.isoformat(): naive, no zone
        // designator, optionally with microseconds.
        let json = """
        {"model":"gpt-4o","input_tokens":1500,"output_tokens":800,"cost":0.0315,"timestamp":"2026-06-26T10:00:00"}
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

    func testNaiveTimestampIsHonoredInsteadOfNow() throws {
        let json = """
        {"model":"gpt-4o","input_tokens":10,"output_tokens":5,"timestamp":"2026-06-26T10:00:00"}
        """
        let event = try XCTUnwrap(AiderParser.parseJSONL(line: json, cwd: "/repo"))
        let expected = try XCTUnwrap(DateFormatter.makeLocalTimestamp(msFor: "2026-06-26T10:00:00"))
        XCTAssertEqual(event.ts, expected)
    }

    func testNaiveTimestampWithMicrosecondsIsHonored() throws {
        let json = """
        {"model":"gpt-4o","input_tokens":10,"output_tokens":5,"timestamp":"2026-06-26T10:00:00.123456"}
        """
        let event = try XCTUnwrap(AiderParser.parseJSONL(line: json, cwd: "/repo"))
        let expected = try XCTUnwrap(DateFormatter.makeLocalTimestamp(msFor: "2026-06-26T10:00:00.123456"))
        XCTAssertEqual(event.ts, expected)
    }
}

private extension DateFormatter {
    /// Mirrors the parser's naive-format interpretation (local time zone) so
    /// the expected value is derived independently of `Date()`.
    static func makeLocalTimestamp(msFor raw: String) -> Int? {
        let format = raw.contains(".") ? "yyyy-MM-dd'T'HH:mm:ss.SSSSSS" : "yyyy-MM-dd'T'HH:mm:ss"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.date(from: raw).map { Int($0.timeIntervalSince1970 * 1000) }
    }
}
