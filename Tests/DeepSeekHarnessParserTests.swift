import XCTest
@testable import AIPulse

final class DeepSeekHarnessParserTests: XCTestCase {
    func testMetadataExtraction() {
        XCTAssertEqual(
            DeepSeekHarnessParser.metadata(fromLine: #"{"type":"session","id":"s1","cwd":"/tmp/repo"}"#)?.sessionId,
            "s1")
        XCTAssertEqual(
            DeepSeekHarnessParser.metadata(fromLine: #"{"type":"request/context","data":{"provider":"deepseek-official","model":"deepseek-v4-flash"}}"#)?.model,
            "deepseek-v4-flash")
        XCTAssertEqual(
            DeepSeekHarnessParser.metadata(fromLine: #"""
            {"type":"assistant/message","data":{"message":{"source":{"kind":"model","provider":"deepseek-official","model":"deepseek-v4-flash"}}}}
            """#)?.model,
            "deepseek-v4-flash")
    }

    func testUsageChunkBecomesUsageEvent() {
        let line = """
        {"type":"assistant/chunk","time":1788350142825,"data":{"turn":17,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":66,"outputTokens":440,"cacheReadTokens":104832,"reasoningTokens":286}}}}
        """
        let event = DeepSeekHarnessParser.parse(
            line: line,
            cwd: "/tmp/repo",
            model: "deepseek-v4-flash",
            sessionId: "session-1")

        XCTAssertEqual(event?.source, "deepseek-harness")
        XCTAssertEqual(event?.model, "deepseek-v4-flash")
        XCTAssertEqual(event?.inTokens, 66)
        XCTAssertEqual(event?.outTokens, 726)
        XCTAssertEqual(event?.cacheTokens, 104832)
        XCTAssertEqual(event?.sessionId, "session-1")
        XCTAssertEqual(PricingManager.shared.providerId(for: event?.model), "deepseek")
    }

    func testCompletedTurnDetected() {
        XCTAssertTrue(DeepSeekHarnessParser.isComplete(
            fromLine: #"{"type":"turn/end","data":{"reason":{"kind":"completed"}}}"#))
        XCTAssertFalse(DeepSeekHarnessParser.isComplete(
            fromLine: #"{"type":"turn/end","data":{"reason":{"kind":"cancelled"}}}"#))
    }

    func testDeepSeekHarnessIntegrationIsRegistered() {
        XCTAssertTrue(
            IntegrationRegistry.visible.contains { $0.id == "deepseek-harness" },
            "DeepSeek Harness must appear as a supported dev tool"
        )
    }
}
