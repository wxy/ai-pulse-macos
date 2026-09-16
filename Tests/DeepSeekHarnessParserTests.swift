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

// MARK: - Journal v3 (2026-09): usage carried on assistant/message

extension DeepSeekHarnessParserTests {

    func testV3MessageUsageBecomesUsageEvent() {
        let line = """
        {"type":"assistant/message","seq":17,"time":1789171723019,"data":{"turn":1,"step":1,"usage":{"inputTokens":9145,"outputTokens":131,"totalTokens":9276,"cacheReadTokens":64,"reasoningTokens":50},"message":{"role":"assistant","source":{"model":"glm-5.3-flash"}}}}
        """
        let event = DeepSeekHarnessParser.parse(
            line: line,
            cwd: "/tmp/repo",
            model: "glm-5.3-flash",
            sessionId: "session-v3")

        XCTAssertEqual(event?.source, "deepseek-harness")
        XCTAssertEqual(event?.model, "glm-5.3-flash")
        XCTAssertEqual(event?.inTokens, 9145)
        XCTAssertEqual(event?.outTokens, 181, "outputTokens + reasoningTokens")
        XCTAssertEqual(event?.cacheTokens, 64)
        XCTAssertEqual(event?.dedupeKey.hasPrefix("deepseek-harness|"), true)
    }

    func testV3MessageWithoutUsageIsIgnored() {
        let line = """
        {"type":"assistant/message","seq":3,"time":1789171723019,"data":{"message":{"role":"assistant","source":{"model":"glm-5.3-flash"}}}}
        """
        XCTAssertNil(DeepSeekHarnessParser.parse(
            line: line, cwd: nil, model: "glm-5.3-flash", sessionId: nil))
    }

    func testV3TurnEndStillDetected() {
        XCTAssertTrue(DeepSeekHarnessParser.isComplete(
            fromLine: #"{"type":"turn/end","seq":99,"data":{"reason":{"kind":"completed"}}}"#))
    }
}
