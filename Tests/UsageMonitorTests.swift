import XCTest
import GRDB
@testable import AIPulse

final class UsageMonitorTests: XCTestCase {
    func testClaudeSourceTimeCannotBeRenewedByTouchingOrCopying() throws {
        let source = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-17T02:00:00Z"))
        let now = source.addingTimeInterval(600)
        let json: [String: Any] = ["updatedAt": "2026-09-17T02:00:00.000Z"]
        XCTAssertEqual(UsageMonitor.claudeObservationDate(json, modifiedAt: now, now: now), source)
        XCTAssertEqual(UsageMonitor.claudeObservationDate(json, modifiedAt: source.addingTimeInterval(-10), now: now),
                       source.addingTimeInterval(-10))
        XCTAssertNil(UsageMonitor.claudeObservationDate([:], modifiedAt: now, now: now))
        XCTAssertNil(UsageMonitor.claudeObservationDate(["updatedAt": "invalid"], modifiedAt: now, now: now))
        XCTAssertNil(UsageMonitor.claudeObservationDate(json, modifiedAt: now.addingTimeInterval(1), now: now))
        XCTAssertNil(UsageMonitor.claudeObservationDate(["updatedAt": "2026-09-18T02:00:00Z"], modifiedAt: now, now: now))
    }

    func testClaudeRecentModelDoesNotUseDistinctHistoricalOrFutureModels() throws {
        let queue = try DatabaseQueue()
        let now = Date(timeIntervalSince1970: 100_000)
        let end = Int(now.timeIntervalSince1970 * 1_000)
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            for (index, item) in [(end - 6 * 3_600_000, "claude-sonnet-4"),
                                  (end - 1000, "deepseek-chat"),
                                  (end + 1000, "claude-opus-4")].enumerated() {
                let event = UsageEvent(ts: item.0, source: "claude-code", model: item.1,
                                       inTokens: 10, outTokens: 2, cacheTokens: 0,
                                       repoPath: nil, sessionId: nil, dedupeKey: "model-\(index)")
                _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "unknown")], nowMs: Int64(end))
            }
            XCTAssertEqual(try UsageMonitor.latestClaudeModel(in: db, now: now), "deepseek-chat")
            XCTAssertNil(try UsageMonitor.latestClaudeModel(in: db, now: now.addingTimeInterval(6 * 3_600)))
        }
    }

    // MARK: - Claude status cache parsing

    func testParseClaudeStatusCacheValid() {
        let json: [String: Any] = [
            "version": 2,
            "usageData": [
                "utilization5h": 0.23,
                "utilization7d": 0.45,
                "limitStatus": "allowed",
                "reset5hAt": 1718740800,
                "reset7dAt": 1719086400,
            ],
        ]
        let result = UsageMonitor.parseClaudeStatusCache(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.utilization5h, 0.23)
        XCTAssertEqual(result?.utilization7d, 0.45)
        XCTAssertEqual(result?.limitStatus, "allowed")
        XCTAssertEqual(result?.reset5hAt, 1718740800)
        XCTAssertEqual(result?.reset7dAt, 1719086400)
    }

    func testParseClaudeStatusCacheMissingUsageData() {
        let json: [String: Any] = ["version": 2]
        let result = UsageMonitor.parseClaudeStatusCache(json)
        XCTAssertNil(result)
    }

    func testParseClaudeStatusCacheEmptyUsage() {
        let json: [String: Any] = ["usageData": [:]]
        let result = UsageMonitor.parseClaudeStatusCache(json)
        XCTAssertNil(result, "missing utilization is unknown, not observed zero")
    }

    func testParseClaudeStatusCacheReturnsBothWindows() {
        let json: [String: Any] = [
            "usageData": [
                "utilization5h": 0.9,
                "utilization7d": 0.3,
                "limitStatus": "allowed_warning",
            ],
        ]
        let result = UsageMonitor.parseClaudeStatusCache(json)
        XCTAssertNotNil(result)
        // Both windows round-trip independently; consumers decide how to
        // combine them (the status list no longer applies a max()).
        XCTAssertEqual(result?.utilization5h, 0.9)
        XCTAssertEqual(result?.utilization7d, 0.3)
        XCTAssertEqual(result?.limitStatus, "allowed_warning")
    }

    // MARK: - Copilot API response parsing

    func testParseCopilotResponseValid() {
        let json: [String: Any] = [
            "quota_reset_date": "2026-08-01T00:00:00Z",
            "quota_snapshots": [
                "premium_interactions": [
                    "percent_remaining": 31.16,
                    "overage_count": 0,
                    "quota_remaining": 93,
                    "unlimited": false,
                ],
            ],
        ]
        let result = UsageMonitor.parseCopilotResponse(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.usedPercent, 68.84)
        XCTAssertEqual(result?.overageCount, 0)
        XCTAssertEqual(result?.quotaResetAt, 1785542400)
    }

    func testParseCopilotResponseOverage() {
        let json: [String: Any] = [
            "quota_snapshots": [
                "premium_interactions": [
                    "percent_remaining": 0.0,
                    "overage_count": 15,
                    "quota_remaining": 0,
                ],
            ],
        ]
        let result = UsageMonitor.parseCopilotResponse(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.usedPercent, 100.0)
        XCTAssertEqual(result?.overageCount, 15)
    }

    func testParseCopilotResponseMissingQuotaSnapshots() {
        let json: [String: Any] = ["other": "data"]
        let result = UsageMonitor.parseCopilotResponse(json)
        XCTAssertNil(result)
    }

    func testParseCopilotResponseMissingPremium() {
        let json: [String: Any] = ["quota_snapshots": [:]]
        let result = UsageMonitor.parseCopilotResponse(json)
        XCTAssertNil(result)
    }

    func testParseCopilotResponseZeroRemaining() {
        let json: [String: Any] = [
            "quota_snapshots": [
                "premium_interactions": [
                    "percent_remaining": 0.0,
                    "overage_count": 0,
                ],
            ],
        ]
        let result = UsageMonitor.parseCopilotResponse(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.usedPercent, 100.0)
    }

    func testQuotaWindowsRemainIndependentAndClampUtilization() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
            try UsageMonitor.upsertQuotaWindow(
                in: db, toolId: "claude-code", windowId: "5h",
                utilization: 120, limitStatus: "limited", resetAt: 100,
                windowSeconds: 18_000, updatedAt: 10)
            try UsageMonitor.upsertQuotaWindow(
                in: db, toolId: "claude-code", windowId: "7d",
                utilization: 40, limitStatus: "normal", resetAt: 200,
                windowSeconds: 604_800, updatedAt: 11)

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT window_id, utilization FROM quota_window_status
                    WHERE tool_id = 'claude-code' ORDER BY window_id
                    """)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0]["utilization"] as Double?, 100)
            XCTAssertEqual(rows[1]["utilization"] as Double?, 40)
        }
    }
}
