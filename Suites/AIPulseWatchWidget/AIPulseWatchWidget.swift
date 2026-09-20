import AIPulseShared
import CloudKit
import SwiftUI
import WidgetKit

private enum WatchWidgetCopy {
    static func text(_ simplifiedChinese: String, _ english: String) -> String {
        let language = Locale.preferredLanguages.first ?? "en"
        let localized = Bundle.main.localizedString(forKey: english, value: english, table: nil)
        if localized != english || language.hasPrefix("en") { return localized }
        if language.hasPrefix("zh-Hant") {
            return simplifiedChinese.applyingTransform(StringTransform("Hans-Hant"), reverse: false)
                ?? simplifiedChinese
        }
        return language.hasPrefix("zh") ? simplifiedChinese : english
    }
}

enum WatchWidgetLoadStatus: Equatable {
    case available
    case partial
    case waitingForRefresh
    case noAccount
    case noData
    case failed
}

struct WatchWidgetEntry: TimelineEntry {
    let date: Date
    let todaySnapshot: DashboardSnapshot?
    let historySnapshot: DashboardSnapshot?
    let pulseEnvelope: CurrentPulseEnvelope?
    let loadStatus: WatchWidgetLoadStatus

    func at(_ date: Date) -> WatchWidgetEntry {
        let today = todaySnapshot.flatMap {
            date >= $0.period.start && date < $0.period.end ? $0 : nil
        }
        let status = todaySnapshot != nil && today == nil ? .waitingForRefresh : loadStatus
        return WatchWidgetEntry(
            date: date,
            todaySnapshot: today,
            historySnapshot: historySnapshot,
            pulseEnvelope: pulseEnvelope,
            loadStatus: status
        )
    }
}

private enum RecordResult<Value> {
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

private enum WatchWidgetCloudReader {
    static func load(at date: Date) async -> WatchWidgetEntry {
        let container = CKContainer(identifier: "iCloud.com.wxy.aipulse")
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            return WatchWidgetEntry(
                date: date,
                todaySnapshot: nil,
                historySnapshot: nil,
                pulseEnvelope: nil,
                loadStatus: .failed
            )
        }
        guard accountStatus == .available else {
            let status: WatchWidgetLoadStatus = accountStatus == .noAccount || accountStatus == .restricted
                ? .noAccount
                : .failed
            return WatchWidgetEntry(
                date: date,
                todaySnapshot: nil,
                historySnapshot: nil,
                pulseEnvelope: nil,
                loadStatus: status
            )
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
            return WatchWidgetEntry(
                date: date,
                todaySnapshot: nil,
                historySnapshot: nil,
                pulseEnvelope: nil,
                loadStatus: .failed
            )
        }
        let today = decodeSnapshot(records[todayID], range: "today")
        let history = decodeSnapshot(records[historyID], range: "30d")
        let pulse = decodePulse(records[pulseID])
        let resultsHaveValue = today.value != nil || history.value != nil || pulse.value != nil
        let resultsHaveFailure = today.hasFailure || history.hasFailure || pulse.hasFailure
        let resultsHaveMissing = today.isMissing || history.isMissing || pulse.isMissing
        var status: WatchWidgetLoadStatus
        if !resultsHaveValue {
            status = resultsHaveFailure ? .failed : .noData
        } else if resultsHaveFailure || resultsHaveMissing {
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
        return WatchWidgetEntry(
            date: date,
            todaySnapshot: todaySnapshot,
            historySnapshot: history.value,
            pulseEnvelope: pulse.value,
            loadStatus: status
        )
    }

    private static func decodeSnapshot(
        _ result: Result<CKRecord, any Error>?,
        range: String
    ) -> RecordResult<DashboardSnapshot> {
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
    ) -> RecordResult<CurrentPulseEnvelope> {
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

struct WatchWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchWidgetEntry {
        Self.previewEntry(at: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchWidgetEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await WatchWidgetCloudReader.load(at: Date())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchWidgetEntry>) -> Void) {
        Task {
            let now = Date()
            let entry = await WatchWidgetCloudReader.load(at: now)
            let nextRefresh = now.addingTimeInterval(CurrentPulseEnvelope.widgetRefreshInterval)
            let transitionDates = WatchDashboardData.timelineTransitionDates(
                todaySnapshot: entry.todaySnapshot,
                pulse: entry.pulseEnvelope?.pulse,
                now: now,
                nextRefresh: nextRefresh
            )
            let entries = [entry] + transitionDates.map(entry.at)
            completion(Timeline(entries: entries, policy: .after(nextRefresh)))
        }
    }

    static func previewEntry(
        at date: Date,
        status: WatchWidgetLoadStatus = .available,
        staleSummary: Bool = false,
        expiredPulse: Bool = false,
        tier: PulseTier = .elevated,
        todayTokens: Int64 = 2_400_000,
        todayLines: Int = 900
    ) -> WatchWidgetEntry {
        guard status == .available || status == .partial else {
            return WatchWidgetEntry(
                date: date,
                todaySnapshot: nil,
                historySnapshot: nil,
                pulseEnvelope: nil,
                loadStatus: status
            )
        }

        let updatedAt = staleSummary ? date.addingTimeInterval(-3_600) : date
        var today = DashboardSnapshot(
            todayTokens: todayTokens,
            topRepos: [RepoItem(
                repoPath: "/preview",
                name: "Preview",
                added: todayLines,
                deleted: 0,
                commits: 0
            )],
            payloadVersion: CKSchema.payloadVersion,
            updatedAt: updatedAt
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
            tier: tier,
            primarySignal: .activity,
            reason: "activity",
            signals: [signal],
            asOf: pulseDate,
            validUntil: pulseDate.addingTimeInterval(CurrentPulseEnvelope.cloudValidityInterval)
        )
        return WatchWidgetEntry(
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

private struct WatchWidgetProjection {
    let entry: WatchWidgetEntry

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

    var latestPulse: PulseSnapshot? {
        entry.pulseEnvelope?.pulse
    }

    var pulseIsExpired: Bool {
        latestPulse != nil && currentPulse == nil
    }

    var intensity: Double? {
        WatchDashboardData.observedIntensity(latestPulse)
    }

    var summaryIsStale: Bool {
        entry.todaySnapshot != nil
            && !WatchDashboardData.isSummaryFresh(entry.todaySnapshot, now: entry.date)
    }

    var tierText: String {
        guard let tier = latestPulse?.tier else { return "N/A" }
        switch tier {
        case .resting: return WatchWidgetCopy.text("平静", "Resting")
        case .active: return WatchWidgetCopy.text("活跃", "Active")
        case .elevated: return WatchWidgetCopy.text("升高", "Elevated")
        case .intense: return WatchWidgetCopy.text("强烈", "Intense")
        }
    }

    var complicationTierText: String {
        if currentPulse != nil { return tierText }
        if pulseIsExpired { return WatchWidgetCopy.text("已过期", "Expired") }
        return "N/A"
    }

    var statusText: String? {
        switch entry.loadStatus {
        case .available:
            return summaryIsStale ? WatchWidgetCopy.text("摘要已陈旧", "Summary stale") : nil
        case .partial:
            return WatchWidgetCopy.text("同步未完成", "Sync incomplete")
        case .waitingForRefresh:
            return WatchWidgetCopy.text("等待刷新", "Waiting to refresh")
        case .noAccount:
            return WatchWidgetCopy.text("需要 iCloud", "iCloud required")
        case .noData:
            return WatchWidgetCopy.text("暂无数据", "No data")
        case .failed:
            return WatchWidgetCopy.text("同步失败", "Sync failed")
        }
    }

    func count(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "N/A" }
        return ChartMath.compactCount(Int64(value))
    }

    func inlineCount(_ value: Double?) -> String {
        let compact = count(value)
        guard compact.count > 7, let value else { return compact }
        return String(format: "%.1E", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private struct WatchPulseRobot: View {
    @Environment(\.colorScheme) private var colorScheme
    let projection: WatchWidgetProjection

    var body: some View {
        PulseRobotMark(tier: projection.latestPulse?.tier)
            .fill(watchRobotColor(for: projection.latestPulse?.tier, colorScheme: colorScheme),
                  style: FillStyle(eoFill: true))
            .opacity(projection.pulseIsExpired ? 0.55 : 1)
            .widgetAccentable()
    }
}

private func watchRobotColor(for tier: PulseTier?, colorScheme: ColorScheme) -> Color {
    guard let rgb = PulseRobotPalette.rgb(for: tier, dark: colorScheme == .dark) else {
        return .secondary
    }
    return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
}

private struct WatchWidgetRing: View {
    let ratio: Double?
    let color: Color
    let trackColor: Color
    let width: CGFloat
    var allowsLaps = true

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let radius = (diameter - width) / 2
            let value = ratio.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let arc = WatchDashboardData.remainingArc(value ?? 0)
            ZStack {
                Circle().stroke(value == nil ? Color.gray.opacity(0.30) : trackColor, lineWidth: width)
                if let value {
                    if value >= 1 {
                        Circle().stroke(color.opacity(allowsLaps ? 0.48 : 1), lineWidth: width)
                    }
                    if arc > 0 {
                        Circle()
                            .trim(from: 0, to: arc)
                            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    if value >= 1 {
                        let angle = (arc * 360 - 90) * Double.pi / 180
                        Circle()
                            .fill(color)
                            .frame(width: width, height: width)
                            .position(
                                x: radius + radius * cos(angle),
                                y: radius + radius * sin(angle)
                            )
                    }
                }
            }
            .frame(width: diameter - width, height: diameter - width)
            .position(x: diameter / 2, y: diameter / 2)
        }
        .accessibilityHidden(true)
    }
}

private struct WatchWidgetRings: View {
    let projection: WatchWidgetProjection

    private let tokenColor = Color.deepRed
    private let lineColor = Color.marsGreen
    private let activityColor = Color(red: 212 / 255, green: 163 / 255, blue: 38 / 255)

    var body: some View {
        GeometryReader { geometry in
            let edge = min(geometry.size.width, geometry.size.height)
            let width = max(2, edge * 0.09)
            ZStack {
                WatchWidgetRing(
                    ratio: projection.tokenRatio,
                    color: tokenColor,
                    trackColor: Color.deepRed2.opacity(0.25),
                    width: width
                )
                .opacity(projection.summaryIsStale ? 0.55 : 1)
                WatchWidgetRing(
                    ratio: projection.lineRatio,
                    color: lineColor,
                    trackColor: Color.marsGreenLight.opacity(0.25),
                    width: width
                )
                .padding(edge * 0.16)
                .opacity(projection.summaryIsStale ? 0.55 : 1)
                WatchWidgetRing(
                    ratio: projection.intensity,
                    color: activityColor,
                    trackColor: Color(red: 226 / 255, green: 204 / 255, blue: 126 / 255).opacity(0.24),
                    width: width,
                    allowsLaps: false
                )
                .padding(edge * 0.32)
            }
            .widgetAccentable()
        }
    }
}

private struct WatchRingsCircularView: View {
    let entry: WatchWidgetEntry

    var body: some View {
        let projection = WatchWidgetProjection(entry: entry)
        ZStack {
            AccessoryWidgetBackground()
            WatchWidgetRings(projection: projection)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(projection))
    }

    private func accessibilityLabel(_ projection: WatchWidgetProjection) -> String {
        [
            "AI Pulse",
            "\(WatchWidgetCopy.text("今日词元", "Today tokens")): \(projection.count(projection.todayTokens))",
            "\(WatchWidgetCopy.text("今日行数", "Today lines")): \(projection.count(projection.todayLines))",
            "\(WatchWidgetCopy.text("当前强度", "Current activity")): \(projection.tierText)",
            projection.statusText
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private struct WatchRingsRectangularView: View {
    let entry: WatchWidgetEntry

    var body: some View {
        let projection = WatchWidgetProjection(entry: entry)
        GeometryReader { geometry in
            let columnWidth = geometry.size.width / 2
            let side = min(geometry.size.height, columnWidth)
            HStack(spacing: 0) {
                WatchWidgetRings(projection: projection)
                    .frame(width: side, height: side)
                    .frame(width: columnWidth, height: geometry.size.height)
                VStack(alignment: .center, spacing: 4) {
                    fact(WatchWidgetCopy.text("词元", "Tokens"), projection.count(projection.todayTokens))
                    fact(WatchWidgetCopy.text("行数", "Lines"), projection.count(projection.todayLines))
                    if let status = projection.statusText {
                        Text(status)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .frame(width: columnWidth, height: geometry.size.height, alignment: .center)
            }
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityElement(children: .combine)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct WatchActivityCircularView: View {
    let entry: WatchWidgetEntry

    var body: some View {
        let projection = WatchWidgetProjection(entry: entry)
        GeometryReader { geometry in
            let edge = min(geometry.size.width, geometry.size.height)
            ZStack {
                AccessoryWidgetBackground()
                WatchPulseRobot(projection: projection)
                    .frame(width: edge * 0.58, height: edge * 0.58)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activityAccessibilityLabel(projection))
    }
}

private struct WatchActivityRectangularView: View {
    let entry: WatchWidgetEntry

    var body: some View {
        let projection = WatchWidgetProjection(entry: entry)
        GeometryReader { geometry in
            let columnWidth = geometry.size.width / 2
            let side = min(geometry.size.height, columnWidth)
            HStack(spacing: 0) {
                WatchPulseRobot(projection: projection)
                    .frame(width: side * 0.68, height: side * 0.68)
                    .frame(width: columnWidth, height: geometry.size.height)
                VStack(alignment: .center, spacing: 3) {
                    Text(WatchWidgetCopy.text("活动强度", "Activity"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(projection.tierText)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    activityDetail(projection)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                    .multilineTextAlignment(.center)
                    .frame(width: columnWidth, height: geometry.size.height, alignment: .center)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activityAccessibilityLabel(projection))
    }

    @ViewBuilder
    private func activityDetail(_ projection: WatchWidgetProjection) -> some View {
        if let observedAt = projection.latestPulse?.asOf {
            Text(WatchWidgetCopy.text("观测于 ", "Observed ")
                 + observedAt.formatted(date: .omitted, time: .shortened))
        }
        if let status = projection.statusText { Text(status) }
    }
}

private struct WatchActivityCornerView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: WatchWidgetEntry

    var body: some View {
        let projection = WatchWidgetProjection(entry: entry)
        Text(projection.complicationTierText)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(activityTextColor(projection))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .widgetAccentable()
            .widgetCurvesContent()
            .widgetLabel {
                if projection.currentPulse != nil, let intensity = projection.intensity {
                    Gauge(value: intensity) {
                        Text("AI Pulse")
                    }
                    .tint(watchRobotColor(
                        for: projection.latestPulse?.tier,
                        colorScheme: colorScheme
                    ))
                } else {
                    Text("AI Pulse")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(activityAccessibilityLabel(projection))
    }

    private func activityTextColor(_ projection: WatchWidgetProjection) -> Color {
        guard projection.currentPulse != nil else { return .secondary }
        return watchRobotColor(for: projection.latestPulse?.tier, colorScheme: colorScheme)
    }
}

private struct WatchActivityInlineView: View {
    let entry: WatchWidgetEntry

    var body: some View {
        let projection = WatchWidgetProjection(entry: entry)
        Text(verbatim: "AI Pulse · \(projection.complicationTierText)")
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .allowsTightening(true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(activityAccessibilityLabel(projection))
    }
}

private func activityAccessibilityLabel(_ projection: WatchWidgetProjection) -> String {
    [
        WatchWidgetCopy.text("AI Pulse 活动强度", "AI Pulse activity"),
        projection.complicationTierText,
        projection.latestPulse.map {
            WatchWidgetCopy.text("观测于 ", "Observed ")
                + $0.asOf.formatted(date: .omitted, time: .shortened)
        },
        projection.statusText
    ]
    .compactMap { $0 }
    .joined(separator: ", ")
}

private enum WatchMetric {
    case tokens
    case lines

    var inlineLabel: String {
        switch self {
        case .tokens: return "Tokens"
        case .lines: return "Lines"
        }
    }

    var localizedLabel: String {
        switch self {
        case .tokens: return WatchWidgetCopy.text("今日词元", "Today's tokens")
        case .lines: return WatchWidgetCopy.text("今日行数", "Today's lines")
        }
    }

    var color: Color {
        switch self {
        case .tokens: return .deepRed
        case .lines: return .marsGreen
        }
    }

    func value(in projection: WatchWidgetProjection) -> Double? {
        switch self {
        case .tokens: return projection.todayTokens
        case .lines: return projection.todayLines
        }
    }

    func ratio(in projection: WatchWidgetProjection) -> Double? {
        switch self {
        case .tokens: return projection.tokenRatio
        case .lines: return projection.lineRatio
        }
    }
}

private struct WatchMetricCornerView: View {
    let entry: WatchWidgetEntry
    let metric: WatchMetric

    var body: some View {
        let projection = WatchWidgetProjection(entry: entry)
        let value = projection.count(metric.value(in: projection))
        Text(value)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .foregroundStyle(metric.color)
            .widgetAccentable()
            .widgetCurvesContent()
            .widgetLabel {
                if let ratio = metric.ratio(in: projection) {
                    Gauge(value: min(1, ratio)) {
                        Text(metric.localizedLabel)
                    }
                    .tint(metric.color)
                } else {
                    Text(metric.localizedLabel)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([
                metric.localizedLabel,
                value,
                projection.statusText
            ].compactMap { $0 }.joined(separator: ", "))
    }
}

private struct WatchMetricInlineView: View {
    let entry: WatchWidgetEntry
    let metric: WatchMetric

    var body: some View {
        let projection = WatchWidgetProjection(entry: entry)
        let value = projection.inlineCount(metric.value(in: projection))
        Text("\(metric.inlineLabel) \(value)")
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .allowsTightening(true)
            .accessibilityLabel([
                metric.localizedLabel,
                value,
                projection.statusText
            ].compactMap { $0 }.joined(separator: ", "))
    }
}

private struct WatchRingsEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            WatchRingsCircularView(entry: entry)
        case .accessoryRectangular:
            WatchRingsRectangularView(entry: entry)
        default:
            WatchRingsCircularView(entry: entry)
        }
    }
}

private struct WatchActivityEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            WatchActivityCircularView(entry: entry)
        case .accessoryRectangular:
            WatchActivityRectangularView(entry: entry)
        case .accessoryCorner:
            WatchActivityCornerView(entry: entry)
        case .accessoryInline:
            WatchActivityInlineView(entry: entry)
        default:
            WatchActivityCircularView(entry: entry)
        }
    }
}

private struct WatchMetricEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchWidgetEntry
    let metric: WatchMetric

    var body: some View {
        switch family {
        case .accessoryCorner:
            WatchMetricCornerView(entry: entry, metric: metric)
        case .accessoryInline:
            WatchMetricInlineView(entry: entry, metric: metric)
        default:
            WatchMetricInlineView(entry: entry, metric: metric)
        }
    }
}

struct AIPulseWatchRingsWidget: Widget {
    let kind = "AIPulseWatchRings"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchWidgetProvider()) { entry in
            WatchRingsEntryView(entry: entry)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName(WatchWidgetCopy.text(
            "AI Pulse · 三环总览",
            "AI Pulse · Three Rings"
        ))
        .description(WatchWidgetCopy.text(
            "通过三环查看今日词元、代码行数和当前活动强度。",
            "See today's tokens, code lines, and current activity in three rings."
        ))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct AIPulseWatchActivityWidget: Widget {
    let kind = "AIPulseWatchActivity"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchWidgetProvider()) { entry in
            WatchActivityEntryView(entry: entry)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName(WatchWidgetCopy.text(
            "AI Pulse · 活动强度",
            "AI Pulse · Activity"
        ))
        .description(WatchWidgetCopy.text(
            "通过状态机器人查看当前 AI 编码活动强度。",
            "See current AI coding activity through the status robot."
        ))
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryCorner,
            .accessoryInline
        ])
        .contentMarginsDisabled()
    }
}

struct AIPulseWatchTokensWidget: Widget {
    let kind = "AIPulseWatchTokens"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchWidgetProvider()) { entry in
            WatchMetricEntryView(entry: entry, metric: .tokens)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName(WatchWidgetCopy.text(
            "AI Pulse · 今日词元",
            "AI Pulse · Today's Tokens"
        ))
        .description(WatchWidgetCopy.text(
            "查看今日已观测的 AI 词元数量。",
            "See today's observed AI token count."
        ))
        .supportedFamilies([.accessoryCorner, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct AIPulseWatchLinesWidget: Widget {
    let kind = "AIPulseWatchLines"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchWidgetProvider()) { entry in
            WatchMetricEntryView(entry: entry, metric: .lines)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName(WatchWidgetCopy.text(
            "AI Pulse · 今日行数",
            "AI Pulse · Today's Lines"
        ))
        .description(WatchWidgetCopy.text(
            "查看今日新增与删除的代码行数。",
            "See today's added and deleted code lines."
        ))
        .supportedFamilies([.accessoryCorner, .accessoryInline])
        .contentMarginsDisabled()
    }
}

@main
struct AIPulseWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        AIPulseWatchRingsWidget()
        AIPulseWatchActivityWidget()
        AIPulseWatchTokensWidget()
        AIPulseWatchLinesWidget()
    }
}

#if DEBUG
#Preview("Rings Circular", as: .accessoryCircular) {
    AIPulseWatchRingsWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now)
}

#Preview("Rings Rectangular", as: .accessoryRectangular) {
    AIPulseWatchRingsWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now, staleSummary: true, tier: .active)
}

#Preview("Activity Circular", as: .accessoryCircular) {
    AIPulseWatchActivityWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now, tier: .elevated)
}

#Preview("Activity Rectangular", as: .accessoryRectangular) {
    AIPulseWatchActivityWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now, tier: .active)
}

#Preview("Activity Corner", as: .accessoryCorner) {
    AIPulseWatchActivityWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now, tier: .intense)
}

#Preview("Activity Inline", as: .accessoryInline) {
    AIPulseWatchActivityWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now, tier: .active)
}

#Preview("Tokens Corner", as: .accessoryCorner) {
    AIPulseWatchTokensWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now)
}

#Preview("Tokens Inline", as: .accessoryInline) {
    AIPulseWatchTokensWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now)
}

#Preview("Lines Corner", as: .accessoryCorner) {
    AIPulseWatchLinesWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now)
}

#Preview("Lines Inline", as: .accessoryInline) {
    AIPulseWatchLinesWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now)
}

#Preview("Tokens Inline Long", as: .accessoryInline) {
    AIPulseWatchTokensWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now, todayTokens: 999_900_000)
}

#Preview("Lines Inline Long", as: .accessoryInline) {
    AIPulseWatchLinesWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now, todayLines: 999_900)
}

#Preview("Tokens Inline N/A", as: .accessoryInline) {
    AIPulseWatchTokensWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now, status: .noData)
}

#Preview("Lines Inline N/A", as: .accessoryInline) {
    AIPulseWatchLinesWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now, status: .noData)
}

#Preview("Rings No Data", as: .accessoryCircular) {
    AIPulseWatchRingsWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now, status: .noData)
}

#Preview("Activity Expired", as: .accessoryCorner) {
    AIPulseWatchActivityWidget()
} timeline: {
    WatchWidgetProvider.previewEntry(at: .now, expiredPulse: true)
}
#endif
