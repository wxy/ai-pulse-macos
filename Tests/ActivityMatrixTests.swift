import XCTest
import GRDB
import AIPulseShared
@testable import AIPulse

final class ActivityMatrixTests: XCTestCase {
    func testRealQueryKeepsMissingModelAndUsesHalfOpenPeriodBounds() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            for (index, ts) in [99, 100, 199, 200].enumerated() {
                let event = UsageEvent(ts: ts, source: "aider", model: nil,
                                       inTokens: 10, outTokens: 2, cacheTokens: 0,
                                       repoPath: nil, sessionId: nil, dedupeKey: "bound-\(index)")
                _ = try LogWatcher.persistObservedEvents(in: db, rows: [(event, "deepseek")], nowMs: 200)
            }
            let rows = try StatsService.modelActivity(in: db, sinceMs: 100, beforeMs: 200)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.model, "")
            XCTAssertEqual(rows.first?.tokens, 24)
            XCTAssertEqual(rows.first?.calls, 2)
        }
    }

    func testDuplicatesSumWithoutMergingProvidersOrDroppingUnknowns() {
        let rows = [
            ModelActivityItem(model: "same", providerId: "a", toolId: "tool", tokens: 10, calls: 1),
            ModelActivityItem(model: "same", providerId: "a", toolId: "tool", tokens: 20, calls: 1),
            ModelActivityItem(model: "same", providerId: "b", toolId: "tool", tokens: 40, calls: 1),
            ModelActivityItem(model: "", providerId: "unknown", tokens: 5, calls: 1)
        ]
        let matrix = ActivityMatrix(rows)
        XCTAssertEqual(matrix.models.count, 3)
        XCTAssertEqual(matrix.tokens(model: .init(provider: "a", model: "same"), tool: "tool"), 30)
        XCTAssertEqual(matrix.tokens(model: .init(provider: "b", model: "same"), tool: "tool"), 40)
        XCTAssertEqual(matrix.tokens(tool: ""), 5)
        XCTAssertEqual(matrix.grandTotal, 75)
        XCTAssertEqual(matrix.tools.reduce(0) { $0 + matrix.tokens(tool: $1) }, matrix.grandTotal)
        XCTAssertEqual(matrix.models.reduce(0) { $0 + matrix.tokens(model: $1) }, matrix.grandTotal)
    }

    func testNoSilentTruncationAndEqualTotalsHaveStableOrdering() {
        let rows = (0..<12).map {
            ModelActivityItem(model: "model-\($0)", providerId: "p", toolId: "tool-\($0)", tokens: 10, calls: 1)
        }
        let matrix = ActivityMatrix(rows)
        let reversed = ActivityMatrix(Array(rows.reversed()))
        XCTAssertEqual(matrix.models.count, 12)
        XCTAssertEqual(matrix.tools.count, 12)
        XCTAssertEqual(matrix.models, reversed.models)
        XCTAssertEqual(matrix.tools, reversed.tools)
        XCTAssertEqual(matrix.grandTotal, 120)
        for model in matrix.models {
            XCTAssertEqual(matrix.tools.reduce(0) { $0 + matrix.tokens(model: model, tool: $1) },
                           matrix.tokens(model: model))
        }
    }
}
