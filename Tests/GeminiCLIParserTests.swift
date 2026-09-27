import XCTest
@testable import AIPulse

/// The Gemini CLI adapter: format verified against upstream
/// `google-gemini/gemini-cli` chatRecordingService (see GeminiCLIParser's doc
/// comment). Parsing delegates to QwenCodeParser under the gemini-cli source
/// label; these tests pin that delegation and the qwen defaults.
final class GeminiCLIParserTests: XCTestCase {
    func testGeminiMessageWithFullTokenSummary() {
        let line = """
        {"id":"m1","timestamp":"2026-09-27T10:00:00.000Z","type":"gemini","model":"gemini-2.5-pro","content":"ok","tokens":{"input":100,"output":150,"cached":40,"thoughts":30,"tool":10,"total":250}}
        """
        let event = GeminiCLIParser.parse(line: line, cwd: nil)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.source, "gemini-cli")
        XCTAssertEqual(event?.model, "gemini-2.5-pro")
        XCTAssertEqual(event?.inTokens, 100)
        XCTAssertEqual(event?.cacheTokens, 40)
        XCTAssertEqual(event?.outTokens, 150, "output is total minus input; thoughts/tool never add twice")
        XCTAssertTrue(event?.dedupeKey.hasPrefix("gemini-cli|") == true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(event?.ts, Int(formatter.date(from: "2026-09-27T10:00:00.000Z")!.timeIntervalSince1970 * 1000))
    }

    func testNonGeminiMessagesProduceNoEvent() {
        // Metadata header, user message, tool-call record shapes: no usage.
        let header = """
        {"sessionId":"s1","projectHash":"abc","startTime":"2026-09-27T10:00:00.000Z","lastUpdated":"2026-09-27T10:05:00.000Z"}
        """
        let user = """
        {"id":"m0","timestamp":"2026-09-27T10:00:01.000Z","type":"user","content":"hi"}
        """
        let rewind = """
        {"$rewindTo":"m0"}
        """
        XCTAssertNil(GeminiCLIParser.parse(line: header, cwd: nil))
        XCTAssertNil(GeminiCLIParser.parse(line: user, cwd: nil))
        XCTAssertNil(GeminiCLIParser.parse(line: rewind, cwd: nil))
    }

    func testGarbageTimestampFallsBackToFileMtime() {
        let line = """
        {"id":"m2","timestamp":"bogus","type":"gemini","model":"gemini-2.5-flash","content":"x","tokens":{"input":5,"output":6,"cached":0,"total":11}}
        """
        let event = GeminiCLIParser.parse(line: line, cwd: nil, fallbackTimestampMs: 1_790_000_000_000)
        XCTAssertEqual(event?.ts, 1_790_000_000_000)
    }

    func testSessionFileClassification() {
        XCTAssertTrue(GeminiCLIParser.isSessionFile(URL(fileURLWithPath: "/h/.gemini/tmp/abc123/chats/session-2026-09-27T10-00-abcd1234.jsonl")))
        XCTAssertTrue(GeminiCLIParser.isSessionFile(URL(fileURLWithPath: "/h/.gemini/tmp/abc123/chats/parent-uuid/session-xyz.jsonl")),
                      "subagent sessions nest one level below chats/")
        XCTAssertFalse(GeminiCLIParser.isSessionFile(URL(fileURLWithPath: "/h/.gemini/tmp/abc123/checkpoint.json")))
        XCTAssertFalse(GeminiCLIParser.isSessionFile(URL(fileURLWithPath: "/h/.gemini/tmp/abc123/chats")))
    }

    func testQwenDefaultsStayStableAcrossTheRefactor() {
        let line = """
        {"id":"m1","timestamp":"2026-09-27T10:00:00.000Z","type":"gemini","model":"qwen3-coder","content":"ok","tokens":{"input":10,"output":5,"cached":0,"thoughts":0,"tool":0,"total":15}}
        """
        let event = QwenCodeParser.parse(line: line, cwd: nil)
        XCTAssertEqual(event?.source, "qwen-code")
        XCTAssertTrue(event?.dedupeKey.hasPrefix("qwen|") == true,
                      "existing installs must keep their dedupe keys after the source-parameter refactor")
    }
}
