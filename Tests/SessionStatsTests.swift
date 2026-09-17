import XCTest
@testable import AIPulse

final class SessionStatsTests: XCTestCase {
    func testGroupSessionsSortsByObservedTokensDesc() {
        let rows = [
            SessionRow(source: "codex", sessionId: "a", title: nil, repo: "/r1", firstTs: 1, lastTs: 2, lastInput: 100, windowTokens: nil, observedTokens: 500),
            SessionRow(source: "codex", sessionId: "b", title: nil, repo: nil, firstTs: 1, lastTs: 2, lastInput: 100, windowTokens: nil, observedTokens: 200),
            SessionRow(source: "codex", sessionId: "c", title: nil, repo: "/r1", firstTs: 1, lastTs: 2, lastInput: 100, windowTokens: nil, observedTokens: 300),
        ]
        let groups = SessionStats.groupSessions(rows)
        XCTAssertEqual(groups.map(\.repo), ["/r1", SessionStats.noRepoKey])
        XCTAssertEqual(groups[0].sessions.map(\.sessionId), ["a", "c"])
        XCTAssertEqual(groups[0].observedTokens, 800)
        XCTAssertEqual(groups[1].observedTokens, 200)
    }

    func testSameNamedRepositoriesAndCrossSourceSessionIDsDoNotMergeIdentity() {
        let rows = [
            SessionRow(source: "codex", sessionId: "same", title: nil, repo: "/a/project",
                       firstTs: 1, lastTs: 2, lastInput: 0, windowTokens: nil),
            SessionRow(source: "claude-code", sessionId: "same", title: nil, repo: "/b/project",
                       firstTs: 1, lastTs: 2, lastInput: 0, windowTokens: nil)
        ]
        XCTAssertNotEqual(rows[0].id, rows[1].id)
        XCTAssertEqual(SessionStats.groupSessions(rows).map(\.repo), ["/a/project", "/b/project"])
    }

    func testCompactionMarks() {
        let turns = [
            TurnPoint(index: 1, ts: 1, inputTokens: 100, cacheTokens: 10, outTokens: 5, contextTokens: 110),
            TurnPoint(index: 2, ts: 2, inputTokens: 120, cacheTokens: 20, outTokens: 5, contextTokens: 140),
            TurnPoint(index: 3, ts: 3, inputTokens: 60, cacheTokens: 10, outTokens: 5, contextTokens: 70),
            TurnPoint(index: 4, ts: 4, inputTokens: 70, cacheTokens: 15, outTokens: 5, contextTokens: 85),
        ]
        XCTAssertEqual(SessionStats.compactionMarks(turns), [3])
    }


    func testContextTrendOccupancy() {
        let turns = [
            TurnPoint(index: 1, ts: 1, inputTokens: 100, cacheTokens: 10, outTokens: 5, contextTokens: 110),
            TurnPoint(index: 2, ts: 2, inputTokens: 140, cacheTokens: 20, outTokens: 5, contextTokens: 160),
        ]
        let trend = ContextTrend(turns: turns, windowTokens: 200, model: nil)
        XCTAssertEqual(trend.finalOccupancy ?? -1, 0.8, accuracy: 0.001)
        XCTAssertFalse(trend.needsCompactionHint) // 0.8 不触发
        let nearFull = ContextTrend(
            turns: [TurnPoint(index: 1, ts: 1, inputTokens: 152, cacheTokens: 10, outTokens: 5, contextTokens: 162)],
            windowTokens: 200, model: nil)
        XCTAssertTrue(nearFull.needsCompactionHint) // 0.81 > 0.8 触发
    }

    func testContextLikeDetection() {
        let mono = [100, 120, 130, 150].enumerated().map {
            TurnPoint(index: $0.offset + 1, ts: $0.offset, inputTokens: $0.element, cacheTokens: 0, outTokens: 0, contextTokens: $0.element)
        }
        XCTAssertTrue(ContextTrend(turns: mono, windowTokens: 1000, model: nil).isContextLike)

        let noisy = [100, 50, 120, 60, 130, 70].enumerated().map {
            TurnPoint(index: $0.offset + 1, ts: $0.offset, inputTokens: $0.element, cacheTokens: 0, outTokens: 0, contextTokens: $0.element)
        }
        XCTAssertFalse(ContextTrend(turns: noisy, windowTokens: 1000, model: nil).isContextLike)

        XCTAssertFalse(ContextTrend(turns: Array(mono.prefix(2)), windowTokens: 1000, model: nil).isContextLike)
    }

    func testSessionMetricsComputesProfile() {
        let turns = [
            TurnPoint(index: 0, ts: 1, inputTokens: 50, cacheTokens: 40, outTokens: 10, contextTokens: 50),
            TurnPoint(index: 1, ts: 2, inputTokens: 100, cacheTokens: 90, outTokens: 20, contextTokens: 100),
            // context 100 → 60 (< 70%) is marked as a compaction
            TurnPoint(index: 2, ts: 3, inputTokens: 60, cacheTokens: 50, outTokens: 30, contextTokens: 60),
        ]
        let m = SessionStats.metrics(turns: turns, windowTokens: 200)
        XCTAssertEqual(m.turnCount, 3)
        XCTAssertEqual(m.avgOccupancy ?? -1, (50 + 100 + 60) / Double(3 * 200), accuracy: 0.0001)
        XCTAssertEqual(m.avgCacheRatio ?? -1, (40.0 / 50 + 90.0 / 100 + 50.0 / 60) / 3, accuracy: 0.0001)
        XCTAssertEqual(m.compactionCount, 1)
    }

    func testSessionMetricsEmptyAndNilWindow() {
        let m = SessionStats.metrics(turns: [], windowTokens: nil)
        XCTAssertEqual(m.turnCount, 0)
        XCTAssertNil(m.avgOccupancy)
        XCTAssertNil(m.avgCacheRatio)
        XCTAssertEqual(m.compactionCount, 0)
    }

    func testMetricsDoesNotOverflowWithHugeWindow() {
        let turns = [
            TurnPoint(index: 0, ts: 1, inputTokens: 10, cacheTokens: 0, outTokens: 0, contextTokens: 10),
            TurnPoint(index: 1, ts: 2, inputTokens: 10, cacheTokens: 0, outTokens: 0, contextTokens: 10),
        ]
        // Int.max * turnCount previously overflowed (and trapped) before the
        // Double-based denominator fix.
        let m = SessionStats.metrics(turns: turns, windowTokens: Int.max)
        XCTAssertEqual(m.avgOccupancy ?? -1, 0, accuracy: 0.0001)
    }

}
