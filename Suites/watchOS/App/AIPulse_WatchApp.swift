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
        if I18n.lang.hasPrefix("zh-Hant") { return zh.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? zh }
        return I18n.lang == "zh-Hans" ? zh : en
    }
}

private struct WatchActivityRing: View {
    let ratio: Double?
    let color: Color
    let width: CGFloat
    var allowsLaps = true
    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let radius = (diameter - width) / 2
            let value = ratio.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let arc = WatchDashboardData.remainingArc(value ?? 0)
            ZStack {
                Circle().stroke(value == nil ? Color.gray.opacity(0.24) : color.opacity(0.15), lineWidth: width)
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
    @State private var showingInfo = false
    @State private var refreshing = false
    @State private var refreshMessage: String?
    private let red = Color(red: 236 / 255, green: 81 / 255, blue: 90 / 255)
    private let green = Color(red: 49 / 255, green: 197 / 255, blue: 129 / 255)
    private let yellow = Color(red: 246 / 255, green: 199 / 255, blue: 66 / 255)
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
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        return ChartMath.compactCount(Int64(value))
    }
    private func multiple(_ value: Double?) -> String {
        guard let value else { return t("暂无基准", "No baseline") }
        return String(format: "%.1f×", locale: Locale(identifier: "en_US_POSIX"), value)
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
                // Size against the full display width, as in the original corner-overlay layout.
                let side = geometry.size.width * 0.93
                let thickness = side * 13 / 184
                ZStack {
                    Color.black
                    ZStack {
                        WatchActivityRing(ratio: tokenRatio, color: red, width: thickness)
                        WatchActivityRing(ratio: lineRatio, color: green, width: thickness).padding(side * 16 / 184)
                        WatchActivityRing(ratio: WatchDashboardData.intensity(pulse, now: now), color: yellow, width: thickness, allowsLaps: false).padding(side * 32 / 184)
                        Button { showingInfo = true } label: {
                            VStack(spacing: 5) {
                                Text(t("当前强度", "Current activity")).font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(pulse.map { I18n.pulseTier($0.tier) } ?? (cloud.pulseEnvelope?.pulse == nil ? t("暂无观测", "No observation") : t("观测已过期", "Expired")))
                                    .font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                                if let date = cloud.pulseEnvelope?.pulse?.asOf {
                                    Text(t("观测于 ", "Observed ") + date.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                } else { Text("—").font(.system(size: 10)).foregroundStyle(.secondary) }
                            }.frame(width: side * 0.49)
                        }.buttonStyle(.plain).accessibilityHint(t("查看数据说明与同步状态", "View data explanation and sync status"))
                    }.frame(width: side, height: side).position(x: geometry.size.width / 2, y: geometry.size.height / 2 + 6)
                    VStack {
                        HStack(alignment: .top) {
                            corner(t("今日词元", "Today tokens"), count(tokens(snapshot)), color: red, alignment: .leading, numberFirst: false)
                            Spacer()
                            corner(t("今日行数", "Today lines"), count(lines(snapshot)), color: green, alignment: .trailing, numberFirst: false)
                        }
                        Spacer()
                        HStack(alignment: .bottom) {
                            corner(t("词元 / 平常", "Tokens / usual"), multiple(tokenRatio), color: red, alignment: .leading, numberFirst: true)
                            Spacer()
                            corner(t("行数 / 平常", "Lines / usual"), multiple(lineRatio), color: green, alignment: .trailing, numberFirst: true)
                        }
                    }.padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
                    if cloud.isPreview { Text(t("演示", "Demo")).font(.system(size: 8)).foregroundStyle(.secondary).position(x: geometry.size.width / 2, y: geometry.size.height - 8) }
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
    private func corner(_ label: String, _ value: String, color: Color, alignment: HorizontalAlignment, numberFirst: Bool) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            if numberFirst { Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(color).lineLimit(1) }
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            if !numberFirst { Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(color).lineLimit(1) }
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
        defer { refreshing = false }
        for range in ["today", "30d"] { await cloud.fetchAndStore(range: range, force: force) }
        cloud.loadSnapshot(for: "today")
        await cloud.fetchCurrentPulse(force: force)
        refreshMessage = cloud.rangeErrors["today"] == nil && cloud.rangeErrors["30d"] == nil && cloud.pulseError == nil
            ? t("已读取云端数据", "Cloud data fetched") : t("未能完整同步，已保留缓存", "Sync incomplete; cached data retained")
    }

    #if DEBUG
    private func installPreview() {
        let now = Date()
        var today = DashboardSnapshot(todayTokens: 2_400_000,
            topRepos: [RepoItem(repoPath: "/preview", name: "Preview", added: 700, deleted: 200, commits: 0)], payloadVersion: CKSchema.payloadVersion, updatedAt: now)
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
    }
    #endif
}
