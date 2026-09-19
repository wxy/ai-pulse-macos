import XCTest
import AIPulseShared

final class WatchDashboardDataTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func history(_ samples: Int) -> DashboardSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var snapshot = DashboardSnapshot(payloadVersion: CKSchema.payloadVersion)
        snapshot.period = DashboardPeriod(kind: .days30, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        snapshot.dailyStats = (1...samples).map { day in
            TrendPoint(ts: calendar.date(byAdding: .day, value: -day, to: today)!.timeIntervalSince1970,
                       value: 0, calls: 1, tokens: Int64(day * 100), netLines: 0)
        }
        return snapshot
    }
    func testMedianExcludesTodayAndMissingDays() {
        var snapshot = history(7)
        snapshot.dailyStats.append(TrendPoint(ts: now.timeIntervalSince1970, value: 0, calls: 1, tokens: 999999, netLines: 0))
        snapshot.dailyStats.append(TrendPoint(ts: now.addingTimeInterval(-2 * 86400).timeIntervalSince1970, value: 0, calls: 0, tokens: 0, netLines: 0))
        XCTAssertEqual(WatchDashboardData.baseline(snapshot, tokens: true, now: now), 400)
    }
    func testInsufficientAndFailedHistoryHasNoBaseline() {
        XCTAssertNil(WatchDashboardData.baseline(history(6), tokens: true, now: now))
        var snapshot = history(7)
        snapshot.readFailures = ["dashboardUsageStats"]
        XCTAssertNil(WatchDashboardData.baseline(snapshot, tokens: true, now: now))
    }
    func testCodeBaselineCountsAddedAndDeleted() {
        var snapshot = history(8)
        snapshot.codeChanges = snapshot.dailyStats.map { TrendPoint(ts: $0.ts, value: 0, calls: 0, tokens: 0, netLines: 1, added: 2, deleted: 1) }
        XCTAssertEqual(WatchDashboardData.baseline(snapshot, tokens: false, now: now), 3)
    }
    func testMultipleLapsAndIntegerLaps() {
        XCTAssertEqual(WatchDashboardData.remainingArc(2.4), 0.4, accuracy: 0.00001)
        XCTAssertEqual(WatchDashboardData.remainingArc(3), 0)
        XCTAssertEqual(WatchDashboardData.remainingArc(0.8), 0.8)
        XCTAssertEqual(WatchDashboardData.remainingArc(.infinity), 0)
        XCTAssertNil(WatchDashboardData.ratio(value: 1, baseline: 0))
        XCTAssertNil(WatchDashboardData.ratio(value: nil, baseline: 100))
    }
    func testIntensityUsesRealSignalAndExpires() {
        let signal = PulseSignal(kind: .activity, rawValue: 100, unit: "tokens", baseline: 50,
                                 normalized: 1.5, freshness: .fresh, completeness: .complete, observedAt: now, reason: "activity")
        let pulse = PulseSnapshot(tier: .elevated, primarySignal: .activity, reason: "activity", signals: [signal], asOf: now)
        XCTAssertEqual(WatchDashboardData.intensity(pulse, now: now), 0.5)
        XCTAssertNil(WatchDashboardData.intensity(pulse, now: now.addingTimeInterval(60)))
        XCTAssertNil(WatchDashboardData.intensity(nil, now: now))
    }
    func testSummaryFreshnessAllowsPublishDelayButRejectsStaleOrFutureData() {
        var snapshot = history(7)
        snapshot.updatedAt = now.addingTimeInterval(-WatchDashboardData.summaryFreshnessInterval)
        XCTAssertTrue(WatchDashboardData.isSummaryFresh(snapshot, now: now))
        snapshot.updatedAt = snapshot.updatedAt.addingTimeInterval(-1)
        XCTAssertFalse(WatchDashboardData.isSummaryFresh(snapshot, now: now))
        snapshot.updatedAt = now.addingTimeInterval(61)
        XCTAssertFalse(WatchDashboardData.isSummaryFresh(snapshot, now: now))
        XCTAssertFalse(WatchDashboardData.isSummaryFresh(nil, now: now))
    }

    func testExpiredPulseRetainsItsLastObservedIntensityForWidgetPresentation() {
        let signal = PulseSignal(kind: .activity, rawValue: 100, unit: "tokens", baseline: 50,
                                 normalized: 1.5, freshness: .fresh, completeness: .complete,
                                 observedAt: now, reason: "activity")
        let pulse = PulseSnapshot(tier: .active, primarySignal: .activity, reason: "activity",
                                  signals: [signal], asOf: now,
                                  validUntil: now.addingTimeInterval(-1))
        XCTAssertNil(WatchDashboardData.intensity(pulse, now: now))
        XCTAssertEqual(WatchDashboardData.observedIntensity(pulse), 0.5)
    }

    func testTimelineTransitionsAtPulseExpiryAndSummaryStaleness() {
        var snapshot = history(7)
        snapshot.updatedAt = now.addingTimeInterval(-600)
        let signal = PulseSignal(kind: .activity, rawValue: 100, unit: "tokens", baseline: 50,
                                 normalized: 1.5, freshness: .fresh, completeness: .complete,
                                 observedAt: now, reason: "activity")
        let pulse = PulseSnapshot(tier: .active, primarySignal: .activity, reason: "activity",
                                  signals: [signal], asOf: now,
                                  validUntil: now.addingTimeInterval(300))
        let dates = WatchDashboardData.timelineTransitionDates(
            todaySnapshot: snapshot,
            pulse: pulse,
            now: now,
            nextRefresh: now.addingTimeInterval(900)
        )
        XCTAssertEqual(dates, [pulse.validUntil, snapshot.updatedAt.addingTimeInterval(901)])
    }

    func testTimelineTransitionsIncludeMidnightAndExcludeRefreshBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let lateNight = calendar.date(from: DateComponents(
            year: 2027, month: 1, day: 15, hour: 23, minute: 55
        ))!
        var snapshot = DashboardSnapshot(payloadVersion: CKSchema.payloadVersion, updatedAt: lateNight)
        snapshot.period = DashboardPeriod(kind: .today, now: lateNight, calendar: calendar)
        let dates = WatchDashboardData.timelineTransitionDates(
            todaySnapshot: snapshot,
            pulse: nil,
            now: lateNight,
            nextRefresh: lateNight.addingTimeInterval(15 * 60)
        )
        XCTAssertEqual(dates, [snapshot.period.end])
        XCTAssertTrue(WatchDashboardData.timelineTransitionDates(
            todaySnapshot: snapshot,
            pulse: nil,
            now: lateNight,
            nextRefresh: lateNight
        ).isEmpty)
    }
}
