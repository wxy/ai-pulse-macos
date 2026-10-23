import XCTest
@testable import AIPulse

/// The 2026-09-24 review (P1-3 follow-up) found parsers silently stamping
/// events whose timestamp was missing or unparseable with the wall clock, so
/// re-imported history piled onto the scan day with no observable signal.
/// These tests pin the resolution chain: parsed → file mtime → wall clock,
/// with the first two tiers wired into every parser.
final class EventTimestampTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ParserTimestampFallbackCounter.shared.resetForTesting()
    }

    override func tearDown() {
        ParserTimestampFallbackCounter.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Resolution chain

    func testParsedTimestampWins() {
        let ts = EventTimestamp.resolve(parsed: 1_750_000_000_000, fileModifiedMs: 1_760_000_000_000, source: "test")
        XCTAssertEqual(ts, 1_750_000_000_000)
    }

    func testMissingParsedTimestampFallsBackToFileMtime() {
        let ts = EventTimestamp.resolve(parsed: nil, fileModifiedMs: 1_760_000_000_000, source: "test")
        XCTAssertEqual(ts, 1_760_000_000_000)
        XCTAssertEqual(
            ParserTimestampFallbackCounter.shared.count(source: "test", mode: .fileMtime), 1)
    }

    func testNonPositiveMtimeIsTreatedAsUnavailable() {
        let before = Int(Date().timeIntervalSince1970 * 1000)
        let ts = EventTimestamp.resolve(parsed: nil, fileModifiedMs: 0, source: "test")
        XCTAssertGreaterThanOrEqual(ts, before)
        XCTAssertEqual(
            ParserTimestampFallbackCounter.shared.count(source: "test", mode: .wallClock), 1)
        XCTAssertEqual(
            ParserTimestampFallbackCounter.shared.count(source: "test", mode: .fileMtime), 0)
    }

    func testReportFallbackFalseDoesNotCount() {
        _ = EventTimestamp.resolve(parsed: nil, fileModifiedMs: 1_760_000_000_000, source: "test", reportFallback: false)
        _ = EventTimestamp.resolve(parsed: nil, fileModifiedMs: 0, source: "test", reportFallback: false)
        XCTAssertEqual(
            ParserTimestampFallbackCounter.shared.count(source: "test", mode: .fileMtime), 0)
        XCTAssertEqual(
            ParserTimestampFallbackCounter.shared.count(source: "test", mode: .wallClock), 0)
    }

    // MARK: - Rate-limited counter

    func testCounterReportsFirstThenEveryFiftieth() {
        let counter = ParserTimestampFallbackCounter.shared
        XCTAssertTrue(counter.record(source: "rate", mode: .fileMtime), "first occurrence reports")
        for _ in 2...49 {
            XCTAssertFalse(counter.record(source: "rate", mode: .fileMtime))
        }
        XCTAssertTrue(counter.record(source: "rate", mode: .fileMtime), "50th occurrence reports")
    }

    func testCounterIsolatesSourcesAndModes() {
        let counter = ParserTimestampFallbackCounter.shared
        XCTAssertTrue(counter.record(source: "a", mode: .fileMtime))
        XCTAssertTrue(counter.record(source: "b", mode: .fileMtime), "different source reports independently")
        XCTAssertTrue(counter.record(source: "a", mode: .wallClock), "different mode reports independently")
        XCTAssertFalse(counter.record(source: "a", mode: .fileMtime))
    }

    // MARK: - Parser wiring (bad or missing timestamps land on the file mtime)

    func testClaudeCodeParserUsesMtimeWhenTimestampIsGarbage() {
        let line = """
        {"timestamp":"not-a-date","message":{"role":"assistant","model":"claude-x","id":"msg_1","usage":{"input_tokens":10,"output_tokens":5}}}
        """
        let event = ClaudeCodeParser.parse(line: line, fallbackTimestampMs: 1_760_000_000_000)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.ts, 1_760_000_000_000)
    }

    func testCodexParserUsesMtimeWhenTimestampIsMissing() {
        let line = """
        {"type":"token_count","payload":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":3}}}
        """
        let event = CodexParser.parse(line: line, cwd: nil, model: nil, fallbackTimestampMs: 1_760_000_000_001)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.ts, 1_760_000_000_001)
    }

    func testQwenParserUsesMtimeWhenTimestampIsGarbage() {
        let line = """
        {"type":"gemini","model":"qwen3-coder","tokens":{"input":100,"output":20,"cached":0,"thoughts":0,"tool":0,"total":120},"timestamp":"oops"}
        """
        let event = QwenCodeParser.parse(line: line, cwd: nil, fallbackTimestampMs: 1_760_000_000_002)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.ts, 1_760_000_000_002)
    }

    func testAiderJSONLUsesMtimeWhenTimestampIsMissing() {
        let line = """
        {"model":"gpt-4o","input_tokens":100,"output_tokens":50}
        """
        let event = AiderParser.parseJSONL(line: line, cwd: "/repo", fallbackTimestampMs: 1_760_000_000_003)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.ts, 1_760_000_000_003)
    }

    func testAiderMarkdownUsesProvidedFallbackDate() {
        let event = AiderParser.parseMarkdown(
            line: "> Tokens: 12k sent, 47 received. Cost: $0.0034 message, $0.0034 session.",
            cwd: "/repo", model: "gpt-4o", fallbackDate: 1_760_000_000_004)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.ts, 1_760_000_000_004)
    }

    func testDeepSeekHarnessParserUsesMtimeWhenTimeIsMissing() {
        let line = """
        {"type":"assistant/chunk","data":{"chunk":{"type":"usage","usage":{"inputTokens":30,"outputTokens":10,"cacheReadTokens":0,"reasoningTokens":0}}}}
        """
        let event = DeepSeekHarnessParser.parse(
            line: line, cwd: nil, model: nil, sessionId: nil, fallbackTimestampMs: 1_760_000_000_005)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.ts, 1_760_000_000_005)
    }

    func testOpenCodeParserUsesMtimeWhenNoTimestampField() {
        let json: [String: Any] = [
            "role": "assistant", "id": "msg_1",
            "tokens": ["input": 10, "output": 4],
        ]
        let event = OpenCodeParser.parse(json: json, cwd: nil, fallbackTimestampMs: 1_760_000_000_006)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.ts, 1_760_000_000_006)
    }

    // MARK: - Parsed timestamps still win everywhere

    func testParsedTimestampBeatsMtimeForEveryParser() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = Int(formatter.date(from: "2026-06-18T09:29:32.485Z")!.timeIntervalSince1970 * 1000)

        let claude = ClaudeCodeParser.parse(
            line: """
            {"timestamp":"2026-06-18T09:29:32.485Z","message":{"role":"assistant","id":"m","usage":{"input_tokens":1,"output_tokens":1}}}
            """, fallbackTimestampMs: 1_760_000_000_000)
        XCTAssertEqual(claude?.ts, expected)

        let aider = AiderParser.parseJSONL(
            line: """
            {"model":"m","input_tokens":1,"output_tokens":1,"timestamp":"2026-06-26T10:00:00"}
            """, cwd: nil, fallbackTimestampMs: 1_760_000_000_000)
        XCTAssertEqual(aider?.source, "aider")
        XCTAssertEqual(
            ParserTimestampFallbackCounter.shared.count(source: "aider", mode: .fileMtime), 0,
            "a successfully parsed timestamp is not a fallback")
    }

    // MARK: - 2026-10-23 review F01:非法数值时间戳必须降级而不是陷阱退出

    func testScaledBy1000RejectsValuesOutsideRepresentableRange() {
        XCTAssertEqual(EventTimestamp.scaledBy1000(1_730_000_000), 1_730_000_000_000)
        XCTAssertEqual(EventTimestamp.scaledBy1000(-1_730_000_000), -1_730_000_000_000)
        XCTAssertEqual(EventTimestamp.scaledBy1000(1_730_000_000.5), 1_730_000_000_500)
        XCTAssertNil(EventTimestamp.scaledBy1000(1e20), "1e20 s is a legal JSON number but not an Int")
        XCTAssertNil(EventTimestamp.scaledBy1000(-1e20))
        XCTAssertNil(EventTimestamp.scaledBy1000(1e308), "×1000 is not even finite")
        XCTAssertNil(EventTimestamp.scaledBy1000(.infinity))
        XCTAssertNil(EventTimestamp.scaledBy1000(.nan))
    }

    func testClaudeNumericTimestampFarOutsideIntRangeFallsBackToMtime() {
        // The previous implementation executed `Int(1e20 * 1000)` here, which
        // traps — and startup re-reads the file, so one corrupted line could
        // keep the app from launching. It must degrade to the mtime instead.
        let line = """
        {"timestamp":1e20,"message":{"role":"assistant","id":"m","usage":{"input_tokens":1,"output_tokens":1}}}
        """
        let event = ClaudeCodeParser.parse(line: line, fallbackTimestampMs: 1_760_000_000_000)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.ts, 1_760_000_000_000)
        XCTAssertEqual(
            ParserTimestampFallbackCounter.shared.count(source: "claude-code", mode: .fileMtime), 1)
    }

    func testClaudeNegativeHugeNumericTimestampFallsBackToMtime() {
        let line = """
        {"timestamp":-1e20,"message":{"role":"assistant","id":"m","usage":{"input_tokens":1,"output_tokens":1}}}
        """
        let event = ClaudeCodeParser.parse(line: line, fallbackTimestampMs: 1_760_000_000_001)
        XCTAssertEqual(event?.ts, 1_760_000_000_001)
    }

    func testClaudeNormalNumericTimestampStillWins() {
        let line = """
        {"timestamp":1781770172,"message":{"role":"assistant","id":"m","usage":{"input_tokens":1,"output_tokens":1}}}
        """
        let event = ClaudeCodeParser.parse(line: line, fallbackTimestampMs: 1_760_000_000_002)
        XCTAssertEqual(event?.ts, 1_781_770_172_000)
        XCTAssertEqual(
            ParserTimestampFallbackCounter.shared.count(source: "claude-code", mode: .fileMtime), 0)
    }

    func testOpenCodeNumericTimestampOutsideIntRangeFallsBackToMtime() {
        var json: [String: Any] = [
            "role": "assistant", "id": "msg_1",
            "tokens": ["input": 10, "output": 4],
            "created_at": Double(1e20),
        ]
        let event = OpenCodeParser.parse(json: json, cwd: nil, fallbackTimestampMs: 1_760_000_000_003)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.ts, 1_760_000_000_003)

        json["created_at"] = 1_730_000_000.0
        json.removeValue(forKey: "timestamp")
        let normal = OpenCodeParser.parse(json: json, cwd: nil, fallbackTimestampMs: 1_760_000_000_004)
        XCTAssertEqual(normal?.ts, 1_730_000_000_000)
    }

    func testAiderMarkdownHugeKTokenCountDoesNotTrap() {
        let event = AiderParser.parseMarkdown(
            line: "> Tokens: 99999999999999999999k sent, 47 received. Cost: $0.0034 message, $0.0034 session.",
            cwd: "/repo", model: "gpt-4o", fallbackDate: 1_760_000_000_005)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.inTokens, 0, "an absurd digit run degrades to 0 like an unparseable count")
        XCTAssertEqual(event?.outTokens, 47)
    }
}
