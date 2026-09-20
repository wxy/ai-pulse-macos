import AIPulseShared
import Foundation
import WidgetKit

enum MacWidgetLoadStatus: Equatable {
    case available
    case waitingForRefresh
    case noData
    case failed
}

struct MacWidgetEntry: TimelineEntry {
    let date: Date
    let snapshotWrittenAt: Date?
    let todaySnapshot: DashboardSnapshot?
    let historySnapshot: DashboardSnapshot?
    let pulseEnvelope: CurrentPulseEnvelope?
    let loadStatus: MacWidgetLoadStatus

    func at(_ date: Date) -> MacWidgetEntry {
        let today = todaySnapshot.flatMap {
            date >= $0.period.start && date < $0.period.end ? $0 : nil
        }
        return MacWidgetEntry(
            date: date,
            snapshotWrittenAt: snapshotWrittenAt,
            todaySnapshot: today,
            historySnapshot: historySnapshot,
            pulseEnvelope: pulseEnvelope,
            loadStatus: todaySnapshot != nil && today == nil ? .waitingForRefresh : loadStatus
        )
    }
}

private enum MacWidgetLocalReader {
    static func load(at date: Date) -> MacWidgetEntry {
        let payload: MacWidgetLocalPayload
        do {
            guard let stored = try MacWidgetLocalStore.load() else {
                return emptyEntry(at: date, status: .noData)
            }
            payload = stored
        } catch {
            return emptyEntry(at: date, status: .failed)
        }

        let todaySnapshot = payload.todaySnapshot.flatMap {
            date >= $0.period.start && date < $0.period.end ? $0 : nil
        }
        let hasAnySummary = todaySnapshot != nil || payload.historySnapshot != nil
        var status: MacWidgetLoadStatus = hasAnySummary ? .available : .noData
        if payload.todaySnapshot != nil && todaySnapshot == nil {
            // A snapshot from an earlier day is intentionally not rendered as
            // today's activity. The historical baseline can still be shown.
            status = .waitingForRefresh
        } else if !hasAnySummary {
            status = .noData
        }
        return MacWidgetEntry(
            date: date,
            snapshotWrittenAt: payload.writtenAt,
            todaySnapshot: todaySnapshot,
            historySnapshot: payload.historySnapshot,
            pulseEnvelope: payload.pulseEnvelope,
            loadStatus: status
        )
    }

    private static func emptyEntry(at date: Date, status: MacWidgetLoadStatus) -> MacWidgetEntry {
        MacWidgetEntry(
            date: date,
            snapshotWrittenAt: nil,
            todaySnapshot: nil,
            historySnapshot: nil,
            pulseEnvelope: nil,
            loadStatus: status
        )
    }

}

private struct MacWidgetCompletion<Value>: @unchecked Sendable {
    let call: (Value) -> Void
}

struct MacWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacWidgetEntry {
        Self.previewEntry(at: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (MacWidgetEntry) -> Void) {
        guard !context.isPreview else {
            completion(placeholder(in: context))
            return
        }
        completion(MacWidgetLocalReader.load(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacWidgetEntry>) -> Void) {
        let callback = MacWidgetCompletion(call: completion)
        Task {
            let now = Date()
            let entry = MacWidgetLocalReader.load(at: now)
            let nextRefresh = now.addingTimeInterval(CurrentPulseEnvelope.widgetRefreshInterval)
            let transitionDates = WatchDashboardData.timelineTransitionDates(
                todaySnapshot: entry.todaySnapshot,
                pulse: entry.pulseEnvelope?.pulse,
                now: now,
                nextRefresh: nextRefresh
            )
            let producerTransition = entry.snapshotWrittenAt.map {
                $0.addingTimeInterval(MacWidgetLocalPayload.producerFreshnessInterval + 1)
            }
            let allTransitionDates = Set(transitionDates + [producerTransition].compactMap { $0 })
                .filter { $0 > now && $0 < nextRefresh }
                .sorted()
            callback.call(Timeline(
                entries: [entry] + allTransitionDates.map(entry.at),
                policy: .after(nextRefresh)
            ))
        }
    }

    static func previewEntry(
        at date: Date,
        status: MacWidgetLoadStatus = .available,
        staleSummary: Bool = false,
        expiredPulse: Bool = false
    ) -> MacWidgetEntry {
        guard status == .available else {
            return MacWidgetEntry(
                date: date,
                snapshotWrittenAt: nil,
                todaySnapshot: nil,
                historySnapshot: nil,
                pulseEnvelope: nil,
                loadStatus: status
            )
        }

        var today = DashboardSnapshot(
            todayTokens: 2_400_000,
            topRepos: [RepoItem(
                repoPath: "/preview",
                name: "Preview",
                added: 700,
                deleted: 200,
                commits: 0
            )],
            payloadVersion: CKSchema.payloadVersion,
            updatedAt: staleSummary ? date.addingTimeInterval(-3_600) : date
        )
        today.period = DashboardPeriod(kind: .today, now: date)

        var history = DashboardSnapshot(payloadVersion: CKSchema.payloadVersion, updatedAt: date)
        history.period = DashboardPeriod(kind: .days30, now: date)
        let calendar = Calendar.current
        history.dailyStats = (1...10).map { day in
            TrendPoint(
                ts: calendar.date(
                    byAdding: .day,
                    value: -day,
                    to: calendar.startOfDay(for: date)
                )!.timeIntervalSince1970,
                value: 0,
                calls: 1,
                tokens: 1_000_000,
                netLines: 0
            )
        }
        history.codeChanges = history.dailyStats.map {
            TrendPoint(
                ts: $0.ts,
                value: 0,
                calls: 0,
                tokens: 0,
                netLines: 300,
                added: 200,
                deleted: 100
            )
        }

        let pulseDate = expiredPulse ? date.addingTimeInterval(-10 * 60) : date
        let signal = PulseSignal(
            kind: .activity,
            rawValue: 100,
            unit: "tokens",
            baseline: 50,
            normalized: 2.4,
            freshness: .fresh,
            completeness: .complete,
            observedAt: pulseDate,
            reason: "activity"
        )
        let pulse = PulseSnapshot(
            tier: .elevated,
            primarySignal: .activity,
            reason: "activity",
            signals: [signal],
            asOf: pulseDate,
            validUntil: pulseDate.addingTimeInterval(CurrentPulseEnvelope.cloudValidityInterval)
        )
        return MacWidgetEntry(
            date: date,
            snapshotWrittenAt: staleSummary ? date.addingTimeInterval(-3_600) : date,
            todaySnapshot: today,
            historySnapshot: history,
            pulseEnvelope: CurrentPulseEnvelope(
                pulse: pulse,
                writerAppVersion: "Widget preview",
                generatedAt: pulseDate
            ),
            loadStatus: status
        )
    }
}

struct MacWidgetProjection {
    let entry: MacWidgetEntry

    var todayTokens: Double? {
        guard let snapshot = entry.todaySnapshot,
              !snapshot.readFailures.contains("toolUsage"),
              !snapshot.readFailures.contains("dashboardUsageStats") else { return nil }
        return Double(snapshot.todayTokens)
    }

    var todayLines: Double? {
        guard let snapshot = entry.todaySnapshot,
              !snapshot.readFailures.contains("repositoryCode") else { return nil }
        return snapshot.topRepos.reduce(0) { $0 + Double($1.added) + Double($1.deleted) }
    }

    var tokenRatio: Double? {
        WatchDashboardData.ratio(
            value: todayTokens,
            baseline: WatchDashboardData.baseline(entry.historySnapshot, tokens: true, now: entry.date)
        )
    }

    var lineRatio: Double? {
        WatchDashboardData.ratio(
            value: todayLines,
            baseline: WatchDashboardData.baseline(entry.historySnapshot, tokens: false, now: entry.date)
        )
    }

    var currentPulse: PulseSnapshot? {
        entry.pulseEnvelope?.currentPulse(asOf: entry.date)
    }

    var intensity: Double? {
        WatchDashboardData.intensity(currentPulse, now: entry.date)
    }

    var summaryIsStale: Bool {
        entry.todaySnapshot != nil
            && !WatchDashboardData.isSummaryFresh(entry.todaySnapshot, now: entry.date)
    }

    var shouldOpenApp: Bool {
        guard entry.loadStatus == .available,
              let writtenAt = entry.snapshotWrittenAt else { return true }
        return !MacWidgetLocalPayload.isProducerFresh(writtenAt: writtenAt, asOf: entry.date)
    }

    func count(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "N/A" }
        return ChartMath.compactCount(Int64(value))
    }

    func multiple(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "N/A" }
        return String(format: "%.1f×", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
