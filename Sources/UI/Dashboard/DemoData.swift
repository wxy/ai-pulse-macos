import Foundation

/// Pre-generated sample data shown when no integrations are configured.
/// Gives reviewers and new users a realistic preview of the Dashboard.
enum DemoData {

    // MARK: - Detection

    private static let manualKey = "demo_mode_manual"

    /// User can force demo mode from the welcome page or Window menu.
    static var isManual: Bool {
        get { UserDefaults.standard.bool(forKey: manualKey) }
        set { UserDefaults.standard.set(newValue, forKey: manualKey) }
    }

    /// True when demo should be active: either user requested it manually,
    /// or no integrations are configured (auto-detect).
    static var isActive: Bool {
        isManual || (
            IntegrationRegistry.activeCostSources().isEmpty
            && IntegrationRegistry.all.allSatisfy { IntegrationRegistry.config(for: $0.id).enabled == false }
        )
    }

    // MARK: - Dates

    private static let cal: Calendar = {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }()

    static let today = cal.startOfDay(for: Date())

    /// Generate a date offset from today.
    private static func day(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: today) ?? today
    }

    // MARK: - Daily Stats (30 days)

    /// Realistic 30-day spend pattern: higher on weekdays, lower on weekends.
    static let dailyStats: [DailyStat] = {
        (0..<30).reversed().map { i in
            let d = day(-i)
            let wd = cal.component(.weekday, from: d)
            let isWeekend = wd == 1 || wd == 7
            let base = isWeekend ? Double.random(in: 2...8) : Double.random(in: 8...28)
            let cost = round(base * 100) / 100
            let calls = Int(cost * 1.8) + Int.random(in: 0...5)
            let tokens = Int(cost * 4200)
            let netLines = Int(cost * 9) + Int.random(in: -20...20)
            return DailyStat(date: d, cost: cost, calls: calls, tokens: tokens,
                             netLines: netLines, costPerLine: netLines > 0 ? cost * 1000 / Double(netLines) : 0)
        }
    }()

    // MARK: - Provider Daily Costs

    static let providerCosts: [ProviderDailyCost] = {
        let providers: [(String, Double)] = [("openai", 0.40), ("anthropic", 0.35), ("deepseek", 0.25)]
        var result: [ProviderDailyCost] = []
        for i in (0..<30).reversed() {
            let d = day(-i)
            let wd = cal.component(.weekday, from: d)
            let isWeekend = wd == 1 || wd == 7
            for (pid, share) in providers {
                let base = isWeekend ? Double.random(in: 0.5...3) : Double.random(in: 3...12)
                let cost = round(base * share * 100) / 100
                if cost > 0.01 {
                    result.append(ProviderDailyCost(date: d, providerId: pid, cost: cost))
                }
            }
        }
        return result
    }()

    // MARK: - Daily Code Changes

    static let codeChanges: [DailyCodeChange] = {
        (0..<30).reversed().map { i in
            let d = day(-i)
            let wd = cal.component(.weekday, from: d)
            let isWeekend = wd == 1 || wd == 7
            let added = isWeekend ? Int.random(in: 0...80) : Int.random(in: 50...400)
            let deleted = isWeekend ? Int.random(in: 0...40) : Int.random(in: 20...180)
            return DailyCodeChange(date: d, added: added, deleted: deleted)
        }
    }()

    // MARK: - Repo Breakdown

    static let repos: [RepoBreakdown] = {
        let repoData: [(repo: String, cost: Double, added: Int, deleted: Int, apiSources: [(String, Double)], subSources: [(String, Double)])] = [
            ("ai-pulse-macos", 168.0, 4520, 1280,
             [("Claude Code", 2.85), ("aider", 3.72)],
             [("Cursor Pro", 1.14)]),
            ("xingyu.wang", 112.0, 3240, 940,
             [("Claude Code", 3.21)],
             [("Cursor Pro", 0.93)]),
            ("open-source-lib", 48.0, 1680, 520,
             [("aider", 4.15)],
             []),
        ]
        return repoData.map { r in
            RepoBreakdown(
                repo: r.repo, cost: r.cost, added: r.added, deleted: r.deleted,
                apiSources: r.apiSources.map { CPLSource(label: $0.0, cpl: $0.1) },
                subscriptionSources: r.subSources.map { CPLSource(label: $0.0, cpl: $0.1) }
            )
        }
    }()

    // MARK: - Prediction

    static let prediction: Prediction = {
        let monthSoFar = round(dailyStats.reduce(0) { $0 + $1.cost } * 100) / 100
        let dailyRate = round(monthSoFar / max(Double(max(1, cal.component(.day, from: today))), 1) * 100) / 100
        let daysInMonth = cal.range(of: .day, in: .month, for: today)?.count ?? 30
        let daysRemaining = daysInMonth - cal.component(.day, from: today)
        return Prediction(
            monthProjected: round((monthSoFar + dailyRate * Double(daysRemaining)) * 100) / 100,
            dailyRate: dailyRate, daysRemaining: daysRemaining, monthSoFar: monthSoFar
        )
    }()

    // MARK: - Balance Spend (per-provider aggregated)

    static let balanceSpend: [(providerId: String, name: String, spend: Double)] = [
        ("openai", "OpenAI", round(dailyStats.reduce(0) { $0 + $1.cost } * 0.40 * 100) / 100),
        ("anthropic", "Anthropic", round(dailyStats.reduce(0) { $0 + $1.cost } * 0.35 * 100) / 100),
        ("deepseek", "DeepSeek", round(dailyStats.reduce(0) { $0 + $1.cost } * 0.25 * 100) / 100),
    ]

    static let dailyBalanceSpend: [Date: Double] = {
        var map = [Date: Double]()
        for s in dailyStats {
            map[s.date] = s.cost
        }
        return map
    }()

    // MARK: - Tool Costs

    static let toolCosts: [(name: String, cost: Double)] = [
        ("Claude Code", round(dailyStats.reduce(0) { $0 + $1.cost } * 0.38 * 100) / 100),
        ("aider", round(dailyStats.reduce(0) { $0 + $1.cost } * 0.27 * 100) / 100),
        ("Cursor", round(dailyStats.reduce(0) { $0 + $1.cost } * 0.20 * 100) / 100),
        ("Copilot", round(dailyStats.reduce(0) { $0 + $1.cost } * 0.10 * 100) / 100),
        ("Windsurf", round(dailyStats.reduce(0) { $0 + $1.cost } * 0.05 * 100) / 100),
    ]

    // MARK: - Today stats

    static let todayCalls: Int = dailyStats.last?.calls ?? 12
    static let todayTokens: Int = dailyStats.last?.tokens ?? 52000
    static let yesterdaySpend: Double = {
        let stats = dailyStats
        guard stats.count >= 2 else { return 0 }
        return stats[stats.count - 2].cost
    }()
    static let previousPeriodSpend: Double = round(dailyStats.prefix(15).reduce(0) { $0 + $1.cost } * 100) / 100
}
