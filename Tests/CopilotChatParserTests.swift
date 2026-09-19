import XCTest
@testable import AIPulse

final class CopilotChatParserTests: XCTestCase {
    func testSnapshotWhitelistsCopilotUsageAndIgnoresConversationContent() throws {
        let line = #"{"kind":0,"v":{"sessionId":"session-1","responderUsername":"GitHub Copilot","requests":[{"requestId":"request-1","timestamp":1720000000123,"modelId":"fallback-model","promptTokens":1000,"completionTokens":200,"copilotCredits":1.2,"message":{"text":"private prompt must not be decoded"},"result":{"metadata":{"resolvedModel":"gpt-5.6-sol","summaries":[{"usage":{"prompt_tokens":600,"completion_tokens":120,"prompt_tokens_details":{"cached_tokens":400},"completion_tokens_details":{"reasoning_tokens":30},"copilot_usage":{"token_details":[{"model":"gpt-5.6-sol","token_count":25,"token_type":"cache_write"}]}}},{"usage":{"prompt_tokens":400,"completion_tokens":80,"prompt_tokens_details":{"cached_tokens":100},"completion_tokens_details":{"reasoning_tokens":10},"copilot_usage":{"token_details":[]}}}]}}}]}}"#
        var state = CopilotChatParser.State(repoPath: "/tmp/repo")

        let event = try XCTUnwrap(state.consume(line: line).only)

        XCTAssertEqual(event.ts, 1_720_000_000_123)
        XCTAssertEqual(event.source, "copilot")
        XCTAssertEqual(event.model, "gpt-5.6-sol")
        XCTAssertEqual(event.inTokens, 1_000)
        XCTAssertEqual(event.outTokens, 200)
        XCTAssertEqual(event.cacheTokens, 500)
        XCTAssertEqual(event.cacheCreationTokens, 25)
        XCTAssertEqual(event.reportedOutputTokens, 200)
        XCTAssertEqual(event.reasoningTokens, 40)
        XCTAssertEqual(event.repoPath, "/tmp/repo")
        XCTAssertEqual(event.sessionId, "session-1")
        XCTAssertEqual(event.dedupeKey, "copilot|session-1|request-1")
    }

    func testJournalPatchesReplaceOneRequestsLatestCounters() throws {
        var state = CopilotChatParser.State(repoPath: nil)
        XCTAssertTrue(state.consume(line: #"{"kind":0,"v":{"sessionId":"s","responderUsername":"GitHub Copilot","requests":[]}}"#).isEmpty)
        XCTAssertTrue(state.consume(line: #"{"kind":2,"k":["requests"],"v":[{"requestId":"r","timestamp":10,"modelId":"m"}]}"#).isEmpty)

        let partial = try XCTUnwrap(state.consume(line: #"{"kind":1,"k":["requests",0,"promptTokens"],"v":100}"#).only)
        XCTAssertEqual(partial.inTokens, 100)
        XCTAssertEqual(partial.outTokens, 0)
        let firstCompletion = try XCTUnwrap(state.consume(line: #"{"kind":1,"k":["requests",0,"completionTokens"],"v":20}"#).only)
        XCTAssertEqual(firstCompletion.inTokens, 100)
        XCTAssertEqual(firstCompletion.outTokens, 20)
        let finalCompletion = try XCTUnwrap(state.consume(line: #"{"kind":1,"k":["requests",0,"completionTokens"],"v":35}"#).only)
        XCTAssertEqual(finalCompletion.inTokens, 100)
        XCTAssertEqual(finalCompletion.outTokens, 35)
        XCTAssertEqual(partial.dedupeKey, finalCompletion.dedupeKey)
    }

    func testCopilotCreditsPatchCanEstablishSourceEvidence() throws {
        var state = CopilotChatParser.State(repoPath: nil)
        _ = state.consume(line: #"{"kind":0,"v":{"sessionId":"s","requests":[{"requestId":"r","timestamp":10,"promptTokens":100,"completionTokens":20}]}}"#)
        XCTAssertTrue(state.consume(line: #"{"kind":1,"k":["requests",0,"promptTokens"],"v":100}"#).isEmpty)

        let event = try XCTUnwrap(state.consume(line: #"{"kind":1,"k":["requests",0,"copilotCredits"],"v":0}"#).only)
        XCTAssertEqual(event.inTokens, 100)
        XCTAssertEqual(event.outTokens, 20)
    }

    func testUnattributedNativeChatIsNotMisreportedAsCopilot() {
        var state = CopilotChatParser.State(repoPath: nil)
        let events = state.consume(line: #"{"kind":0,"v":{"sessionId":"s","responderUsername":"Another Extension","requests":[{"requestId":"r","timestamp":10,"promptTokens":100,"completionTokens":20}]}}"#)
        XCTAssertTrue(events.isEmpty)
    }

    func testVSCodeWorkspaceFileURIResolvesToPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = directory.appendingPathComponent("workspace.json")
        try #"{"folder":"file:///tmp/Repo%20With%20Spaces"}"#.data(using: .utf8)?.write(to: metadata)

        XCTAssertEqual(LogWatcher.vsCodeWorkspacePath(from: metadata), "/tmp/Repo With Spaces")
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
