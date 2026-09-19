import AIPulseShared
import CloudKit
import Foundation
import WidgetKit

enum MacWidgetLoadStatus: Equatable {
    case available
    case partial
    case waitingForRefresh
    case noAccount
    case noData
    case failed
}

struct MacWidgetEntry: TimelineEntry {
    let date: Date
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
            todaySnapshot: today,
            historySnapshot: historySnapshot,
            pulseEnvelope: pulseEnvelope,
            loadStatus: todaySnapshot != nil && today == nil ? .waitingForRefresh : loadStatus
        )
    }
}

private enum MacWidgetRecordResult<Value> {
    case value(Value)
    case missing
    case failed

    var value: Value? {
        guard case .value(let value) = self else { return nil }
        return value
    }

    var hasFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}

private enum MacWidgetCloudReader {
    static func load(at date: Date) async -> MacWidgetEntry {
        let container = CKContainer(identifier: "iCloud.com.wxy.aipulse")
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            return emptyEntry(at: date, status: .failed)
        }
        guard accountStatus == .available else {
            let status: MacWidgetLoadStatus = accountStatus == .noAccount || accountStatus == .restricted
                ? .noAccount
                : .failed
            return emptyEntry(at: date, status: status)
        }

        let todayID = CKRecord.ID(recordName: CKSchema.RecordName.today)
        let historyID = CKRecord.ID(recordName: CKSchema.RecordName.month)
        let pulseID = CKRecord.ID(recordName: CKSchema.CurrentPulse.recordName)
        let records: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            records = try await container.privateCloudDatabase.records(
                for: [todayID, historyID, pulseID],
                desiredKeys: [CKSchema.Field.json]
            )
        } catch {
            return emptyEntry(at: date, status: .failed)
        }

        let today = decodeSnapshot(records[todayID], range: "today")
        let history = decodeSnapshot(records[historyID], range: "30d")
        let pulse = decodePulse(records[pulseID])
        let hasValue = today.value != nil || history.value != nil || pulse.value != nil
        let hasFailure = today.hasFailure || history.hasFailure || pulse.hasFailure
        let hasMissing = today.isMissing || history.isMissing || pulse.isMissing
        var status: MacWidgetLoadStatus
        if !hasValue {
            status = hasFailure ? .failed : .noData
        } else if hasFailure || hasMissing {
            status = .partial
        } else {
            status = .available
        }

        let todaySnapshot = today.value.flatMap {
            date >= $0.period.start && date < $0.period.end ? $0 : nil
        }
        if today.value != nil && todaySnapshot == nil {
            status = .waitingForRefresh
        }
        return MacWidgetEntry(
            date: date,
            todaySnapshot: todaySnapshot,
            historySnapshot: history.value,
            pulseEnvelope: pulse.value,
            loadStatus: status
        )
    }

    private static func emptyEntry(at date: Date, status: MacWidgetLoadStatus) -> MacWidgetEntry {
        MacWidgetEntry(
            date: date,
            todaySnapshot: nil,
            historySnapshot: nil,
            pulseEnvelope: nil,
            loadStatus: status
        )
    }

    private static func decodeSnapshot(
        _ result: Result<CKRecord, any Error>?,
        range: String
    ) -> MacWidgetRecordResult<DashboardSnapshot> {
        switch result {
        case .success(let record):
            guard let json = record[CKSchema.Field.json] as? String,
                  let data = json.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(DashboardSnapshot.self, from: data),
                  PhoneDashboardData.accepts(snapshot, range: range) else {
                return .failed
            }
            return .value(snapshot.sanitized())
        case .failure(let error):
            if let cloudError = error as? CKError, cloudError.code == .unknownItem {
                return .missing
            }
            return .failed
        case nil:
            return .failed
        }
    }

    private static func decodePulse(
        _ result: Result<CKRecord, any Error>?
    ) -> MacWidgetRecordResult<CurrentPulseEnvelope> {
        switch result {
        case .success(let record):
            guard let json = record[CKSchema.Field.json] as? String,
                  let data = json.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(CurrentPulseEnvelope.self, from: data),
                  envelope.payloadVersion == CKSchema.payloadVersion else {
                return .failed
            }
            return .value(envelope)
        case .failure(let error):
            if let cloudError = error as? CKError, cloudError.code == .unknownItem {
                return .missing
            }
            return .failed
        case nil:
            return .failed
        }
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
        let callback = MacWidgetCompletion(call: completion)
        Task { callback.call(await MacWidgetCloudReader.load(at: Date())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacWidgetEntry>) -> Void) {
        let callback = MacWidgetCompletion(call: completion)
        Task {
            let now = Date()
            let entry = await MacWidgetCloudReader.load(at: now)
            let nextRefresh = now.addingTimeInterval(CurrentPulseEnvelope.widgetRefreshInterval)
            let transitionDates = WatchDashboardData.timelineTransitionDates(
                todaySnapshot: entry.todaySnapshot,
                pulse: entry.pulseEnvelope?.pulse,
                now: now,
                nextRefresh: nextRefresh
            )
            callback.call(Timeline(
                entries: [entry] + transitionDates.map(entry.at),
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
        guard status == .available || status == .partial else {
            return MacWidgetEntry(
                date: date,
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

    func count(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "N/A" }
        return ChartMath.compactCount(Int64(value))
    }

    func multiple(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "N/A" }
        return String(format: "%.1f×", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
