import Foundation
import AIPulseShared

/// Deterministic fictional activity, never a price estimate or account balance.
enum DemoData {
    private static let manualKey = "demo_mode_manual"
    private static let suppressedKey = "demo_mode_suppressed"

    static var isManual: Bool {
        get { UserDefaults.standard.bool(forKey: manualKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: manualKey)
            if newValue { UserDefaults.standard.set(false, forKey: suppressedKey) }
        }
    }

    static var isSuppressed: Bool {
        get { UserDefaults.standard.bool(forKey: suppressedKey) }
        set { UserDefaults.standard.set(newValue, forKey: suppressedKey) }
    }

    static var isActive: Bool {
        if isManual { return true }
        if isSuppressed { return false }
        return IntegrationRegistry.activeCostSources().isEmpty
            && IntegrationRegistry.all.allSatisfy { IntegrationRegistry.config(for: $0.id).enabled == false }
    }

    struct RangeData {
        let period: DashboardPeriod
        let observedAt: Date
        let dailyStats: [DailyStat]
        let codeChanges: [DailyCodeChange]
        let repos: [RepoItem]
        let toolActivities: [ToolActivityItem]
        let modelActivities: [ModelActivityItem]
        let periodCalls: Int
        let periodTokens: Int
        let periodSessions: Int64
    }

    /// Generate the same hourly facts for every range, then aggregate using
    /// local calendar boundaries. No frozen launch date or future observations.
    static func data(for timeRange: TimeRange, now: Date = Date(),
                     calendar: Calendar = .current) -> RangeData {
        let period = DashboardPeriod(kind: timeRange.periodKind, now: now, calendar: calendar)
        var activity: [Date: (calls: Int, tokens: Int)] = [:]
        var output: [Date: (added: Int, deleted: Int, commits: Int)] = [:]
        var cursor = period.start
        var sessions: Int64 = 0
        while cursor <= now && cursor < period.end {
            let hour = calendar.component(.hour, from: cursor)
            let day = calendar.ordinality(of: .day, in: .era, for: cursor) ?? 1
            if (8...20).contains(hour) {
                let seed = (day + hour * 7) % 23
                let tokens = 12_000 + seed * 1_300
                let calls = 3 + seed % 5
                let key = period.isHourly ? cursor : calendar.startOfDay(for: cursor)
                activity[key, default: (0, 0)].calls += calls
                activity[key, default: (0, 0)].tokens += tokens
                // Commits are their own signal, not inferred from changed lines.
                let commits = hour % 4 == 0 ? 1 : 0
                let added = seed % 6 == 0 ? 0 : 20 + seed * 9
                let deleted = seed % 6 == 0 ? 0 : 5 + seed * 3
                output[key, default: (0, 0, 0)].added += added
                output[key, default: (0, 0, 0)].deleted += deleted
                output[key, default: (0, 0, 0)].commits += commits
                sessions += 1
            }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        let stats = activity.keys.sorted().map { date in
            DailyStat(date: date, calls: activity[date]!.calls,
                      tokens: activity[date]!.tokens,
                      netLines: (output[date]?.added ?? 0) - (output[date]?.deleted ?? 0))
        }
        let changes = output.keys.sorted().map { date in
            DailyCodeChange(date: date, added: output[date]!.added,
                            deleted: output[date]!.deleted, commits: output[date]!.commits)
        }
        let calls = stats.reduce(0) { $0 + $1.calls }
        let tokens = stats.reduce(0) { $0 + $1.tokens }
        let added = changes.reduce(0) { $0 + $1.added }
        let deleted = changes.reduce(0) { $0 + $1.deleted }
        let commits = changes.reduce(0) { $0 + $1.commits }
        func parts(_ value: Int) -> [Int] {
            let first = value / 2
            let second = value / 3
            return [first, second, value - first - second]
        }
        let tokenParts = parts(tokens), callParts = parts(calls)
        let addedParts = parts(added), deletedParts = parts(deleted), commitParts = parts(commits)
        let sources = [
            ("claude-code", "Claude Code", "anthropic", "claude-sonnet-4"),
            ("codex", "Codex", "openai", "gpt-5"),
            ("aider", "aider", "deepseek", "deepseek-chat")
        ]
        let tools = sources.enumerated().map { index, source in
            ToolActivityItem(toolId: source.0, name: source.1,
                             tokens: Int64(tokenParts[index]), calls: callParts[index])
        }
        let models = sources.enumerated().map { index, source in
            ModelActivityItem(model: source.3, providerId: source.2, toolId: source.0,
                              tokens: Int64(tokenParts[index]), calls: callParts[index])
        }
        let names = ["ai-pulse-macos", "xingyu.wang", "open-source-lib"]
        let repoFacts: [RepoItem] = names.enumerated().map { index, name -> RepoItem in
            RepoItem(repoPath: "/demo/" + name, name: name,
                     added: addedParts[index], deleted: deletedParts[index],
                     tokens: Int64(tokenParts[index]), commits: commitParts[index])
        }
        let repos = repoFacts.filter { repo in
            let hasActivity = (repo.tokens ?? 0) > 0
            let hasOutput = repo.added > 0 || repo.deleted > 0 || repo.commits > 0
            return hasActivity || hasOutput
        }
        return RangeData(period: period, observedAt: now, dailyStats: stats, codeChanges: changes,
                         repos: repos, toolActivities: tools, modelActivities: models,
                         periodCalls: calls, periodTokens: tokens, periodSessions: sessions)
    }

    static func snapshot(_ data: RangeData) -> DashboardSnapshot {
        var snapshot = DashboardSnapshot(
            todayCalls: Int64(data.periodCalls), todayTokens: Int64(data.periodTokens),
            activityCoverage: ActivityCoverage(observedEvents: Int64(data.periodCalls), incompleteEvents: 0),
            toolBreakdown: data.toolActivities, topRepos: data.repos,
            dailyStats: data.dailyStats.map {
                TrendPoint(ts: $0.date.timeIntervalSince1970, value: Double($0.tokens),
                           calls: Int64($0.calls), tokens: Int64($0.tokens), netLines: $0.netLines)
            },
            codeChanges: data.codeChanges.map {
                TrendPoint(ts: $0.date.timeIntervalSince1970, value: Double($0.added),
                           calls: 0, tokens: 0, netLines: $0.added - $0.deleted,
                           added: $0.added, deleted: $0.deleted, commits: $0.commits)
            }, modelBreakdown: data.modelActivities, updatedAt: data.observedAt)
        snapshot.period = data.period
        snapshot.periodSessions = data.periodSessions
        return snapshot.sanitized()
    }
}
