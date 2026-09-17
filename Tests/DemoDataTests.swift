import XCTest
import AIPulseShared
@testable import AIPulse

final class DemoDataTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func testAllRangesShareConsistentFactTotalsAndNoFictionalMoney() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 15))!
        for range in [TimeRange.today, .thisWeek, .days30] {
            let data = DemoData.data(for: range, now: now, calendar: calendar)
            let snapshot = DemoData.snapshot(data)
            XCTAssertEqual(snapshot.todayTokens, data.dailyStats.reduce(0) { $0 + Int64($1.tokens) })
            XCTAssertEqual(snapshot.todayTokens, snapshot.modelBreakdown.reduce(0) { $0 + $1.tokens })
            XCTAssertEqual(snapshot.todayTokens, snapshot.toolBreakdown.reduce(0) { $0 + ($1.tokens ?? 0) })
            XCTAssertEqual(snapshot.todayTokens, snapshot.topRepos.reduce(0) { $0 + ($1.tokens ?? 0) })
            XCTAssertEqual(snapshot.todayCalls, snapshot.modelBreakdown.reduce(0) { $0 + Int64($1.calls) })
            XCTAssertEqual(data.codeChanges.reduce(0) { $0 + $1.added }, data.repos.reduce(0) { $0 + $1.added })
            XCTAssertEqual(data.codeChanges.reduce(0) { $0 + $1.deleted }, data.repos.reduce(0) { $0 + $1.deleted })
            XCTAssertEqual(data.codeChanges.reduce(0) { $0 + $1.commits }, data.repos.reduce(0) { $0 + $1.commits })
            XCTAssertTrue(snapshot.providerBreakdown.isEmpty)
            XCTAssertTrue(snapshot.balanceDaily.isEmpty)
            XCTAssertNil(snapshot.observedSpend)
            XCTAssertNil(snapshot.declaredMonthlyCostUSD)
            XCTAssertEqual(snapshot.period, data.period)
            XCTAssertEqual(snapshot.updatedAt, now)
            XCTAssertTrue(data.dailyStats.allSatisfy { $0.date <= now })
            XCTAssertTrue(snapshot.dailyStats.allSatisfy { $0.value == Double($0.tokens) })
        }
        let today = DemoData.data(for: .today, now: now, calendar: calendar)
        let week = DemoData.data(for: .thisWeek, now: now, calendar: calendar)
        let month = DemoData.data(for: .days30, now: now, calendar: calendar)
        XCTAssertLessThan(today.periodTokens, week.periodTokens)
        XCTAssertLessThan(week.periodTokens, month.periodTokens)
        let todayStart = today.period.start
        XCTAssertEqual(today.periodTokens, week.dailyStats.first { $0.date == todayStart }?.tokens)
    }

    func testMidnightDoesNotFreezeLaunchDateOrCreateFutureActivity() {
        let before = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 23))!
        let after = calendar.date(byAdding: .hour, value: 2, to: before)!
        let old = DemoData.data(for: .today, now: before, calendar: calendar)
        let fresh = DemoData.data(for: .today, now: after, calendar: calendar)
        XCTAssertNotEqual(old.period.start, fresh.period.start)
        XCTAssertEqual(fresh.periodCalls, 0)
        XCTAssertEqual(fresh.periodTokens, 0)
        XCTAssertTrue(fresh.dailyStats.isEmpty)
        XCTAssertTrue(fresh.repos.isEmpty)
    }

    func testDailyAndHourlyFactsAgreeOnDSTTransitionDay() {
        for components in [
            DateComponents(year: 2026, month: 3, day: 8, hour: 23),
            DateComponents(year: 2026, month: 11, day: 1, hour: 23)
        ] {
            let now = calendar.date(from: components)!
            let today = DemoData.data(for: .today, now: now, calendar: calendar)
            let month = DemoData.data(for: .days30, now: now, calendar: calendar)
            XCTAssertEqual(today.periodTokens, month.dailyStats.first { $0.date == today.period.start }?.tokens)
            XCTAssertEqual(today.codeChanges.reduce(0) { $0 + $1.commits },
                           month.codeChanges.first { $0.date == today.period.start }?.commits)
            XCTAssertEqual(Set(today.dailyStats.map(\.date)).count, today.dailyStats.count)
        }
    }
}
