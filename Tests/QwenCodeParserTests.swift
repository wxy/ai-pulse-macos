import XCTest
@testable import AIPulse

final class QwenCodeParserTests: XCTestCase {

    func testParseGeminiMessage() {
        let line = """
        {"id":"q1","timestamp":"2026-08-02T10:00:00.000Z","type":"gemini","model":"qwen3-coder","content":"hi","tokens":{"input":100,"output":50,"cached":30,"thoughts":5,"tool":2,"total":150}}
        """
        let event = QwenCodeParser.parse(line: line, cwd: nil)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.source, "qwen-code")
        XCTAssertEqual(event?.model, "qwen3-coder")
        XCTAssertEqual(event?.inTokens, 100)
        XCTAssertEqual(event?.outTokens, 50)  // total - input = 50
        XCTAssertEqual(event?.cacheTokens, 30)
        XCTAssertTrue(event?.dedupeKey.hasPrefix("qwen|") ?? false)
    }

    func testUserMessageSkipped() {
        let line = """
        {"id":"u1","timestamp":"2026-08-02T10:00:00Z","type":"user","content":"hi"}
        """
        XCTAssertNil(QwenCodeParser.parse(line: line, cwd: nil))
    }

    func testGeminiMessageWithoutTokensSkipped() {
        let line = """
        {"id":"q2","timestamp":"2026-08-02T10:00:00Z","type":"gemini","model":"qwen3-coder","content":"x"}
        """
        XCTAssertNil(QwenCodeParser.parse(line: line, cwd: nil))
    }

    func testSessionHeaderDetection() {
        let header = """
        {"sessionId":"s1","projectHash":"abc123","startTime":"2026-08-02T10:00:00Z","lastUpdated":"2026-08-02T10:05:00Z","kind":"main"}
        """
        XCTAssertTrue(QwenCodeParser.isSessionHeader(header))
        let normal = """
        {"id":"u1","type":"user","content":"hi"}
        """
        XCTAssertFalse(QwenCodeParser.isSessionHeader(normal))
    }

    func testTimestampParsed() {
        let line = """
        {"id":"q1","timestamp":"2026-08-02T10:00:00.000Z","type":"gemini","model":"m","tokens":{"input":1,"output":1,"total":2}}
        """
        let event = QwenCodeParser.parse(line: line, cwd: nil)
        XCTAssertEqual(event?.ts, 1785664800000)
    }

    func testOutTokensFallbackToThoughtsPlusTool() {
        // If total missing, out = thoughts + tool
        let line = """
        {"id":"q1","timestamp":"2026-08-02T10:00:00Z","type":"gemini","model":"m","tokens":{"input":10,"thoughts":5,"tool":3}}
        """
        let event = QwenCodeParser.parse(line: line, cwd: nil)
        XCTAssertEqual(event?.outTokens, 8)
    }
}
