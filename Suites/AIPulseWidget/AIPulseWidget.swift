import Foundation
import SwiftUI
import WidgetKit
import AIPulseShared

struct Provider: TimelineProvider {
    private static let appGroupIdentifier = "group.com.wxy.aipulse"
    private static let dashboardCacheName = "dashboard_cache.json"
    private static let pulseCacheName = "current_pulse_v2.json"

    func placeholder(in context: Context) -> WidgetEntry {
        Self.previewEntry(at: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : loadLatestEntry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let now = Date()
        let entry = loadLatestEntry(at: now)
        let nextRefresh = now.addingTimeInterval(15 * 60)
        var transitionDates: [Date] = []
        if let validUntil = entry.pulseEnvelope?.pulse?.validUntil,
           validUntil > now, validUntil < nextRefresh {
            transitionDates.append(validUntil.addingTimeInterval(1))
        }
        if let snapshot = entry.todaySnapshot {
            let staleAt = snapshot.updatedAt.addingTimeInterval(
                WatchDashboardData.summaryFreshnessInterval + 1
            )
            if staleAt > now, staleAt < nextRefresh { transitionDates.append(staleAt) }
            if snapshot.period.end > now, snapshot.period.end < nextRefresh {
                transitionDates.append(snapshot.period.end)
            }
        }
        let entries = [entry] + Set(transitionDates).sorted().map(entry.at)
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }

    private func loadLatestEntry(at date: Date) -> WidgetEntry {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            return WidgetEntry(date: date, todaySnapshot: nil, historySnapshot: nil, pulseEnvelope: nil)
        }

        var todaySnapshot: DashboardSnapshot?
        var historySnapshot: DashboardSnapshot?
        let dashboardURL = groupURL.appendingPathComponent(Self.dashboardCacheName)
        if let data = try? Data(contentsOf: dashboardURL),
           let snapshots = try? JSONDecoder().decode([String: DashboardSnapshot].self, from: data) {
            if let today = snapshots["today"], PhoneDashboardData.accepts(today, range: "today"),
               date >= today.period.start, date < today.period.end {
                todaySnapshot = today.sanitized()
            }
            if let history = snapshots["30d"], PhoneDashboardData.accepts(history, range: "30d") {
                historySnapshot = history.sanitized()
            }
        }

        var pulseEnvelope: CurrentPulseEnvelope?
        let pulseURL = groupURL.appendingPathComponent(Self.pulseCacheName)
        if let data = try? Data(contentsOf: pulseURL),
           let envelope = try? JSONDecoder().decode(CurrentPulseEnvelope.self, from: data),
           envelope.payloadVersion == CKSchema.payloadVersion {
            pulseEnvelope = envelope
        }
        return WidgetEntry(date: date, todaySnapshot: todaySnapshot,
                           historySnapshot: historySnapshot, pulseEnvelope: pulseEnvelope)
    }

    static func previewEntry(at date: Date) -> WidgetEntry {
        var today = DashboardSnapshot(
            todayTokens: 2_400_000,
            topRepos: [RepoItem(repoPath: "/preview", name: "Preview",
                                added: 700, deleted: 200, commits: 0)],
            payloadVersion: CKSchema.payloadVersion,
            updatedAt: date
        )
        today.period = DashboardPeriod(kind: .today, now: date)

        var history = DashboardSnapshot(payloadVersion: CKSchema.payloadVersion, updatedAt: date)
        history.period = DashboardPeriod(kind: .days30, now: date)
        let calendar = Calendar.current
        history.dailyStats = (1...10).map { day in
            TrendPoint(
                ts: calendar.date(byAdding: .day, value: -day,
                                  to: calendar.startOfDay(for: date))!.timeIntervalSince1970,
                value: 0, calls: 1, tokens: 1_000_000, netLines: 0
            )
        }
        history.codeChanges = history.dailyStats.map {
            TrendPoint(ts: $0.ts, value: 0, calls: 0, tokens: 0,
                       netLines: 300, added: 200, deleted: 100)
        }

        let signal = PulseSignal(kind: .activity, rawValue: 100, unit: "tokens",
                                 baseline: 50, normalized: 2.4, freshness: .fresh,
                                 completeness: .complete, observedAt: date, reason: "activity")
        let pulse = PulseSnapshot(tier: .elevated, primarySignal: .activity,
                                  reason: "activity", signals: [signal], asOf: date,
                                  validUntil: date.addingTimeInterval(7 * 60))
        return WidgetEntry(
            date: date,
            todaySnapshot: today,
            historySnapshot: history,
            pulseEnvelope: CurrentPulseEnvelope(pulse: pulse, writerAppVersion: "Widget preview", generatedAt: date)
        )
    }
}

struct WidgetEntry: TimelineEntry {
    let date: Date
    let todaySnapshot: DashboardSnapshot?
    let historySnapshot: DashboardSnapshot?
    let pulseEnvelope: CurrentPulseEnvelope?

    func at(_ date: Date) -> WidgetEntry {
        let today = todaySnapshot.flatMap {
            date >= $0.period.start && date < $0.period.end ? $0 : nil
        }
        return WidgetEntry(date: date, todaySnapshot: today,
                           historySnapshot: historySnapshot, pulseEnvelope: pulseEnvelope)
    }
}

struct AIPulseWidget: Widget {
    let kind = "AIPulseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            AIPulseWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Pulse")
        .description("See today's AI coding activity in three rings.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

#if DEBUG
#Preview(as: .systemSmall) {
    AIPulseWidget()
} timeline: {
    Provider.previewEntry(at: .now)
}
#endif