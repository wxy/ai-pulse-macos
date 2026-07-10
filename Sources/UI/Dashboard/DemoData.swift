import Foundation

/// Pre-generated sample data shown when no integrations are configured.
/// Deterministic — no random values, consistent between launches.
enum DemoData {

    // MARK: - Detection

    private static let manualKey = "demo_mode_manual"

    static var isManual: Bool {
        get { UserDefaults.standard.bool(forKey: manualKey) }
        set { UserDefaults.standard.set(newValue, forKey: manualKey) }
    }

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

    private static func day(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: today) ?? today
    }

    /// Is this date a weekend (Sat/Sun)?
    private static func isWeekend(_ d: Date) -> Bool {
        let wd = cal.component(.weekday, from: d)
        return wd == 1 || wd == 7
    }

    // MARK: - Raw daily cost (deterministic seed values)

    /// Base daily cost pattern — realistic AI coding spend over 30 days.
    /// Weekday: $8-$24, Weekend: $2-$8, with some natural variation.
    /// Computed from day index to avoid Random.
    private static func dailyBase(offset: Int) -> Double {
        let d = day(offset)
        if isWeekend(d) {
            // Weekend: lighter usage
            let seeds: [Double] = [2.40, 3.10, 5.80, 7.20, 1.90, 4.50, 3.70, 6.10]
            return seeds[abs(offset) % seeds.count]
        } else {
            // Weekday: normal workday pattern
            let seeds: [Double] = [12.50, 18.30, 9.80, 22.10, 15.70, 14.20, 8.90,
                                   19.40, 11.30, 24.00, 17.60, 13.80, 10.50, 21.20,
                                   16.40, 8.10, 14.90, 19.70, 12.10, 23.50, 18.80, 15.30]
            return seeds[abs(offset) % seeds.count]
        }
    }

    // MARK: - Daily Stats (30 days)

    static let dailyStats: [DailyStat] = {
        (0..<30).reversed().map { i in
            let d = day(-i)
            let cost = dailyBase(offset: -i)
            let calls = max(1, Int(cost * 1.5))
            let tokens = Int(cost * 4200)
            let baseLines = Int(cost * 9)
            let netLines = isWeekend(d) ? baseLines / 3 : baseLines
            return DailyStat(date: d, cost: cost, calls: calls, tokens: tokens,
                             netLines: netLines,
                             costPerLine: netLines > 0 ? cost * 1000 / Double(max(netLines, 1)) : 0)
        }
    }()

    // MARK: - Provider Distributed Costs

    /// Provider shares: Anthropic 38%, OpenAI 33%, DeepSeek 29%
    private static let providerShares: [(String, Double)] = [
        ("anthropic", 0.38), ("openai", 0.33), ("deepseek", 0.29),
    ]

    private static let providerNames: [String: String] = [
        "anthropic": "Anthropic", "openai": "OpenAI", "deepseek": "DeepSeek",
    ]

    static let providerCosts: [ProviderDailyCost] = {
        var result: [ProviderDailyCost] = []
        for i in (0..<30).reversed() {
            let d = day(-i)
            let total = dailyBase(offset: -i)
            for (pid, share) in providerShares {
                let cost = (total * share * 100).rounded() / 100
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
            let base = dailyBase(offset: -i)
            let added = Int(base * 14) + (isWeekend(d) ? 0 : Int(base * 3))
            let deleted = Int(base * 5) + (isWeekend(d) ? 0 : Int(base))
            return DailyCodeChange(date: d, added: max(0, added), deleted: max(0, deleted))
        }
    }()

    // MARK: - Repo Breakdown

    static let repos: [RepoBreakdown] = {
        let repoData: [(repo: String, cost: Double, added: Int, deleted: Int, apiSources: [(String, Double)], subSources: [(String, Double)])] = [
            ("ai-pulse-macos", 172.0, 4580, 1320,
             [("Claude Code", 2.85), ("aider", 3.72)],
             [("Cursor Pro", 1.14)]),
            ("xingyu.wang", 118.0, 3380, 1020,
             [("Claude Code", 3.21)],
             [("Cursor Pro", 0.93)]),
            ("open-source-lib", 52.0, 1820, 560,
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
        let monthSoFar = (dailyStats.reduce(0) { $0 + $1.cost } * 100).rounded() / 100
        let elapsed = max(1, cal.component(.day, from: today))
        let dailyRate = (monthSoFar / Double(elapsed) * 100).rounded() / 100
        let daysInMonth = cal.range(of: .day, in: .month, for: today)?.count ?? 30
        let daysRemaining = daysInMonth - elapsed
        return Prediction(
            monthProjected: (monthSoFar + dailyRate * Double(daysRemaining) * 100).rounded() / 100,
            dailyRate: dailyRate, daysRemaining: daysRemaining, monthSoFar: monthSoFar
        )
    }()

    // MARK: - Balance Spend (per-provider aggregated, full 30d)

    static let balanceSpend: [(providerId: String, name: String, spend: Double)] = {
        var totals: [String: Double] = [:]
        for pc in providerCosts {
            totals[pc.providerId, default: 0] += pc.cost
        }
        return totals.compactMap { (pid, spend) in
            guard spend > 0.01, let name = providerNames[pid] else { return nil }
            return (providerId: pid, name: name, spend: (spend * 100).rounded() / 100)
        }.sorted { $0.spend > $1.spend }
    }()

    static let dailyBalanceSpend: [Date: Double] = {
        var map = [Date: Double]()
        for s in dailyStats { map[s.date] = s.cost }
        return map
    }()

    // MARK: - Tool Costs (full 30d)

    /// Tool distribution: Claude Code 36%, aider 27%, Cursor 19%, Copilot 12%, Windsurf 6%
    private static let toolShares: [(String, Double)] = [
        ("Claude Code", 0.36), ("aider", 0.27), ("Cursor", 0.19),
        ("Copilot", 0.12), ("Windsurf", 0.06),
    ]

    static let toolCosts: [(name: String, cost: Double)] = {
        let totalCost = dailyStats.reduce(0.0) { $0 + $1.cost }
        return toolShares.map { (name, share) in
            (name: name, cost: (totalCost * share * 100).rounded() / 100)
        }
    }()

    // MARK: - Convenience: today stats

    static let todayStat: DailyStat? = dailyStats.last
    static let yesterdayStat: DailyStat? = dailyStats.count >= 2 ? dailyStats[dailyStats.count - 2] : nil
}
