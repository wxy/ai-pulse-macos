import XCTest
@testable import AIPulse

final class ClaudeCodeParserTests: XCTestCase {
    func testParseAssistantMessageWithUsage() {
        let json = """
        {"message":{"id":"msg-1","role":"assistant","model":"deepseek-v4-pro","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":200}},"cwd":"/Users/test/project","sessionId":"session-1","timestamp":"2026-06-18T09:29:32.485Z"}
        """
        let result = ClaudeCodeParser.parse(line: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.source, "claude-code")
        XCTAssertEqual(result?.model, "deepseek-v4-pro")
        XCTAssertEqual(result?.inTokens, 100)
        XCTAssertEqual(result?.outTokens, 50)
        XCTAssertEqual(result?.cacheTokens, 200)
        XCTAssertEqual(result?.repoPath, "/Users/test/project")
        XCTAssertEqual(result?.sessionId, "session-1")
    }

    func testIgnoresNonAssistantMessages() {
        let result = ClaudeCodeParser.parse(line: """
        {"type":"queue-operation","operation":"enqueue"}
        """)
        XCTAssertNil(result)
    }

    func testIgnoresAssistantWithoutUsage() {
        XCTAssertNil(ClaudeCodeParser.parse(line: """
        {"message":{"role":"assistant","model":"claude-sonnet-4","content":"Hello"}}
        """))
    }

    func testHandlesMissingFields() {
        let result = ClaudeCodeParser.parse(line: """
        {"message":{"role":"assistant","usage":{}}}
        """)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.inTokens, 0)
        XCTAssertEqual(result?.outTokens, 0)
    }

    func testDedupeKeyWithSessionId() {
        let result = ClaudeCodeParser.parse(line: """
        {"message":{"id":"msg-xyz","role":"assistant","usage":{"input_tokens":1}},"sessionId":"abc"}
        """)
        XCTAssertEqual(result?.dedupeKey, "claude-code|abc|msg-xyz")
    }

    func testParsesCwdFromJson() {
        let result = ClaudeCodeParser.parse(line: """
        {"message":{"role":"assistant","usage":{"input_tokens":1}},"cwd":"/Users/xingyuwang/develop/ai-pulse"}
        """)
        XCTAssertEqual(result?.repoPath, "/Users/xingyuwang/develop/ai-pulse")
    }
}
