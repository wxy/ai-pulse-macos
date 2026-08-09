import XCTest
@testable import AIPulse

final class SessionInfoBackfillTests: XCTestCase {
    func testCodexSnippetExtractsMetadata() {
        let snippet = Data("""
        {"timestamp":"2026-08-09T00:00:00Z","type":"session_meta","payload":{"session_id":"s1","cwd":"/repo"}}
        {"timestamp":"2026-08-09T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"第一个任务"}}
        {"timestamp":"2026-08-09T00:00:02Z","type":"task_complete","payload":{}}
        """.utf8)
        let record = SessionInfoBackfill.metadataFromSnippet(
            snippet, source: "codex", sessionId: nil, repo: nil)
        XCTAssertEqual(record?.sessionId, "s1")
        XCTAssertEqual(record?.repo, "/repo")
        XCTAssertEqual(record?.title, "第一个任务")
        XCTAssertEqual(record?.completed, true)
    }

    func testClaudeSnippetExtractsTitle() {
        let snippet = Data("""
        {"timestamp":"2026-07-14T03:07:27.904Z","type":"user","message":{"role":"user","content":[{"type":"text","text":"请分析"}]}}
        """.utf8)
        let record = SessionInfoBackfill.metadataFromSnippet(
            snippet, source: "claude-code", sessionId: "c1", repo: "/r")
        XCTAssertEqual(record?.title, "请分析")
        XCTAssertEqual(record?.sessionId, "c1")
    }
}
