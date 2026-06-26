import XCTest
@testable import AIPulse

final class ClaudeCodeParserTests: XCTestCase {
    func testParseAssistantMessageWithUsage() {
        let json = """
        {"message":{"id":"msg-1","role":"assistant","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":200}},"timestamp":"2026-06-18T09:29:32.485Z"}
        """
        let result = ClaudeCodeParser.parse(line: json, cwd: "/Users/test/project", sessionId: "session-1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.source, "claude-code")
        XCTAssertEqual(result?.model, "claude-sonnet-4")
        XCTAssertEqual(result?.inTokens, 100)
        XCTAssertEqual(result?.outTokens, 50)
        XCTAssertEqual(result?.cacheTokens, 200)
        XCTAssertEqual(result?.repoPath, "/Users/test/project")
        XCTAssertEqual(result?.sessionId, "session-1")
    }

    func testIgnoresNonAssistantMessages() {
        let json = """
        {"type":"queue-operation","operation":"enqueue"}
        """
        let result = ClaudeCodeParser.parse(line: json, cwd: nil, sessionId: nil)
        XCTAssertNil(result)
    }

    func testIgnoresAssistantWithoutUsage() {
        let json = """
        {"message":{"role":"assistant","model":"claude-sonnet-4","content":"Hello"}}
        """
        let result = ClaudeCodeParser.parse(line: json, cwd: nil, sessionId: nil)
        XCTAssertNil(result)
    }

    func testHandlesMissingFields() {
        let json = """
        {"message":{"role":"assistant","usage":{}}}
        """
        let result = ClaudeCodeParser.parse(line: json, cwd: nil, sessionId: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.inTokens, 0)
        XCTAssertEqual(result?.outTokens, 0)
        XCTAssertNil(result?.model)
    }

    func testDedupeKeyWithSessionId() {
        let json = """
        {"message":{"id":"msg-xyz","role":"assistant","usage":{"input_tokens":1}}}
        """
        let result = ClaudeCodeParser.parse(line: json, cwd: nil, sessionId: "abc")
        XCTAssertEqual(result?.dedupeKey, "claude-code|abc|msg-xyz")
    }
}
