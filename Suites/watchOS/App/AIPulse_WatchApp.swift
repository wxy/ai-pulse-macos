import SwiftUI
import WatchKit
import AIPulseShared

@main
struct AIPulse_WatchApp: App {
    @StateObject private var cloudData = CloudDataService.shared
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchDashboardView().environmentObject(cloudData)
                    .transformEnvironment(\.dynamicTypeSize) { size in
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--watch-accessibility-layout") {
                            size = .accessibility3
                        }
                        #endif
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Spacer().frame(width: 0) }
                        ToolbarItem(placement: .topBarTrailing) { Spacer().frame(width: 0) }
                    }
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
                .persistentSystemOverlays(.hidden)
        }
    }
}

private enum WatchCopy {
    static func t(_ zh: String, _ en: String) -> String {
        I18n.prototype(zh, en)
    }
}

private struct WatchActivityRing: View {
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
                Circle().stroke(value == nil ? Color.gray.opacity(0.24) : trackColor, lineWidth: width)
                if let value {
                    if value >= 1 { Circle().stroke(color.opacity(allowsLaps ? 0.48 : 1), lineWidth: width) }
                    if arc > 0 {
                        Circle().trim(from: 0, to: arc)
                            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    if value >= 1 {
                        let angle = (arc * 360 - 90) * Double.pi / 180
                        Circle().fill(color).frame(width: width, height: width)
                            .position(x: radius + radius * cos(angle), y: radius + radius * sin(angle))
                    }
                }
            }.frame(width: diameter - width, height: diameter - width)
                .position(x: diameter / 2, y: diameter / 2)
        }.accessibilityHidden(true)
    }
}

struct WatchDashboardView: View {
    @EnvironmentObject private var cloud: CloudDataService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var cornerLabelSize: CGFloat = 9
    @ScaledMetric(relativeTo: .headline) private var cornerValueSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var centerLabelSize: CGFloat = 10
    @ScaledMetric(relativeTo: .headline) private var centerValueSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) private var statusFontSize: CGFloat = 8
    @State private var showingInfo = false
    @State private var refreshing = false
    @State private var hasAttemptedRefresh = false
    @State private var refreshMessage: String?
    private let tokenColor = Color.deepRed
    private let tokenTrackColor = Color.deepRed2.opacity(0.22)
    private let lineColor = Color.marsGreen
    private let lineTrackColor = Color.marsGreenLight.opacity(0.22)
    private let activityColor = Color(red: 212 / 255, green: 163 / 255, blue: 38 / 255)
    private let activityTrackColor = Color(red: 226 / 255, green: 204 / 255, blue: 126 / 255).opacity(0.20)
    private let supportTextColor = Color.white.opacity(0.82)
    private func t(_ zh: String, _ en: String) -> String { WatchCopy.t(zh, en) }

    private func today(asOf now: Date) -> DashboardSnapshot? {
        guard let snapshot = cloud.cachedSnapshot(for: "today"),
              now >= snapshot.period.start, now < snapshot.period.end else { return nil }
        return snapshot
    }
    private func tokens(_ snapshot: DashboardSnapshot?) -> Double? {
        guard let snapshot, !snapshot.readFailures.contains("toolUsage"),
              !snapshot.readFailures.contains("dashboardUsageStats") else { return nil }
        return Double(snapshot.todayTokens)
    }
    private func lines(_ snapshot: DashboardSnapshot?) -> Double? {
        guard let snapshot, !snapshot.readFailures.contains("repositoryCode"), !snapshot.topRepos.isEmpty else { return nil }
        return snapshot.topRepos.reduce(0) { $0 + Double($1.added) + Double($1.deleted) }
    }
    private func count(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "N/A" }
        return ChartMath.compactCount(Int64(value))
    }
    private func multiple(_ value: Double?) -> String {
        guard let value else { return "N/A" }
        return String(format: "%.1f×", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private func summaryIsStale(_ snapshot: DashboardSnapshot?, asOf now: Date) -> Bool {
        snapshot != nil && !WatchDashboardData.isSummaryFresh(snapshot, now: now)
    }
    private func summaryUsesCache(_ snapshot: DashboardSnapshot?, asOf now: Date) -> Bool {
        snapshot != nil && (summaryIsStale(snapshot, asOf: now)
            || cloud.rangeErrors["today"] != nil || cloud.missingRanges.contains("today"))
    }
    private func dashboardStatus(_ snapshot: DashboardSnapshot?, asOf now: Date) -> (text: String, color: Color)? {
        let arguments = ProcessInfo.processInfo.arguments
        let previewsDataState = arguments.contains("--watch-stale")
            || arguments.contains("--watch-empty") || arguments.contains("--watch-error")
        if cloud.isPreview && !previewsDataState { return (t("演示", "Demo"), .secondary) }
        if refreshing || (!hasAttemptedRefresh && snapshot == nil) {
            return (t("同步中…", "Syncing…"), .secondary)
        }
        if cloud.rangeErrors["today"] != nil {
            guard let snapshot else { return (t("同步失败", "Sync failed"), tokenColor) }
            return (t("缓存 ", "Cached ") + snapshot.updatedAt.formatted(date: .omitted, time: .shortened), activityColor)
        }
        if cloud.missingRanges.contains("today") {
            guard let snapshot else { return (t("暂无数据", "No data"), .secondary) }
            return (t("缓存 ", "Cached ") + snapshot.updatedAt.formatted(date: .omitted, time: .shortened), activityColor)
        }
        guard let snapshot else { return (t("暂无数据", "No data"), .secondary) }
        if summaryIsStale(snapshot, asOf: now) {
            return (t("缓存 ", "Cached ") + snapshot.updatedAt.formatted(date: .omitted, time: .shortened), activityColor)
        }
        if cloud.rangeErrors["30d"] != nil || cloud.missingRanges.contains("30d") || cloud.pulseError != nil {
            return (t("同步未完成", "Sync incomplete"), activityColor)
        }
        return nil
    }
    private var usesAccessibleLayout: Bool {
        dynamicTypeSize.isAccessibilitySize || dynamicTypeSize == .xxLarge || dynamicTypeSize == .xxxLarge
            || (cloud.isPreview && ProcessInfo.processInfo.arguments.contains("--watch-accessibility-layout"))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            GeometryReader { geometry in
                let now = context.date
                let snapshot = today(asOf: now)
                let history = cloud.cachedSnapshot(for: "30d")
                let tokenRatio = WatchDashboardData.ratio(value: tokens(snapshot), baseline: WatchDashboardData.baseline(history, tokens: true, now: now))
                let lineRatio = WatchDashboardData.ratio(value: lines(snapshot), baseline: WatchDashboardData.baseline(history, tokens: false, now: now))
                let pulse = cloud.pulseEnvelope?.currentPulse(asOf: now)
                let status = dashboardStatus(snapshot, asOf: now)
                // Size against the full display width, as in the original corner-overlay layout.
                let side = geometry.size.width * 0.90
                let thickness = side * 13 / 184
                let ringCenter = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2 + 8)
                if usesAccessibleLayout {
                    accessibleDashboard(snapshot: snapshot, tokenRatio: tokenRatio, lineRatio: lineRatio,
                                        pulse: pulse, status: status, now: now, side: side, thickness: thickness,
                                        viewportHeight: geometry.size.height)
                } else {
                    ZStack {
                        Color.black
                        ringCluster(side: side, thickness: thickness, tokenRatio: tokenRatio, lineRatio: lineRatio,
                                    pulse: pulse, now: now, dimsSummary: summaryUsesCache(snapshot, asOf: now))
                            .position(ringCenter)
                        cornerFacts(
                            in: geometry.size,
                            ringCenter: ringCenter,
                            side: side,
                            ringWidth: thickness,
                            snapshot: snapshot,
                            tokenRatio: tokenRatio,
                            lineRatio: lineRatio,
                            dimsValue: summaryUsesCache(snapshot, asOf: now)
                        )
                        if let status {
                            Text(status.text).font(.system(size: statusFontSize)).foregroundStyle(status.color)
                                .lineLimit(1).minimumScaleFactor(0.75)
                                .position(x: geometry.size.width / 2, y: geometry.size.height - 8)
                        }
                    }
                }
            }
        }.ignoresSafeArea().persistentSystemOverlays(.hidden)
            .sheet(isPresented: $showingInfo) { info }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                #if DEBUG
                if cloud.isPreview { installPreview(); return }
                #endif
                await refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await cloud.fetchAndStore(range: "today")
                    cloud.loadSnapshot(for: "today")
                    await cloud.fetchCurrentPulse()
                }
            }
    }

    private func cornerFacts(
        in size: CGSize,
        ringCenter: CGPoint,
        side: CGFloat,
        ringWidth: CGFloat,
        snapshot: DashboardSnapshot?,
        tokenRatio: Double?,
        lineRatio: Double?,
        dimsValue: Bool
    ) -> some View {
        let topGapRadius = side / 2 + ringWidth * 1.65
        let bottomGapRadius = side / 2 + ringWidth * 1.50
        let lineSpacing: CGFloat = 3
        let labelEdgePadding = cornerLabelSize
        let leftReach = max(1, ringCenter.x - labelEdgePadding)
        let rightReach = max(1, size.width - ringCenter.x - labelEdgePadding)
        let topReach = max(1, ringCenter.y - labelEdgePadding)
        let bottomReach = max(
            1,
            size.height - ringCenter.y - max(labelEdgePadding, statusFontSize + 6)
        )
        let topLeftAngle = Angle.radians(Double(atan2(-topReach, -leftReach)))
        let topRightAngle = Angle.radians(Double(atan2(-topReach, rightReach)))
        let bottomLeftAngle = Angle.radians(Double(atan2(bottomReach, -leftReach)))
        let bottomRightAngle = Angle.radians(Double(atan2(bottomReach, rightReach)))

        return ZStack {
            curvedCorner(
                t("今日词元", "Today tokens"), count(tokens(snapshot)), color: tokenColor,
                centerAngle: topLeftAngle, direction: .clockwise,
                gapRadius: topGapRadius, lineSpacing: lineSpacing, dimsValue: dimsValue
            )
            curvedCorner(
                t("今日行数", "Today lines"), count(lines(snapshot)), color: lineColor,
                centerAngle: topRightAngle, direction: .clockwise,
                gapRadius: topGapRadius, lineSpacing: lineSpacing, dimsValue: dimsValue
            )
            curvedCorner(
                t("词元 / 平常", "Tokens / usual"), multiple(tokenRatio), color: tokenColor,
                centerAngle: bottomLeftAngle, direction: .counterClockwise,
                gapRadius: bottomGapRadius, lineSpacing: lineSpacing, dimsValue: dimsValue
            )
            curvedCorner(
                t("行数 / 平常", "Lines / usual"), multiple(lineRatio), color: lineColor,
                centerAngle: bottomRightAngle, direction: .counterClockwise,
                gapRadius: bottomGapRadius, lineSpacing: lineSpacing, dimsValue: dimsValue
            )
        }
        .frame(width: size.width, height: size.height)
        .offset(x: ringCenter.x - size.width / 2, y: ringCenter.y - size.height / 2)
    }

    private func curvedCorner(
        _ label: String,
        _ value: String,
        color: Color,
        centerAngle: Angle,
        direction: ArcText.Direction,
        gapRadius: CGFloat,
        lineSpacing: CGFloat,
        dimsValue: Bool
    ) -> some View {
        ZStack {
            ArcText(
                label,
                radius: gapRadius + lineSpacing / 2,
                centerAngle: centerAngle,
                direction: direction,
                radialAlignment: .innerEdge,
                maximumSweep: .degrees(42),
                fontSize: cornerLabelSize,
                color: supportTextColor,
                characterSpacing: 0.1,
                minimumScaleFactor: 0.75
            )
            ArcText(
                value,
                radius: gapRadius - lineSpacing / 2,
                centerAngle: centerAngle,
                direction: direction,
                radialAlignment: .outerEdge,
                maximumSweep: .degrees(30),
                fontSize: cornerValueSize,
                fontWeight: .semibold,
                fontDesign: .rounded,
                color: color,
                characterSpacing: 0.1,
                minimumScaleFactor: 0.8
            )
            .opacity(dimsValue ? 0.65 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label + ", " + value))
    }
    private func ringCluster(side: CGFloat, thickness: CGFloat, tokenRatio: Double?, lineRatio: Double?,
                             pulse: PulseSnapshot?, now: Date, dimsSummary: Bool,
                             compactCenter: Bool = false) -> some View {
        let labelSize = compactCenter ? CGFloat(10) : centerLabelSize
        let valueSize = compactCenter ? CGFloat(15) : centerValueSize
        return ZStack {
            WatchActivityRing(ratio: tokenRatio, color: tokenColor, trackColor: tokenTrackColor, width: thickness)
                .opacity(dimsSummary ? 0.55 : 1)
            WatchActivityRing(ratio: lineRatio, color: lineColor, trackColor: lineTrackColor, width: thickness)
                .padding(side * 16 / 184).opacity(dimsSummary ? 0.55 : 1)
            WatchActivityRing(ratio: WatchDashboardData.intensity(pulse, now: now), color: activityColor,
                              trackColor: activityTrackColor, width: thickness, allowsLaps: false)
                .padding(side * 32 / 184)
            Button { showingInfo = true } label: {
                VStack(spacing: 5) {
                    Text(t("当前强度", "Current activity")).font(.system(size: labelSize)).foregroundStyle(supportTextColor)
                    Text(pulse.map { I18n.pulseTier($0.tier) } ?? (cloud.pulseEnvelope?.pulse == nil ? t("暂无观测", "No observation") : t("观测已过期", "Expired")))
                        .font(.system(size: valueSize, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                    if let date = cloud.pulseEnvelope?.pulse?.asOf {
                        Text(t("观测于 ", "Observed ") + date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: labelSize)).foregroundStyle(supportTextColor).lineLimit(1)
                    } else { Text("—").font(.system(size: labelSize)).foregroundStyle(supportTextColor) }
                }.frame(width: side * 0.49)
            }.buttonStyle(.plain).accessibilityHint(t("查看数据说明与同步状态", "View data explanation and sync status"))
        }.frame(width: side, height: side)
    }
    private func accessibleDashboard(snapshot: DashboardSnapshot?, tokenRatio: Double?, lineRatio: Double?,
                                     pulse: PulseSnapshot?, status: (text: String, color: Color)?,
                                     now: Date, side: CGFloat, thickness: CGFloat, viewportHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    VStack(spacing: 4) {
                        ringCluster(side: side, thickness: thickness, tokenRatio: tokenRatio, lineRatio: lineRatio,
                                    pulse: pulse, now: now, dimsSummary: summaryUsesCache(snapshot, asOf: now),
                                    compactCenter: true)
                        if let status { Text(status.text).font(.caption2).foregroundStyle(status.color) }
                    }
                    .frame(height: viewportHeight)
                    VStack(spacing: 6) {
                        accessibleMetric(t("词元", "Tokens"), count(tokens(snapshot)), color: tokenColor)
                        accessibleMetric(t("相对平常", "vs usual"), multiple(tokenRatio), color: tokenColor)
                        accessibleMetric(t("行数", "Lines"), count(lines(snapshot)), color: lineColor)
                        accessibleMetric(t("相对平常", "vs usual"), multiple(lineRatio), color: lineColor)
                    }
                    .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .center)
                    .id("watch-facts")
                }
                .scrollTargetLayout()
                .padding(.horizontal, 8)
            }.background(Color.black)
                .scrollTargetBehavior(.viewAligned)
                .onAppear {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--watch-accessibility-details") {
                        proxy.scrollTo("watch-facts", anchor: .top)
                    }
                    #endif
                }
            }
    }
    private func accessibleMetric(_ label: String, _ value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(supportTextColor).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).font(.headline).foregroundStyle(color).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
    private var info: some View {
        NavigationStack {
            List {
                Section(t("同步", "Sync")) {
                    Text(t("手表从同一 Apple 账户的 iCloud 读取 Mac 摘要。重新同步不会触发 Mac 上传。", "Watch reads Mac summaries from the same Apple account’s iCloud. Refreshing does not trigger a Mac upload."))
                    if let date = cloud.lastUpdated { Text(t("摘要更新于 ", "Summary updated ") + date.formatted(date: .abbreviated, time: .shortened)) }
                    if cloud.rangeErrors["today"] != nil || cloud.pulseError != nil { Text(t("云端读取未成功，当前保留缓存。", "Cloud fetch failed; cached data is retained.")) }
                    Button(refreshing ? t("正在同步…", "Syncing…") : t("重新同步", "Sync again")) { Task { await refresh(force: true) } }.disabled(refreshing || cloud.isPreview)
                    if let refreshMessage { Text(refreshMessage).font(.footnote).foregroundStyle(.secondary) }
                }
                Section(t("三圈依据", "Ring reference")) {
                    Text(t("外圈：今日词元。中圈：今日代码新增与删除行数之和。内圈：当前 AI 活动强度。", "Outer: today's tokens. Middle: added plus deleted code lines. Inner: current AI activity."))
                    Text(t("平常为最近 28 天已观测活跃日的中位数估算，至少需要 7 天样本。空白日不按零计算；这是个人参照，不是额度、目标或效率。", "Usual is the estimated median of observed active days over the last 28 days, with at least 7 samples. Missing days are not zeros. This is a personal reference, not a quota, target or efficiency score."))
                    Text(t("超过满圈后，亮弧表示下一圈的位置，准确倍数显示在下方。强度达到高强度边界时满圈，停止更新后会过期。", "Beyond a full lap, the bright arc shows the next lap's position; the corners show exact multiples. Activity fills at the intense-tier boundary and expires when updates stop."))
                }
            }.navigationTitle(t("数据说明", "Data info"))
        }
    }
    private func refresh(force: Bool = false) async {
        guard !refreshing, !cloud.isPreview else { return }
        refreshing = true
        defer { refreshing = false; hasAttemptedRefresh = true }
        for range in ["today", "30d"] { await cloud.fetchAndStore(range: range, force: force) }
        cloud.loadSnapshot(for: "today")
        await cloud.fetchCurrentPulse(force: force)
        refreshMessage = cloud.rangeErrors["today"] == nil && cloud.rangeErrors["30d"] == nil && cloud.pulseError == nil
            ? t("已读取云端数据", "Cloud data fetched") : t("未能完整同步，已保留缓存", "Sync incomplete; cached data retained")
    }

    #if DEBUG
    private func installPreview() {
        let now = Date()
        let arguments = ProcessInfo.processInfo.arguments
        let emptyPulse = CurrentPulseEnvelope.forCloudSync(pulse: nil, writerAppVersion: "watch preview", generatedAt: now)
        if arguments.contains("--watch-empty") {
            cloud.installPreview(snapshots: [:], pulse: emptyPulse, missingRanges: ["today"])
            hasAttemptedRefresh = true
            return
        }
        if arguments.contains("--watch-error") {
            cloud.installPreview(snapshots: [:], pulse: emptyPulse, rangeErrors: ["today": "Preview sync failure"])
            hasAttemptedRefresh = true
            return
        }
        let updatedAt = arguments.contains("--watch-stale") ? now.addingTimeInterval(-3_600) : now
        var today = DashboardSnapshot(todayTokens: 2_400_000,
            topRepos: [RepoItem(repoPath: "/preview", name: "Preview", added: 700, deleted: 200, commits: 0)], payloadVersion: CKSchema.payloadVersion, updatedAt: updatedAt)
        today.period = DashboardPeriod(kind: .today, now: now)
        var history = DashboardSnapshot(payloadVersion: CKSchema.payloadVersion, updatedAt: now)
        history.period = DashboardPeriod(kind: .days30, now: now)
        let count = ProcessInfo.processInfo.arguments.contains("--watch-no-baseline") ? 6 : 10
        let calendar = Calendar.current
        history.dailyStats = (1...count).map { day in TrendPoint(ts: calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: now))!.timeIntervalSince1970, value: 0, calls: 1, tokens: 1_000_000, netLines: 0) }
        history.codeChanges = history.dailyStats.map { TrendPoint(ts: $0.ts, value: 0, calls: 0, tokens: 0, netLines: 100, added: 200, deleted: 100) }
        let date = ProcessInfo.processInfo.arguments.contains("--watch-expired") ? now.addingTimeInterval(-600) : now
        let signal = PulseSignal(kind: .activity, rawValue: 100, unit: "tokens", baseline: 50, normalized: 2.4, freshness: .fresh, completeness: .complete, observedAt: date, reason: "activity")
        let pulse = PulseSnapshot(tier: .elevated, primarySignal: .activity, reason: "activity", signals: [signal], asOf: date)
        cloud.installPreview(snapshots: ["today": today, "30d": history], pulse: CurrentPulseEnvelope.forCloudSync(pulse: pulse, writerAppVersion: "watch preview", generatedAt: date))
        hasAttemptedRefresh = true
    }
    #endif
}
