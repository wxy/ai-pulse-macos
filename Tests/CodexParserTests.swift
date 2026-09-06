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

    func testParseEventMsgWrappedTokenCount() {
        // ChatGPT desktop app format: token_count nested inside event_msg.info.
        let line = """
        {"timestamp":"2026-08-09T00:40:35.898Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":22364,"cached_input_tokens":9728,"output_tokens":669,"reasoning_output_tokens":469,"total_tokens":23033},"last_token_usage":{"input_tokens":22364,"cached_input_tokens":9728,"output_tokens":669,"reasoning_output_tokens":469,"total_tokens":23033},"model_context_window":996147},"rate_limits":{"limit_id":"codex"}}}
        """
        let event = CodexParser.parse(
            line: line,
            cwd: "/Users/test/repo",
            model: "gpt-5-codex",
            sessionId: "thread-1"
        )
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.source, "codex")
        XCTAssertEqual(event?.model, "gpt-5-codex")
        XCTAssertEqual(event?.repoPath, "/Users/test/repo")
        XCTAssertEqual(event?.sessionId, "thread-1")
        XCTAssertEqual(event?.inTokens, 22364)
        XCTAssertEqual(event?.outTokens, 1138)  // output + reasoning
        XCTAssertEqual(event?.cacheTokens, 9728)
    }

    func testEventMsgWithoutTokenCountSkipped() {
        let line = """
        {"timestamp":"2026-08-09T00:40:35Z","type":"event_msg","payload":{"type":"output_text","text":"hi"}}
        """
        XCTAssertNil(CodexParser.parse(line: line, cwd: nil, model: nil))
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

    func testSessionMetaSessionIdExtraction() {
        let line = """
        {"timestamp":"2026-08-02T10:00:00Z","type":"session_meta","payload":{"session_id":"019fda52-1234","cwd":"/Users/me/proj"}}
        """
        XCTAssertEqual(CodexParser.sessionId(fromLine: line), "019fda52-1234")
    }

    func testTurnContextModelExtraction() {
        let line = """
        {"timestamp":"2026-08-02T10:00:00Z","type":"turn_context","payload":{"session_id":"s1","model":"gpt-5-codex"}}
        """
        XCTAssertEqual(CodexParser.model(fromLine: line), "gpt-5-codex")
    }

    func testSessionMetaModelExtraction() {
        let line = """
        {"timestamp":"2026-08-02T10:00:00Z","type":"session_meta","payload":{"id":"s1","model":"glm-5.3-flash"}}
        """
        XCTAssertEqual(CodexParser.sessionMetaModel(fromLine: line), "glm-5.3-flash")
    }

    func testTimestampParsedFromISO8601() {
        let line = """
        {"timestamp":"2026-08-02T10:00:00.000Z","type":"token_count","payload":{"last_token_usage":{"input_tokens":1,"output_tokens":1}}}
        """
        let event = CodexParser.parse(line: line, cwd: nil, model: nil)
        // 2026-08-02T10:00:00Z in ms
        XCTAssertEqual(event?.ts, 1785664800000)
    }

    func testFirstUserMessageFromUserMessageEvent() {
        let line = """
        {"timestamp":"2026-08-09T00:40:28Z","type":"event_msg","payload":{"type":"user_message","client_id":"x","message":"排查硬盘占用并给出方案"}}
        """
        XCTAssertEqual(CodexParser.firstUserMessage(fromLine: line), "排查硬盘占用并给出方案")
    }

    func testWindowTokensFromTokenCountEvent() {
        let line = """
        {"timestamp":"2026-08-09T00:40:35Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1},"model_context_window":996147}}}
        """
        XCTAssertEqual(CodexParser.windowTokens(fromLine: line), 996147)
    }

    func testIsSessionComplete() {
        XCTAssertTrue(CodexParser.isSessionComplete(fromLine: #"{"type":"task_complete","payload":{}}"#))
        XCTAssertFalse(CodexParser.isSessionComplete(fromLine: #"{"type":"task_started","payload":{}}"#))
    }
}
