#if DEBUG
import Foundation
import AIPulseShared

enum PhonePreviewData {
    static func install(on cloud: CloudDataService) {
        let now = Date()
        var snapshots: [String: DashboardSnapshot] = [:]
        for kind in DashboardPeriodKind.allCases {
            let period = DashboardPeriod(kind: kind, now: now)
            let multiplier: Int64 = kind == .today ? 1 : kind == .week ? 5 : 22
            var snap = DashboardSnapshot(todayTokens: 2_450_000 * multiplier,
                activityCoverage: ActivityCoverage(observedEvents: 24 * multiplier, incompleteEvents: 0),
                observedSpend: [ObservedSpendItem(providerId: "Preview API", amount: 1.28, currency: "USD", convertedUSD: nil, observedAt: now.timeIntervalSince1970)],
                declaredMonthlyCostUSD: 40,
                toolBreakdown: [ToolActivityItem(toolId: "codex", name: "Codex", tokens: 1_900_000 * multiplier), ToolActivityItem(toolId: "claude", name: "Claude", tokens: 400_000 * multiplier), ToolActivityItem(toolId: "cursor", name: "Cursor", tokens: 150_000 * multiplier)],
                topRepos: [RepoItem(repoPath: "/Projects/ai-pulse", name: "AI Pulse", added: 240 * Int(multiplier), deleted: 65 * Int(multiplier)), RepoItem(repoPath: "/Projects/website", name: "Website", added: 82 * Int(multiplier), deleted: 14 * Int(multiplier))],
                modelBreakdown: [ModelActivityItem(model: "Preview model", providerId: "preview", tokens: 2_450_000 * multiplier, calls: 24)],
                payloadVersion: CKSchema.payloadVersion, writerAppVersion: "2.0 preview", updatedAt: now)
            snap.period = period
            snap.tokenComposition = TokenComposition(nonCachedInput: 20_000 * multiplier, cachedInput: 2_400_000 * multiplier, output: 30_000 * multiplier)
            for i in 0..<period.displaySlots {
                let date = period.start.addingTimeInterval(Double(i) * (period.isHourly ? 3600 : 86400))
                guard date < period.end, date <= now else { continue }
                let value = Int64((i * 17 + 9) % 13) * 7_000
                snap.dailyStats.append(TrendPoint(ts: date.timeIntervalSince1970, value: Double(value), calls: 1, tokens: value, netLines: 0))
                snap.codeChanges.append(TrendPoint(ts: date.timeIntervalSince1970, value: 0, calls: 0, tokens: 0, netLines: 0, added: (i * 7) % 40, deleted: (i * 3) % 12))
            }
            snapshots[kind.rawValue] = snap
        }
        let pulse = PulseSnapshot(tier: .active, primarySignal: .activity, reason: "Preview observation", signals: [], asOf: now, validUntil: now.addingTimeInterval(1800), activityFacts: PulseActivityFacts(recentTokens: 45_000, todayTokens: 2_450_000))
        cloud.installPreview(snapshots: snapshots, pulse: CurrentPulseEnvelope(pulse: pulse, writerAppVersion: "2.0 preview", generatedAt: now))
    }
}
#endif
