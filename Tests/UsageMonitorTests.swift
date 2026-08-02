import XCTest
@testable import AIPulse

final class UsageMonitorTests: XCTestCase {

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
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.utilization5h, 0.0)
        XCTAssertEqual(result?.utilization7d, 0.0)
    }

    func testParseClaudeStatusCacheMaxPicksHigher() {
        let json: [String: Any] = [
            "usageData": [
                "utilization5h": 0.9,
                "utilization7d": 0.3,
                "limitStatus": "allowed_warning",
            ],
        ]
        let result = UsageMonitor.parseClaudeStatusCache(json)
        XCTAssertNotNil(result)
        // UsageMonitor uses max(5h, 7d), verify both values are available
        XCTAssertEqual(result?.utilization5h, 0.9)
        XCTAssertEqual(result?.utilization7d, 0.3)
        let pct = max(result!.utilization5h, result!.utilization7d) * 100
        XCTAssertEqual(pct, 90.0)
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
}
