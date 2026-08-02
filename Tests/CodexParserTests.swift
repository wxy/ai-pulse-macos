import XCTest
@testable import AIPulse

final class CodexParserTests: XCTestCase {

    func testParseTokenCountEvent() {
        let line = """
        {"timestamp":"2026-08-02T10:00:00.000Z","type":"token_count","payload":{"session_id":"abc","last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":180}}}
        """
        let event = CodexParser.parse(line: line, cwd: "/Users/test/repo", model: "gpt-5-codex")
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.source, "codex")
        XCTAssertEqual(event?.model, "gpt-5-codex")
        XCTAssertEqual(event?.repoPath, "/Users/test/repo")
        XCTAssertEqual(event?.inTokens, 100)
        XCTAssertEqual(event?.outTokens, 50)  // output + reasoning
        XCTAssertEqual(event?.cacheTokens, 30)
        XCTAssertEqual(event?.sessionId, "abc")
        XCTAssertTrue(event?.dedupeKey.hasPrefix("codex|") ?? false)
    }

    func testNonTokenCountLineSkipped() {
        let line = """
        {"timestamp":"2026-08-02T10:00:00Z","type":"response_item","payload":{"id":"x"}}
        """
        XCTAssertNil(CodexParser.parse(line: line, cwd: "/repo", model: nil))
    }

    func testMalformedLineSkipped() {
        XCTAssertNil(CodexParser.parse(line: "not json", cwd: nil, model: nil))
    }

    func testSessionMetaCwdExtraction() {
        let line = """
        {"timestamp":"2026-08-02T10:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/Users/me/proj","model_provider":"openai"}}
        """
        XCTAssertEqual(CodexParser.cwd(fromLine: line), "/Users/me/proj")
    }

    func testTurnContextModelExtraction() {
        let line = """
        {"timestamp":"2026-08-02T10:00:00Z","type":"turn_context","payload":{"session_id":"s1","model":"gpt-5-codex"}}
        """
        XCTAssertEqual(CodexParser.model(fromLine: line), "gpt-5-codex")
    }

    func testTimestampParsedFromISO8601() {
        let line = """
        {"timestamp":"2026-08-02T10:00:00.000Z","type":"token_count","payload":{"last_token_usage":{"input_tokens":1,"output_tokens":1}}}
        """
        let event = CodexParser.parse(line: line, cwd: nil, model: nil)
        // 2026-08-02T10:00:00Z in ms
        XCTAssertEqual(event?.ts, 1785664800000)
    }
}
