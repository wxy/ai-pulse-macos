import XCTest
@testable import AIPulse

final class OpenCodeParserTests: XCTestCase {

    func testParseAssistantMessage() {
        let json: [String: Any] = [
            "id": "msg-123",
            "role": "assistant",
            "model": "gpt-5-codex",
            "created_at": 1785664800,
            "tokens": ["input": 100, "output": 50, "cache": ["read": 30]],
        ]
        let event = OpenCodeParser.parse(json: json, cwd: "/Users/test/repo")
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.source, "opencode")
        XCTAssertEqual(event?.model, "gpt-5-codex")
        XCTAssertEqual(event?.inTokens, 100)
        XCTAssertEqual(event?.outTokens, 50)
        XCTAssertEqual(event?.cacheTokens, 30)
        XCTAssertEqual(event?.repoPath, "/Users/test/repo")
        XCTAssertEqual(event?.dedupeKey, "opencode|msg-123")
    }

    func testUserMessageSkipped() {
        let json: [String: Any] = ["id": "m1", "role": "user", "content": "hi"]
        XCTAssertNil(OpenCodeParser.parse(json: json, cwd: nil))
    }

    func testZeroTokensSkipped() {
        let json: [String: Any] = ["id": "m1", "role": "assistant", "tokens": ["input": 0, "output": 0]]
        XCTAssertNil(OpenCodeParser.parse(json: json, cwd: nil))
    }

    func testTimestampInSeconds() {
        let json: [String: Any] = [
            "id": "m1", "role": "assistant", "created_at": 1785664800,
            "tokens": ["input": 10, "output": 5],
        ]
        let event = OpenCodeParser.parse(json: json, cwd: nil)
        XCTAssertEqual(event?.ts, 1785664800000)  // seconds → ms
    }

    func testFallbackDedupeKeyWhenNoId() {
        let json: [String: Any] = [
            "role": "assistant", "created_at": 1785664800, "model": "m",
            "tokens": ["input": 10, "output": 5],
        ]
        let event = OpenCodeParser.parse(json: json, cwd: nil)
        XCTAssertTrue(event?.dedupeKey.hasPrefix("opencode|") ?? false)
    }
}
