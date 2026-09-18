import SwiftUI
import Combine
import Charts
import GRDB
import AIPulseShared

enum TimeRange: Hashable, CaseIterable {
    case today
    case thisWeek
    case days30

    var periodKind: DashboardPeriodKind {
        switch self {
        case .today: return .today
        case .thisWeek: return .week
        case .days30: return .days30
        }
    }

    var days: Int {
        switch self {
        case .today: return 1
        case .thisWeek:
            let days = Calendar.current.dateComponents(
                [.day],
                from: Calendar.mondayOfWeek(),
                to: Calendar.current.startOfDay(for: Date())
            ).day ?? 0
            return max(days + 1, 1)
        case .days30: return 30
        }
    }

    var label: String {
        switch self {
        case .today: return I18n.t("dashboard.today")
        case .thisWeek: return I18n.t("dashboard.this_week")
        case .days30: return I18n.t("dashboard.days_30")
        }
    }

    /// Stable cache key matching Phase 4 / CloudKit record names.
    var cacheKey: String {
        switch self {
        case .today: return "today"
        case .thisWeek: return "week"
        case .days30: return "30d"
        }
    }
}

/// Kept outside observable state: an unchanged heartbeat can be ignored
/// without invalidating the dashboard while the user is scrolling.
@MainActor
private final class DashboardLoadThrottle {
    private var lastLoad = Date.distantPast

    func shouldLoad(now: Date, minimumInterval: TimeInterval) -> Bool {
        guard now.timeIntervalSince(lastLoad) >= minimumInterval else { return false }
        lastLoad = now
        return true
    }
}

struct DashboardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    let initialTimeRange: TimeRange

    @State private var timeRange: TimeRange
    @State private var robotDetail: String?
    @State private var costHoverDate: Date? = nil
    @State private var isRefreshing = false
    @State private var lastChartJournalKey: String = ""

    init(initialTimeRange: TimeRange = .today) {
        self.initialTimeRange = initialTimeRange
        self._timeRange = State(initialValue: initialTimeRange)
    }
    @State private var codeHoverDate: Date? = nil
    @State private var costHoverX: CGFloat = 0
    @State private var codeHoverX: CGFloat = 0
    @State private var editorMappings: [EditorDetector.Mapping] = []
    @State private var healthSeverity = AppHealthMonitor.Severity.nominal
    @State private var healthMessages: [String] = []
    @State private var showHealthDetails = false
    @State private var usageData: [QuotaStatusItem] = []
    @State private var i18nToken = 0  // bumped on language change to force re-render
    @State private var barProgress: CGFloat = 0  // 0→1 drives all entry animations
    @State private var balanceErrors: Set<String> = []     // provider IDs whose API fetch failed
    @State private var loadGenerationByRange: [TimeRange: Int] = [:]
    @State private var rangeLoadTasks: [TimeRange: Task<Void, Never>] = [:]
    @State private var entryAnimationToken = 0   // cancels a stale zero→one entry run
    @State private var rangeChangeStartedAt: Date? = nil
    @State private var rangeSnapshots: [TimeRange: DashboardSnapshot] = [:]
    @State private var currentPulse: PulseSnapshot?
    @State private var pulseRefreshGeneration = 0
    @State private var demoRanges: Set<TimeRange> = []
    @State private var toolsExpanded = false
    @State private var claudeDetailExpanded = false
    @State private var codexDetailExpanded = false
    @State private var selectedToolForOverlay: String? = nil
    @State private var reposExpanded = false
    @State private var modelsExpanded = false
    @State private var isImportingHistory = LogWatcher.backfill.isActive
    @State private var localDataStatus = LocalDataStatus.current()
    @State private var localScanStatus = LogScanObservation.Status.inactive
    @State private var showScanCompletion = false
    @State private var showScanDetails = false
    @State private var matrixViewportWidth: CGFloat = 0

    var hasActiveCostSources: Bool {
        !IntegrationRegistry.activeCostSources(editorMappings: editorMappings).isEmpty
    }

    // The dashboard keeps a complete, independent snapshot per range. All UI
    // data below is a projection of the selected range; switching a tab cannot
    // mutate one range while another range is mid-render.
    private var activeSnapshot: DashboardSnapshot? {
        rangeSnapshots[timeRange]
    }

    private var loadedTimeRange: TimeRange? {
        activeSnapshot != nil ? timeRange : nil
    }

    private var lastUpdated: Date? {
        activeSnapshot?.updatedAt
    }

    private var lastSnapshotTS: Date? {
        activeSnapshot?.updatedAt
    }

    private var isDemoMode: Bool {
        demoRanges.contains(timeRange)
    }

    private var balanceSpend: [(providerId: String, name: String, spend: Double)] {
        (activeSnapshot?.providerBreakdown ?? []).map {
            (providerId: $0.providerId, name: $0.name, spend: $0.cost)
        }
    }

    private var dailyStats: [DailyStat] {
        (activeSnapshot?.dailyStats ?? []).map {
            DailyStat(date: Date(timeIntervalSince1970: $0.ts),
                      calls: Int($0.calls),
                      tokens: Int($0.tokens),
                      netLines: $0.netLines)
        }
    }

    private var dailyBalanceSpend: [Date: Double] {
        (activeSnapshot?.balanceDaily ?? []).reduce(into: [Date: Double]()) { map, point in
            map[Date(timeIntervalSince1970: point.ts)] = point.value
        }
    }

    private var codeChanges: [DailyCodeChange] {
        (activeSnapshot?.codeChanges ?? []).map {
            DailyCodeChange(date: Date(timeIntervalSince1970: $0.ts),
                            added: $0.added,
                            deleted: $0.deleted,
                            commits: $0.commits)
        }
    }

    private var paddedChanges: [DailyCodeChange] {
        Self.padChanges(codeChanges, chartStart: chartStart, chartDays: chartDays)
    }

    private var repos: [RepoItem] { activeSnapshot?.topRepos ?? [] }

    private var remainingBalances: [RemainingBalanceItem] {
        activeSnapshot?.remainingBalances ?? []
    }

    private var todayCalls: Int { Int(activeSnapshot?.todayCalls ?? 0) }
    private var todayTokens: Int { Int(activeSnapshot?.todayTokens ?? 0) }


    private var codeComposition: CodeChangeComposition? {
        CodeChangeComposition.period(in: activeSnapshot)
    }

    private var periodSessionCount: Int {
        Int(clamping: activeSnapshot?.periodSessions ?? 0)
    }

    private var periodActiveDays: Int {
        Set(dailyStats.filter { $0.tokens > 0 || $0.calls > 0 }
            .map { Calendar.current.startOfDay(for: $0.date) }).count
    }

    private var periodCommitCount: Int {
        codeChanges.reduce(0) { $0 + $1.commits }
    }

    /// Period-specific token density. The denominator is the complete visible
    /// horizon (24 hours / 7 days / 30 days), matching the fixed rhythm slots;
    /// this is an arithmetic display rate, not a provider-billing estimate.
    private var rangeTokenRateText: String {
        guard activeSnapshot != nil, activeSnapshot?.readFailures.contains("dashboardUsageStats") != true else {
            return pulseText("词元均速不可用", "Token pace unavailable")
        }
        let total = dailyStats.reduce(Int64(0)) { $0 + Int64($1.tokens) }
        let divisor: Double
        let zhUnit: String
        let enUnit: String
        switch timeRange {
        case .today:
            divisor = 24
            zhUnit = "小时"
            enUnit = "hour"
        case .thisWeek:
            divisor = 7
            zhUnit = "日"
            enUnit = "day"
        case .days30:
            divisor = 30
            zhUnit = "日"
            enUnit = "day"
        }
        let average = Int64((Double(total) / divisor).rounded())
        let value = ChartMath.compactCount(average)
        return pulseText("全周期均速 \(value) 词元/\(zhUnit)", "Full-period pace \(value) tokens/\(enUnit)")
    }

    private var hasPulseActivity: Bool {
        (activeSnapshot?.todayTokens ?? 0) > 0 || periodSessionCount > 0 ||
        !repos.isEmpty || !(activeSnapshot?.observedSpend ?? []).isEmpty
    }

    private var localScanStatusText: String {
        I18n.t("source.local_scan.\(localScanStatusKey)")
    }

    private var localScanStatusKey: String {
        switch localScanStatus {
        case .inactive: return "inactive"
        case .scanning: return "scanning"
        case .available: return "available"
        case .stale: return "stale"
        case .failed: return "failed"
        }
    }

    private func refreshLocalScanStatus() {
        localDataStatus = LocalDataStatus.current(hasActivity: (currentPulse?.activityFacts?.todayTokens ?? 0) > 0)
        let failed = AppHealthMonitor.shared.failingIngestSources.contains {
            $0.lowercased().hasPrefix("log.")
        }
        let next = LogScanObservation.shared.status(hasReadFailure: failed)
        if next != localScanStatus {
            showScanCompletion = next == .available && localScanStatus == .scanning
            localScanStatus = next
        }
    }

    private func pulseText(_ zh: String, _ en: String) -> String {
        I18n.resolvedLang() == "zh-Hans" ? zh : en
    }

    private func pulseColor(_ tier: PulseTier?) -> Color {
        Color(nsColor: PulseAppearance(tier: tier).color)
    }

    private var modelBreakdownItems: [ModelActivityItem] {
        activeSnapshot?.modelBreakdown ?? []
    }


    /// Rounded-rect "ear" for the robot-head frame.
    /// Adaptive font size for donut chart center numbers — smaller for longer values.
    static func donutCenterFontSize(for value: Double) -> CGFloat {
        let chars = String(format: "%.2f", abs(value)).count  // e.g. "12345.67" = 8
        if chars <= 5 { return 16 }
        if chars <= 7 { return 14 }
        return 12
    }

    /// A repository is a dashboard subject when either fact stream saw it:
    /// code changes or attributed token usage. Usage-only days must not vanish.
    nonisolated static func shouldShowRepository(totalChanges: Int, tokens: Int64, commits: Int = 0) -> Bool {
        totalChanges > 0 || tokens > 0 || commits > 0
    }

    private func earView(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(robotEarSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(robotLine, lineWidth: 1)
            )
            .frame(width: width, height: height)
    }

    var body: some View {
        dashboardContent
        .task(id: localScanStatusKey) {
            guard localScanStatus == .available else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            showScanCompletion = false
        }
    }

    /// Notice content is embedded in the forehead's stable-height status row.
    /// Detail uses the same content above its own navigation.
    @ViewBuilder
    private var statusOverlay: some View {
        if healthSeverity >= .degraded {
            Button { showHealthDetails.toggle() } label: {
                Label(healthBannerText, systemImage: healthSeverity == .critical
                      ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(healthSeverity == .critical ? Color.white : Color.primary)
            .background(healthBannerColor, in: RoundedRectangle(cornerRadius: 6))
            .popover(isPresented: $showHealthDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(healthBannerText).font(.headline)
                    ForEach(healthMessages.suffix(5), id: \.self) { message in
                        Text(message).font(.caption).textSelection(.enabled)
                    }
                    Button(I18n.t("health.open_log")) {
                        NSWorkspace.shared.activateFileViewerSelecting([Logger.logFileURL])
                    }
                    Text(I18n.t("health.send_to_dev")).font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(width: 360)
            }
            .padding(.horizontal, 12).padding(.top, 2)
        } else if let notice = statusNotice {
            let warning = !isDemoMode && (localScanStatus == .failed || localScanStatus == .stale)
            Button { showScanDetails = true } label: {
                HStack {
                    Label(notice, systemImage: warning ? "exclamationmark.triangle" : "info.circle")
                        .lineLimit(1)
                    Spacer()
                    if warning { Image(systemName: "chevron.right") }
                }
                .font(.caption).foregroundStyle(warning ? Color.orange : Color.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            .buttonStyle(.plain).disabled(!warning)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .popover(isPresented: $showScanDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localScanStatusText).font(.headline)
                    Text(I18n.t("dashboard.scan_warning_help")).font(.caption)
                    Button(I18n.t("health.open_log")) {
                        NSWorkspace.shared.activateFileViewerSelecting([Logger.logFileURL])
                    }
                }.padding(16).frame(width: 340)
            }
            .robotHelp(notice)
            .padding(.horizontal, 12).padding(.top, 2)
        }
    }

    private var statusNotice: String? {
        if isDemoMode { return I18n.t("demo.banner") }
        if localScanStatus == .failed || localScanStatus == .stale { return localScanStatusText }
        if isImportingHistory { return I18n.t("menu.loading") }
        if localScanStatus != .available || showScanCompletion { return localScanStatusText }
        return nil
    }

    private var periodPicker: some View {
        Group {
            if colorScheme == .dark {
                HStack(spacing: 0) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Button {
                            rangeChangeStartedAt = Date()
                            timeRange = range
                        } label: {
                            Text(range.label).font(.system(size: 11))
                                .foregroundStyle(timeRange == range ? Color(red: 0.76, green: 0.83, blue: 0.78) : Color.secondary)
                                .frame(maxWidth: .infinity).frame(height: 24)
                                .background(timeRange == range ? Color(red: 0.19, green: 0.30, blue: 0.24) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(timeRange == range ? .isSelected : [])
                    }
                }
                .padding(2).frame(width: 240)
                .background(robotEyeSurface, in: RoundedRectangle(cornerRadius: 8))
                .pointingHandCursor()
            } else {
                Picker("", selection: Binding(
                    get: { timeRange },
                    set: { newValue in
                        // Stamp intent before selection changes, retaining range isolation.
                        rangeChangeStartedAt = Date()
                        timeRange = newValue
                    }
                )) {
                    Text(I18n.t("dashboard.today")).tag(TimeRange.today)
                    Text(I18n.t("dashboard.this_week")).tag(TimeRange.thisWeek)
                    Text(I18n.t("dashboard.days_30")).tag(TimeRange.days30)
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(width: 240).pointingHandCursor()
            }
        }
    }

    private var foreheadStatusRow: some View {
        ZStack {
            if selectedToolForOverlay != nil {
                // The mounted-but-hidden dashboard must not create a second
                // popover presenter for the detail page's shared notice state.
                Color.clear
            } else if healthSeverity >= .degraded || statusNotice != nil {
                statusOverlay
            } else {
                let snapshot = currentPulse?.isCurrent() == true ? currentPulse : nil
                let appearance = PulseAppearance(tier: snapshot?.tier,
                                                 cooling: snapshot?.activity?.freshness == .aging)
                HStack(spacing: 6) {
                    Circle().fill(Color(nsColor: appearance.color)).frame(width: 8, height: 8)
                    Text(appearance.label).font(.caption).foregroundStyle(.secondary)
                }
                .robotHelp(snapshot != nil
                      ? StatusItemController.detail(snapshot: snapshot) + "\n" + I18n.t("pulse.activity.legend")
                      : I18n.t("pulse.reason.unavailable"))
            }
        }
        .frame(maxWidth: .infinity).frame(height: 26)
    }

    private var robotAntenna: some View {
        VStack(spacing: 0) {
            Circle().fill(Color.marsGreen.opacity(0.5)).frame(width: 6, height: 6)
            Rectangle().fill(Color.marsGreen.opacity(0.35)).frame(width: 2, height: 6)
            Path { path in
                path.addArc(center: CGPoint(x: 20, y: 20), radius: 20,
                            startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            }.stroke(Color.marsGreen.opacity(0.35), lineWidth: 2).frame(width: 40, height: 20)
        }
        .accessibilityHidden(true).allowsHitTesting(false)
    }

    private var dashboardContent: some View {
        robotDashboard
        .frame(width: 560, height: 640)
        .background(Color.clear)
        .environment(\.locale, I18n.resolvedLocale)
        .transaction {
            if reduceMotion {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled { startEntryAnimation() }
        }
        .task {
            refreshLocalScanStatus()
            let health = AppHealthMonitor.shared.current
            healthSeverity = health.severity
            healthMessages = health.messages
            await refreshCurrentPulse()
            await hydrateRangeSnapshotCache()
            let selectedRange = timeRange
            await load(range: selectedRange)
            for range in TimeRange.allCases where range != selectedRange {
                scheduleLoad(for: range)
            }
            ApiPoller.shared.pollAll()
            triggerCloudSync()
        }
        .onChange(of: timeRange) { _, newValue in
            rangeChangeStartedAt = Date()
            DiagnosticJournal.log("range_change", [
                "to": .string(newValue.cacheKey),
                "snapshot_ready": .bool(rangeSnapshots[newValue] != nil),
            ])
            // Commit the new range at zero first, then animate on the next
            // run-loop tick. Animating in the same update can be coalesced
            // with the tab change and leave geometry at an intermediate state.
            startEntryAnimation()
            costHoverDate = nil
            codeHoverDate = nil
            scheduleLoad(for: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardRefresh)) { _ in
            // Manual refresh / forceRefresh — immediate, no throttle
            scheduleLoad(for: timeRange)
        }
        .onReceive(NotificationCenter.default.publisher(for: .demoModeDidChange)) { _ in
            // A mode change invalidates all three channels, not only the visible
            // one. Never flash fictional activity while real data is loading.
            for range in TimeRange.allCases {
                rangeLoadTasks[range]?.cancel()
                loadGenerationByRange[range, default: 0] += 1
            }
            rangeSnapshots.removeAll()
            demoRanges.removeAll()
            selectedToolForOverlay = nil
            for range in TimeRange.allCases { scheduleLoad(for: range) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataDidChange)) { _ in
            Task { await refreshCurrentPulse() }
            // The coordinator already debounces writes. Refresh all resident
            // channels so non-selected periods cannot retain pre-ingest facts.
            // Each range cancels only its own older request.
            for range in TimeRange.allCases { scheduleLoad(for: range) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appHealthDidChange)) { _ in
            refreshLocalScanStatus()
            let snap = AppHealthMonitor.shared.current
            healthSeverity = snap.severity
            healthMessages = snap.messages
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulseDidChange)) { _ in
            refreshLocalScanStatus()
            Task { await refreshCurrentPulse() }
        }
        .onReceive(NotificationCenter.default.publisher(for: IngestionBackfillState.changeNotification)) { _ in
            isImportingHistory = LogWatcher.backfill.isActive
        }
        .onReceive(NotificationCenter.default.publisher(for: BookmarkManager.didChange)) { _ in
            refreshLocalScanStatus()
            Task { await forceRefresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: LogScanObservation.didChange)) { _ in
            refreshLocalScanStatus()
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            // Expiration must remain visible even when a stalled collector
            // produces no new notifications. This does not refresh source time.
            refreshLocalScanStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardSwitchTab)) { notification in
            if let tr = notification.userInfo?["timeRange"] as? TimeRange, tr != timeRange {
                timeRange = tr
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: I18n.didChangeLanguage)) { _ in
            i18nToken += 1
        }
        .onDisappear {
            for task in rangeLoadTasks.values { task.cancel() }
            rangeLoadTasks.removeAll()
        }
        .id(i18nToken)
    }

    // MARK: - Health banner helpers

    private var healthBannerText: String {
        switch healthSeverity {
        case .critical: return I18n.t("health.critical")
        case .impaired: return I18n.t("health.impaired")
        case .degraded: return I18n.t("health.degraded")
        case .nominal:  return ""
        }
    }

    private var healthBannerColor: Color {
        switch healthSeverity {
        case .critical: return .red
        case .impaired: return .orange
        case .degraded: return .yellow
        case .nominal:  return .clear
        }
    }



    func providerDisplayName(_ pid: String) -> String {
        IntegrationRegistry.all.first(where: { $0.id == pid })?.displayName ?? pid
    }

    // MARK: - Quota HUD

    func usageBarView(percent: Double) -> some View {
        let safePercent = percent.isFinite ? percent : 0
        let clamped = min(max(safePercent, 0), 100)
        let barColor: Color = switch clamped {
        case 0..<75:  .marsGreen
        case 75..<90: .marsGreen2
        default:      .deepRed
        }
        let pctText: Text = if clamped > 100 {
            Text(I18n.t("dashboard.over_limit"))
        } else {
            Text(verbatim: Int(clamped).formatted(.percent))
        }
        return HStack(spacing: 2) {
            pctText
                .font(.system(size: 8)).monospacedDigit().foregroundColor(barColor)
                .frame(width: 28, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: .quaternarySystemFill))
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: max(geo.size.width * min(clamped, 100) / 100, 2), height: 5)
                }
            }
            .frame(width: 40, height: 5)
        }
        .robotHelp(clamped > 90 ? I18n.t("dashboard.usage_help") : I18n.t("dashboard.usage_percent"))
    }


    func smallCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline).fontWeight(.semibold).monospacedDigit()
                .foregroundColor(color)
            Text(title).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }


    var subSources: [CostSource] {
        IntegrationRegistry.activeCostSources(editorMappings: editorMappings).filter {
            if case .subscription(_, _, _) = $0.kind { return true }; return false
        }
    }



    func toolName(for id: String) -> String {
        IntegrationRegistry.toolDisplayName(for: id)
    }

    // MARK: - Cost chart (API balance + subscription amortization, stacked)


    // MARK: Cost chart data helpers

    struct ChartDataPoint: Identifiable {
        var id: String { "\(label)-\(Int(date.timeIntervalSince1970))" }
        let date: Date
        let label: String
        let cost: Double
    }




    // MARK: - Code change chart (added + deleted stacked positive bars)


    /// Flatten paddedChanges into segments ordered for stacked bars (added bottom, deleted top).
    var codeChangeSegments: [CodeChangeSegment] {
        paddedChanges.flatMap { d in
            [
                CodeChangeSegment(date: d.date, lines: d.added, type: I18n.t("dashboard.added")),
                CodeChangeSegment(date: d.date, lines: d.deleted, type: I18n.t("dashboard.deleted"))
            ]
        }
    }

    struct CodeChangeSegment: Identifiable {
        var id: String { "\(type)-\(Int(date.timeIntervalSince1970))" }
        let date: Date
        let lines: Int
        let type: String
    }

    /// Static helper so load() can pad without reading @State codeChanges.
    static func padChanges(_ changes: [DailyCodeChange], chartStart: Date, chartDays: Int) -> [DailyCodeChange] {
        let cal = Calendar.current
        var map = [Date: DailyCodeChange]()
        for c in changes { map[cal.startOfDay(for: c.date)] = c }
        var result = [DailyCodeChange]()
        for offset in 0..<chartDays {
            guard let date = cal.date(byAdding: .day, value: offset, to: chartStart) else { continue }
            if let c = map[date] { result.append(c) }
            else { result.append(DailyCodeChange(date: date, added: 0, deleted: 0, commits: 0)) }
        }
        return result
    }

    func codeTooltip(date: Date, added: Int, deleted: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.month(.abbreviated).day()).font(.caption).fontWeight(.semibold)
            Text("+\(added) \(I18n.t("dashboard.added")) / -\(deleted) \(I18n.t("dashboard.deleted"))")
                .font(.caption2).monospacedDigit()
        }
        .padding(6).background(.regularMaterial).cornerRadius(6)
    }

    /// A short, lowered nose. Labels are outside the ratio geometry.
    @ViewBuilder var noseStatCards: some View {
        let composition = codeComposition
        VStack(spacing: 5) {
            Text(composition.map { "−" + ChartMath.compactCount($0.deleted) } ?? "—")
                .font(.caption2).fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(Color.deepRed)
            GeometryReader { geo in
                ZStack {
                    Color.secondary.opacity(0.12)
                    if let composition, let deletedFraction = composition.deletedFraction {
                        VStack(spacing: 0) {
                            Color.deepRed.opacity(0.65)
                                .frame(height: geo.size.height * deletedFraction)
                            Color.marsGreen.opacity(0.8)
                                .frame(height: geo.size.height * (composition.addedFraction ?? 0))
                        }
                    }
                }
                .clipShape(CodeChangeTrapezoid())
                .overlay(CodeChangeTrapezoid().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            }
            .frame(width: 56, height: 64)
            Text(composition.map { "+" + ChartMath.compactCount($0.added) } ?? "—")
                .font(.caption2).fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(Color.marsGreen)
        }
        .robotHelp(I18n.t("dashboard.code_composition_help"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(I18n.t("dashboard.code_composition_help"))
        .accessibilityValue(composition.map {
            "−\(ChartMath.compactCount($0.deleted)), +\(ChartMath.compactCount($0.added))"
        } ?? I18n.t("pulse.tier.unknown"))
    }

    // MARK: - Head overview (forehead activity · eyes distributions · nose output)

    private var tokenCoverageNote: String? {
        guard !isDemoMode else { return nil }
        guard let isPartial = activeSnapshot?.activityCoverage.isPartial else {
            return I18n.t("dashboard.token_coverage_unavailable")
        }
        return isPartial ? I18n.t("dashboard.token_coverage_partial") : nil
    }

    private func noteIcon(_ text: String) -> some View {
        DashboardNoteButton(text: text, enabled: selectedToolForOverlay == nil)
    }

    var spendingOverview: some View {
        // Forehead: usage is the primary number — pure JSONL facts.
        let rangeTokens = dailyStats.reduce(Int64(0)) { $0 + Int64($1.tokens) }
        return VStack(spacing: 16) {
            periodPicker.frame(maxWidth: .infinity)
            // ── Forehead: usage ──
            VStack(spacing: 4) {
                foreheadStatusRow
                HStack(spacing: 4) {
                    Text(activeSnapshot == nil || activeSnapshot?.readFailures.contains("dashboardUsageStats") == true
                         ? "—" : tokenShort(Int(clamping: rangeTokens)))
                        .font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Color.marsGreen)
                        .scaleEffect(loadedTimeRange == timeRange ? (0.8 + 0.2 * barProgress) : 0.8)
                        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6), value: barProgress)
                    if let note = tokenCoverageNote { noteIcon(note) }
                }
                HStack(spacing: 4) {
                    Text("\(timeRange.label) · \(activeSnapshot?.readFailures.contains("toolUsage") == true ? "—" : String(periodSessionCount)) \(pulseText("个会话", "sessions")) · \(activeSnapshot?.readFailures.contains("dashboardUsageStats") == true ? "—" : String(periodActiveDays)) \(pulseText("个活跃日", "active days")) · \(pulseText("词元", "tokens"))")
                        .font(.caption).foregroundColor(.secondary)
                    Text(I18n.t("dashboard.source_logs"))
                        .font(.caption2).foregroundColor(.secondary)
                        .robotHelp(I18n.t("dashboard.local_activity_scope"))
                }
                Text(rangeTokenRateText)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5).allowsHitTesting(false))

            // ── Eyes + nose ──
            HStack(alignment: .top, spacing: 12) {
                toolTokenDonut()

                // Nose: code lines
                VStack(spacing: 12) {
                    noseStatCards
                    Text("\(codeComposition == nil ? "—" : ChartMath.compactCount(Int64(periodCommitCount))) \(I18n.t("dashboard.commits"))")
                        .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                }
                .frame(width: 100)
                .padding(.top, 54)

                repoCodeDonut()
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5).allowsHitTesting(false))
    }

    /// Left eye: observed token share by AI tool. Money and subscriptions do
    /// not enter the robot face.
    @ViewBuilder
    func toolTokenDonut() -> some View {
        let available = activeSnapshot != nil && activeSnapshot?.readFailures.contains("toolUsage") != true
        let tools = available ? (activeSnapshot?.toolBreakdown ?? []) : []
        let rawSegments = tools.compactMap { item -> DonutItem? in
            guard let tokens = item.tokens, tokens > 0 else { return nil }
            return DonutItem(label: item.name, tokens: Double(tokens), pct: 0, color: .secondary)
        }
        let totalTokens = rawSegments.reduce(0) { $0 + $1.tokens }
        let segments = Self.topSegments(
            Self.renderableDonutSegments(rawSegments)
        ).enumerated().map { i, s in
            DonutItem(label: s.label, tokens: s.tokens,
                      pct: totalTokens > 0 ? s.tokens / totalTokens * 100 : 0,
                      color: Self.donutPalette[i % Self.donutPalette.count])
        }
        VStack(spacing: 6) {
            Text(pulseText("工具用量", "Tool usage"))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            ZStack {
                Circle().fill(robotEyeSurface).frame(width: 120, height: 120)
                Circle().stroke(robotLine, lineWidth: 1).frame(width: 132, height: 132)
                if !segments.isEmpty {
                    robotFlatRing(segments)
                } else {
                    Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 10).frame(width: 110, height: 110)
                }
                VStack(spacing: 2) {
                    Text(!available || (!localDataStatus.canReportCurrentActivity && totalTokens == 0)
                         ? "—" : tokenShort(Int(clamping: Int64(min(totalTokens, Double(Int64.max).nextDown)))))
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Color.primary)
                    Text(verbatim: "TOKENS").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5, alignment: .leading), GridItem(.flexible(), spacing: 5, alignment: .leading)], spacing: 4) {
                ForEach(Array(segments.prefix(4))) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.label).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(height: 28, alignment: .topLeading)
        }
        .frame(width: 145)
        .robotHelp(pulseText("各工具可确认的词元用量及占比；不是额度、账单或工作效率。缓存词元属于输入，不重复累加。", "Confirmed token usage and share by tool; not quota, billing or productivity. Cached tokens are part of input and are not counted twice."))
    }

    /// Right eye: repository code changes. Deletion and addition have equal
    /// weight; tokens, net growth and commits never become slices here.
    @ViewBuilder
    func repoCodeDonut() -> some View {
        let totals = CodeChangeComposition.repositoryTotals(in: activeSnapshot)
        let available = totals != nil
        let changes = totals ?? [:]
        let labels = RepositoryLabels.make(for: Array(changes.keys))
        let items = changes.compactMap { (name, change) -> DonutItem? in
            guard change.total > 0 else { return nil }
            return DonutItem(label: labels[name] ?? name, tokens: change.total, pct: 0, color: .secondary, id: name)
        }
        let totalTokens = items.reduce(0.0) { $0 + $1.tokens }
        let segments = Self.topSegments(items).enumerated().map { i, s in
            DonutItem(label: s.label, tokens: s.tokens,
                      pct: totalTokens > 0 ? s.tokens / totalTokens * 100 : 0,
                      color: Self.donutPalette[i % Self.donutPalette.count], id: s.id)
        }
        let centerText = available && (localDataStatus.repositories == .ready || totalTokens > 0) ? ChartMath.compactCount(Int64(min(totalTokens, Double(Int64.max).nextDown))) : "—"
        VStack(spacing: 6) {
            Text(localDataStatus.repositories == .ready ? pulseText("仓库变化", "Repository changes") : SetupCopy.repositories(localDataStatus.repositories))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            ZStack {
                Circle().fill(robotEyeSurface).frame(width: 120, height: 120)
                Circle().stroke(robotLine, lineWidth: 1).frame(width: 132, height: 132)
                if !segments.isEmpty {
                    robotFlatRing(segments)
                } else {
                    Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 10).frame(width: 110, height: 110)
                }
                VStack(spacing: 2) {
                    Text(centerText)
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Color.primary)
                    Text(verbatim: "LINES").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5, alignment: .leading), GridItem(.flexible(), spacing: 5, alignment: .leading)], spacing: 4) {
                ForEach(Array(segments.prefix(4))) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.label).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                            .robotHelp(changes[item.id] == nil ? item.label : item.id)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(height: 28, alignment: .topLeading)
        }
        .frame(width: 145)
        .robotHelp(I18n.t("dashboard.repo_code_changes_help"))
    }

    /// Canonical four-color donut palette (deepRed / marsGreen / deepRed2 /
    /// marsGreen2). Segments beyond the third collapse into "Other" with the
    /// fourth color, so charts never exceed four slices.
    private static let donutPalette: [Color] = [
        .deepRed, .marsGreen, .deepRed2, .marsGreen2,
    ]

    /// Keeps at most `limit` largest segments and folds the rest into an
    /// "Other" slice so donut legends stay readable.
    static func topSegments(_ items: [DonutItem], limit: Int = 3) -> [DonutItem] {
        let sorted = items.sorted {
            $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens
        }
        guard sorted.count > limit else { return sorted }
        let top = Array(sorted.prefix(limit))
        let otherTokens = sorted.dropFirst(limit).reduce(0.0) { $0 + $1.tokens }
        return top + [DonutItem(label: I18n.t("dashboard.other"), tokens: otherTokens, pct: 0, color: .secondary)]
    }


    // MARK: - Quota (subscription remaining)

    /// Locale-aware countdown to the next quota reset, e.g. "1h 20m" / "3d 4h".
    private func resetCountdownText(_ resetAt: Double) -> String {
        let remaining = resetAt - Date().timeIntervalSince1970
        // A past reset means the quota window already refreshed — the
        // utilization is stale, awaiting the next poll. This is NOT an
        // over-limit condition (that's utilization > 100%, shown by usageBar).
        guard remaining > 0 else { return I18n.t("dashboard.quota_stale") }
        let fmt = DateComponentsFormatter()
        fmt.allowedUnits = [.day, .hour, .minute]
        fmt.unitsStyle = .abbreviated
        fmt.maximumUnitCount = 2
        return fmt.string(from: remaining) ?? ""
    }

    private func quotaColor(for percent: Double) -> Color {
        switch percent {
        case 0..<75:  return .marsGreen
        case 75..<90: return .marsGreen2
        default:      return .deepRed
        }
    }

    /// A subscription quota row shown in the Today "remaining" block.
    /// e.g. "Claude ████░░ 45%  1h 20m" — utilization bar + countdown to next reset.
    func quotaRow(data: QuotaStatusItem) -> some View {
        let icon = data.toolId.contains("claude") ? "sparkles" : "bubble.left.and.bubble.right"
        let stale = data.isStale()
        let windowSuffix = data.windowId.map { " · \($0)" } ?? ""
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2)
                .foregroundColor(stale ? .secondary : quotaColor(for: data.utilization))
            Text(toolDisplayName(data.toolId) + windowSuffix)
                .font(.caption).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            if stale {
                Text(I18n.t("dashboard.quota_stale"))
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                usageBarView(percent: data.utilization)
            }
            if !stale, data.resetAt > 0 {
                Text(resetCountdownText(data.resetAt))
                    .font(.caption2).monospacedDigit().foregroundColor(.secondary)
            }
        }
        .robotHelp(String(format: I18n.t("dashboard.quota_help"),
                     (data.utilization / 100).formatted(.percent.precision(.fractionLength(0))),
                     data.limitStatus))
    }

    private func toolDisplayName(_ toolId: String) -> String {
        IntegrationRegistry.toolDisplayName(for: toolId)
    }

    /// Load independent subscription quota windows with observation freshness.
    /// Independent of whether the user configured a subscription tier.
    private func loadUsageData() async {
        guard !isDemoMode else { return }
        usageData = await StatsService.latestQuotaStatus()
    }

    struct DonutItem: Identifiable {
        // Identity may differ from the display label (canonical repository root).
        // Stable IDs avoid destroy/create transitions on every refresh.
        let id: String
        let label: String
        let tokens: Double
        let pct: Double
        let color: Color

        init(label: String, tokens: Double, pct: Double, color: Color, id: String? = nil) {
            self.id = id ?? label
            self.label = label
            self.tokens = tokens
            self.pct = pct
            self.color = color
        }
    }

    /// SectorMark receives only positive, finite angles. All-zero/error entries
    /// stay out of chart geometry and are represented by the caller's placeholder.
    static func renderableDonutSegments(_ segments: [DonutItem]) -> [DonutItem] {
        segments.filter { $0.tokens.isFinite && $0.tokens > 0.001 }
    }

    private func toolIdToDisplay(_ id: String) -> String? {
        IntegrationRegistry.toolDisplayName(for: id)
    }

    // MARK: - Pulse rhythm and factual context

    private var tokenRhythmValues: [Double] {
        if timeRange == .today {
            var hours = Array(repeating: 0.0, count: 24)
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            for stat in dailyStats {
                let date = stat.date
                guard date >= today else { continue }
                let hour = cal.component(.hour, from: date)
                hours[hour] += Double(max(stat.tokens, 0))
            }
            return hours
        }
        return padStats(dailyStats, days: chartDays).map { Double(max($0.tokens, $0.calls, 0)) }
    }

    private var codeRhythmValues: [Double] {
        if timeRange == .today {
            var hours = Array(repeating: 0.0, count: 24)
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            for change in codeChanges where cal.isDate(change.date, inSameDayAs: today) {
                let hour = cal.component(.hour, from: change.date)
                hours[hour] += Double(max(change.added + change.deleted, 0))
            }
            return hours
        }
        return paddedChanges.map { Double(max($0.added + $0.deleted, 0)) }
    }

    @ViewBuilder
    private func rhythmRow(
        label: String,
        values: [Double],
        color: Color,
        growsDownward: Bool = false
    ) -> some View {
        let slotCount = timeRange == .today ? 24 : chartDays
        let slots = DashboardDataPresentation.rhythmSlots(values: values, count: slotCount, surroundingWeeks: timeRange == .thisWeek)
        let peak = max(slots.compactMap { $0 }.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            if growsDownward {
                Text(label).font(.caption2).foregroundColor(.secondary)
            }
            HStack(alignment: growsDownward ? .top : .bottom, spacing: 3) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, value in
                    if let value {
                        Capsule()
                            .fill(value > 0 ? color : Color.secondary.opacity(0.14))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(3, 26 * value / peak))
                    } else {
                        Capsule()
                            .fill(Color.secondary.opacity(0.14))
                            .frame(maxWidth: .infinity)
                            .frame(height: 3)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 28, alignment: growsDownward ? .top : .bottom)
            if !growsDownward {
                Text(label).font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var activityRhythmSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pulseText("消费节奏", "Consumption rhythm"))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(timeRange == .today ? pulseText("按小时", "hourly") : pulseText("按天", "daily"))
                    .font(.caption2).foregroundColor(.secondary)
            }
            rhythmRow(
                label: pulseText("词元活动", "Token activity"),
                values: tokenRhythmValues,
                color: .marsGreen,
                growsDownward: true)
            rhythmRow(
                label: pulseText("代码变化", "Code changes"),
                values: codeRhythmValues,
                color: .deepRed2)
            if timeRange == .today {
                let added = codeChanges.reduce(0) { $0 + $1.added }
                let deleted = codeChanges.reduce(0) { $0 + $1.deleted }
                if added > 0 || deleted > 0 {
                HStack {
                    Text(pulseText("今日代码变化", "Code changes today"))
                    Spacer()
                    Text("+\(ChartMath.compactCount(Int64(added))) / -\(ChartMath.compactCount(Int64(deleted)))")
                        .monospacedDigit()
                }
                .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var pulseFactsSection: some View {
        let observed = (activeSnapshot?.observedSpend ?? []).filter { $0.amount.isFinite && $0.amount > 0 }
        let quotas = activeSnapshot?.quotaStatus ?? usageData
        let monthly = timeRange == .days30 ? activeSnapshot?.declaredMonthlyCostUSD : nil
        let failures = activeSnapshot?.readFailures ?? []
        VStack(alignment: .leading, spacing: 12) {
            // Actual read failures remain prominent. Token completeness is
            // explained by the note icon beside the forehead token total.
            if !isDemoMode && !failures.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !failures.isEmpty {
                        Label(pulseText("部分统计读取失败，空图和零值不代表没有活动。", "Some statistics could not be read; empty charts and zero values do not mean no activity."),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundColor(.orange)
                            .robotHelp(failures.joined(separator: ", "))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            if !observed.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 4) {
                        Text(I18n.t("dashboard.account_observations")).font(.headline)
                        noteIcon(I18n.t("dashboard.balance_observation_help"))
                    }
                    ForEach(observed, id: \.stableId) { item in
                        HStack {
                            Text(ProviderRegistry.byId(item.providerId)?.name ?? item.providerId)
                            Spacer()
                            Text("\(item.currency.uppercased()) \(String(format: "%.1f", item.amount))")
                                .fontWeight(.semibold).monospacedDigit()
                        }
                        .font(.body)
                        .robotHelp(observedAmountIntervalHelp(item))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if !quotas.isEmpty || (monthly ?? 0) > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    if !quotas.isEmpty {
                        Text(I18n.t("dashboard.quota_context_title")).font(.caption).foregroundStyle(.secondary)
                        ForEach(quotas, id: \.stableId) { quota in quotaRow(data: quota) }
                    }
                    if let monthly, monthly > 0 {
                        HStack {
                            Text(I18n.t("dashboard.fixed_monthly_context"))
                            Spacer()
                            Text("USD \(String(format: "%.1f", monthly))").monospacedDigit()
                        }.font(.caption)
                        Text(I18n.t("dashboard.fixed_monthly_help"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func observedAmountIntervalHelp(_ item: ObservedSpendItem) -> String {
        guard let start = item.intervalStart, let end = item.intervalEnd,
              start.isFinite, end.isFinite, start <= end else {
            return pulseText("采样区间未知", "Sampling interval unavailable")
        }
        let first = Date(timeIntervalSince1970: start).formatted(date: .abbreviated, time: .shortened)
        let last = Date(timeIntervalSince1970: end).formatted(date: .abbreviated, time: .shortened)
        return pulseText("采样区间：", "Sampling interval: ") + first + " – " + last + "\n"
            + pulseText("按后一次观察归入所选时段；基准采样可能早于所选时段。",
                        "Assigned by the later observation; the baseline may precede the selected period.")
    }

    // MARK: - Output section

    @ViewBuilder
    var outputSection: some View {
        // Matrix: one column per dev tool, one row per model; a cell is the
        // token usage of that tool for that model. Row/column totals plus the
        // grand total make both dimensions readable. Calls are not shown.
        let matrixRows = modelBreakdownItems
        let matrix = ActivityMatrix(matrixRows)
        let toolIds = matrix.tools
        let modelNames = matrix.models
        let visibleModels = matrix.visibleModels(expanded: modelsExpanded)
        let cellTokens = { (model: ActivityMatrix.ModelKey, tool: String) in matrix.tokens(model: model, tool: tool) }
        let toolTokens = { (tool: String) in matrix.tokens(tool: tool) }
        let modelTokens = { (model: ActivityMatrix.ModelKey) in matrix.tokens(model: model) }
        let grandTotal = matrix.grandTotal
        let toolColumnMaxima = Dictionary(uniqueKeysWithValues: toolIds.map { tool in
            (tool, modelNames.map { cellTokens($0, tool) }.max() ?? 0)
        })
        let modelTotalMaximum = modelNames.map { modelTokens($0) }.max() ?? 0
        let layout = DashboardMatrixLayout(viewportWidth: matrixViewportWidth, toolCount: toolIds.count)

        let fillsViewport = toolIds.count <= 2
        let table = Grid(alignment: .trailing, horizontalSpacing: 1, verticalSpacing: 1) {
	                        GridRow {
	                            Text(I18n.t("dashboard.model"))
	                                .font(.caption2).bold().foregroundColor(.secondary)
	                                .dashboardTableCell(isHeader: true, alignment: .leading, width: fillsViewport ? nil : layout.modelWidth)
	                            ForEach(toolIds, id: \.self) { t in
	                                Button { selectedToolForOverlay = t } label: {
	                                    HStack(spacing: 4) {
	                                        Text(t.isEmpty ? I18n.t("dashboard.unattributed_tool") : (toolIdToDisplay(t) ?? t))
	                                            .lineLimit(1)
	                                        if !t.isEmpty { Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color.accentColor) }
	                                    }
	                                    .font(.caption2).bold()
	                                    .dashboardTableCell(isHeader: true, alignment: .trailing, width: fillsViewport ? nil : layout.numericWidth)
	                                    .contentShape(Rectangle())
	                                }
	                                .buttonStyle(.plain).disabled(t.isEmpty)
	                                .robotHelp(t.isEmpty ? I18n.t("dashboard.unattributed_tool") : String(format: I18n.t("panel.open_tool_detail"), toolIdToDisplay(t) ?? t))
	                                .accessibilityLabel(t.isEmpty ? I18n.t("dashboard.unattributed_tool") : String(format: I18n.t("panel.open_tool_detail"), toolIdToDisplay(t) ?? t))
	                                .pointingHandCursor(!t.isEmpty)
	                            }
	                            Text(I18n.t("dashboard.total"))
	                                .font(.caption2).bold().foregroundColor(.secondary)
	                                .dashboardTableCell(isHeader: true, width: fillsViewport ? nil : layout.numericWidth)
	                        }
	                        ForEach(Array(visibleModels.enumerated()), id: \.element) { idx, m in
	                            GridRow {
	                                Text((m.model.isEmpty ? I18n.t("dashboard.unknown_model") : m.model) + " · " + m.provider)
	                                    .font(.caption).lineLimit(1)
	                                    .dashboardTableCell(rowIndex: idx, alignment: .leading, width: fillsViewport ? nil : layout.modelWidth)
	                                    .contentShape(Rectangle())
	                                    .onTapGesture {
	                                        if let tool = matrixRows.first(where: { $0.model == m.model && $0.providerId == m.provider })?.toolId {
	                                            selectedToolForOverlay = tool
	                                        }
	                                    }
	                                    .pointingHandCursor()
	                                ForEach(toolIds, id: \.self) { t in
	                                    Text(tokenShort(Int(clamping: cellTokens(m, t))))
	                                        .font(.caption).monospacedDigit()
	                                        .dashboardTableCell(rowIndex: idx, width: fillsViewport ? nil : layout.numericWidth,
                                                            barFraction: DashboardDataPresentation.barFraction(value: Double(cellTokens(m, t)), maximum: Double(toolColumnMaxima[t] ?? 0)), barColor: .marsGreen)
	                                }
	                                Text(tokenShort(Int(clamping: modelTokens(m))))
	                                    .font(.caption).bold().monospacedDigit()
	                                    .dashboardTableCell(rowIndex: idx, width: fillsViewport ? nil : layout.numericWidth,
                                                        barFraction: DashboardDataPresentation.barFraction(value: Double(modelTokens(m)), maximum: Double(modelTotalMaximum)))
	                            }
	                        }
	                        // Total row participates in the zebra pattern (its shade
	                        // continues from the last data row).
	                        GridRow {
	                            Text(I18n.t("dashboard.total"))
	                                .font(.caption).bold()
	                                .dashboardTableCell(rowIndex: visibleModels.count, alignment: .leading, width: fillsViewport ? nil : layout.modelWidth)
	                            ForEach(toolIds, id: \.self) { t in
	                                Text(tokenShort(Int(clamping: toolTokens(t))))
	                                    .font(.caption).bold().monospacedDigit()
	                                    .dashboardTableCell(rowIndex: visibleModels.count, width: fillsViewport ? nil : layout.numericWidth)
	                            }
	                            Text(tokenShort(Int(clamping: grandTotal)))
	                                .font(.caption).bold().monospacedDigit()
	                                .dashboardTableCell(rowIndex: visibleModels.count, width: fillsViewport ? nil : layout.numericWidth)
	                            }
                }

        // ── Tool × model matrix ──
        if !modelNames.isEmpty {
            VStack(spacing: 12) {
                Text(I18n.t("dashboard.by_tool_model"))
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .robotHelp(I18n.t("dashboard.model_data_bar_help"))
                if fillsViewport {
                    // Same flexible Grid layout as the repository table.
                    table.frame(maxWidth: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        table.frame(width: layout.contentWidth, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: MatrixViewportWidthPreference.self, value: geometry.size.width)
                        }
                    }
                    .onPreferenceChange(MatrixViewportWidthPreference.self) { width in
                        guard width.isFinite, width > 0, abs(width - matrixViewportWidth) > 0.5 else { return }
                        matrixViewportWidth = width
                    }
                }
                if modelNames.count > ActivityMatrix.collapsedRowLimit {
                    Button(modelsExpanded ? I18n.t("dashboard.show_less") : I18n.t("dashboard.show_all")) {
                        withAnimation(reduceMotion ? nil : .default) { modelsExpanded.toggle() }
                    }
                    .font(.caption2)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .pointingHandCursor()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.15), lineWidth: 0.5))
        }
    }

    // MARK: - Body sections

    /// Repo list in the body: per-repo output (Git facts) + token usage
    /// (log facts). No estimated costs or CPL here.
    @ViewBuilder
    private var repoListSection: some View {
        let shownRepos = repos.filter {
            Self.shouldShowRepository(
                totalChanges: $0.totalChanges,
                tokens: $0.tokens ?? 0, commits: $0.commits)
        }
        if !shownRepos.isEmpty {
            let shown = reposExpanded ? shownRepos : Array(shownRepos.prefix(5))
            let totals = RepositoryTableTotals(repositories: shownRepos)
            let codeAvailable = activeSnapshot?.readFailures.contains("repositoryCode") != true
            // Use all eligible repositories, not just the collapsed first five.
            let tokenMaximum = shownRepos.compactMap(\.tokens).max() ?? 0
            let lineMaximum = shownRepos.map { max($0.added, $0.deleted) }.max() ?? 0
            let commitMaximum = shownRepos.map(\.commits).max() ?? 0
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n.t("dashboard.by_repo")).font(.caption).foregroundColor(.secondary)
                    .robotHelp(I18n.t("dashboard.repo_data_bar_help"))
                Grid(alignment: .leading, horizontalSpacing: 1, verticalSpacing: 1) {
                    GridRow {
                        Text(I18n.t("dashboard.repo"))
                            .font(.caption2).bold().foregroundColor(.secondary)
                            .dashboardTableCell(isHeader: true, alignment: .leading)
                        Text(I18n.t("dashboard.chart_tokens"))
                            .font(.caption2).bold().foregroundColor(.secondary)
                            .dashboardTableCell(isHeader: true)
                        Text(I18n.t("dashboard.code_added"))
                            .font(.caption2).bold().foregroundColor(.secondary)
                            .dashboardTableCell(isHeader: true)
                        Text(I18n.t("dashboard.code_deleted"))
                            .font(.caption2).bold().foregroundColor(.secondary)
                            .dashboardTableCell(isHeader: true)
                        Text(I18n.t("dashboard.commits"))
                            .font(.caption2).bold().foregroundColor(.secondary)
                            .dashboardTableCell(isHeader: true)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, r in
                        GridRow {
                            Text(r.name).robotHelp(r.repoPath)
                                .font(.caption).fontWeight(.medium).lineLimit(1)
                                .dashboardTableCell(rowIndex: idx, alignment: .leading)
                            Text(tokenShort(Int(clamping: r.tokens ?? 0)))
                                .font(.caption).monospacedDigit()
                                .dashboardTableCell(rowIndex: idx,
                                                    barFraction: DashboardDataPresentation.barFraction(value: r.tokens.map(Double.init), maximum: Double(tokenMaximum)))
                            Text("+" + ChartMath.compactCount(Int64(r.added)))
                                .font(.caption).monospacedDigit().foregroundColor(.marsGreen)
                                .dashboardTableCell(rowIndex: idx,
                                                    barFraction: DashboardDataPresentation.barFraction(value: Double(r.added), maximum: Double(lineMaximum)), barColor: .marsGreen)
                            Text("−" + ChartMath.compactCount(Int64(r.deleted)))
                                .font(.caption).monospacedDigit().foregroundColor(.red)
                                .dashboardTableCell(rowIndex: idx,
                                                    barFraction: DashboardDataPresentation.barFraction(value: Double(r.deleted), maximum: Double(lineMaximum)), barColor: .deepRed)
                            Text(ChartMath.compactCount(Int64(r.commits)))
                                .font(.caption).monospacedDigit()
                                .dashboardTableCell(rowIndex: idx,
                                                    barFraction: DashboardDataPresentation.barFraction(value: Double(r.commits), maximum: Double(commitMaximum)))
                        }
                    }
                    GridRow {
                        Text(I18n.t("dashboard.total"))
                            .font(.caption).bold()
                            .dashboardTableCell(rowIndex: shown.count, alignment: .leading)
                        Text(totals.tokens.map { ChartMath.compactCount($0) } ?? "—")
                            .font(.caption).bold().monospacedDigit()
                            .dashboardTableCell(rowIndex: shown.count)
                        Text(codeAvailable ? "+" + ChartMath.compactCount(totals.added) : "—")
                            .font(.caption).bold().monospacedDigit().foregroundStyle(Color.marsGreen)
                            .dashboardTableCell(rowIndex: shown.count)
                        Text(codeAvailable ? "−" + ChartMath.compactCount(totals.deleted) : "—")
                            .font(.caption).bold().monospacedDigit().foregroundStyle(Color.deepRed)
                            .dashboardTableCell(rowIndex: shown.count)
                        Text(codeAvailable ? ChartMath.compactCount(totals.commits) : "—")
                            .font(.caption).bold().monospacedDigit()
                            .dashboardTableCell(rowIndex: shown.count)
                    }
                }
                .frame(maxWidth: .infinity)
                if shownRepos.count > 5 {
                    Button(reposExpanded ? I18n.t("dashboard.show_less") : I18n.t("dashboard.show_all")) {
                        withAnimation(reduceMotion ? nil : .default) { reposExpanded.toggle() }
                    }
                    .font(.caption2)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.15), lineWidth: 0.5))
        }
    }

    // MARK: - Empty state (no integrations)

    var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(nsImage: AppIconLoader.uiImage(size: 56))
                .resizable().frame(width: 56, height: 56)
            Text(I18n.t("app.name")).font(.headline)
            Text(I18n.t("dashboard.empty_state"))
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity)
        .background(Color(nsColor: .quaternarySystemFill).opacity(0.3))
        .cornerRadius(10)
    }

    // MARK: - Date formatting

    var dateStride: AxisMarkValues {
        if timeRange.days <= 7 {
            return .stride(by: .day)
        } else {
            return .stride(by: .day, count: 10)
        }
    }

    var dateLabelFormat: Date.FormatStyle {
        .dateTime.month(.abbreviated).day().locale(I18n.resolvedLocale)
    }

    // MARK: - Data padding

    /// Number of days to display on charts (full week for thisWeek, rolling for days30).
    var chartDays: Int {
        if case .thisWeek = timeRange { return 7 }
        return timeRange.days
    }

    /// First date shown on charts (Monday for thisWeek, rolling start for days30).
    var chartStart: Date {
        let cal = Calendar.current
        if case .thisWeek = timeRange {
            return Calendar.mondayOfWeek()
        }
        return cal.date(byAdding: .day, value: -(timeRange.days - 1), to: cal.startOfDay(for: Date()))
            ?? cal.startOfDay(for: Date())
    }

    /// Charts' inferred date domain becomes degenerate when every mark uses the
    /// same calendar day (Today). Give it an explicit half-open day span so the
    /// framework always receives a finite interval with positive width.
    static func chartXDomain(start: Date, days: Int) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let safeDays = max(days, 1)
        let safeStart = calendar.startOfDay(for: start)
        let end = calendar.date(byAdding: .day, value: safeDays, to: safeStart)
            ?? safeStart.addingTimeInterval(Double(safeDays) * 86_400)
        return safeStart...end
    }

    func padStats(_ raw: [DailyStat], days queryDays: Int) -> [DailyStat] {
        let cal = Calendar.current
        let start = chartStart
        var map = [Date: DailyStat]()
        for s in raw { map[cal.startOfDay(for: s.date)] = s }

        var result = [DailyStat]()
        for offset in 0..<chartDays {
            guard let date = cal.date(byAdding: .day, value: offset, to: start) else { continue }
            if let s = map[date] {
                result.append(s)
            } else {
                result.append(DailyStat(date: date, calls: 0, tokens: 0, netLines: 0))
            }
        }
        return result
    }

    // MARK: - Helpers



    /// Format integer to short form (e.g. "1K", "15K", "1M", "980").
    func shortNum(_ n: Int) -> String {
        ChartMath.compactCount(Int64(n))
    }

    /// Format token count to short human-readable form (e.g. "12.3K", "1.2M").
    static func formattedTokenCount(_ tokens: Int) -> String {
        ChartMath.compactCount(Int64(tokens))
    }

    func tokenShort(_ tokens: Int) -> String {
        Self.formattedTokenCount(tokens)
    }

    private func rangeSinceMs() -> Int64 {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        switch timeRange {
        case .today:
            return Int64(todayStart.timeIntervalSince1970 * 1000)
        case .thisWeek:
            return Int64(Calendar.mondayOfWeek().timeIntervalSince1970 * 1000)
        case .days30:
            let start = cal.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
            return Int64(start.timeIntervalSince1970 * 1000)
        }
    }

    func balanceString(_ v: Double, currency: String) -> String {
        let symbol: String = {
            switch currency { case "CNY": return "¥"; case "EUR": return "€"; default: return "$" }
        }()
        if v >= 1000 { return "\(symbol)\(String(format: "%.0f", v))" }
        return "\(symbol)\(String(format: "%.2f", v))"
    }

    /// Comparison badge — just the arrow + percentage, no label.
    @ViewBuilder
    func comparisonBadge(current: Double, previous: Double) -> some View {
        let pct = ChartMath.percentageDelta(current: current, previous: previous, fallback: 0)
        if abs(pct) < 1 {
            Text("→")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color(nsColor: .quaternarySystemFill))
                .cornerRadius(4)
        } else if pct > 0 {
            let badge = "↑" + ChartMath.safeInt(round(pct)).formatted(.percent)
            Text(verbatim: badge)
                .font(.caption2).foregroundColor(.deepRed)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.deepRed.opacity(0.1))
                .cornerRadius(4)
        } else {
            let badge = "↓" + ChartMath.safeInt(round(-pct)).formatted(.percent)
            Text(verbatim: badge)
                .font(.caption2).foregroundColor(.marsGreen)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.marsGreen.opacity(0.1))
                .cornerRadius(4)
        }
    }

    // MARK: - Donut charts

    /// Data for subscription-vs-API donut chart.
    /// Gray placeholder ring shown when there's no data to fill a donut.
    /// Matches the 120×120 real chart; the caller renders the shared center value.
    func emptyDonut() -> some View {
        // Ring geometry matches the real donuts (SectorMark innerRadius .ratio(0.5)
        // in a 120×120 chart): inner radius 30, outer radius 60, thickness 30.
        // A larger lineWidth would bleed the stroke past the outer radius.
        Circle()
            .stroke(Color.secondary.opacity(0.12), lineWidth: 30)
            .frame(width: 90, height: 90)
            .frame(width: 100, height: 100)
    }

    /// Sync the cached dashboard snapshot to iCloud, throttled to 5 min.
    private func triggerCloudSync() {
        let syncKey = "lastCloudSyncTime"
        let lastSync = UserDefaults.standard.double(forKey: syncKey)
        let syncNow = Date().timeIntervalSince1970
        guard syncNow - lastSync >= 300 else { return }
        UserDefaults.standard.set(syncNow, forKey: syncKey)

        Task.detached(priority: .background) {
            await CloudSyncService.shared.syncFromCache()
        }
    }

    @ViewBuilder
    private var lastUpdatedFooter: some View {
        HStack(spacing: 6) {
            Text("AI Pulse v\(Self.appVersion)/CloudKit \(CKSchema.payloadVersion)")
                .font(.caption2).foregroundColor(.secondary)
            if let updated = lastUpdated {
                if isRefreshing {
                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                    Text(I18n.t("general.refreshing"))
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("\(I18n.t("dashboard.updated")) \(updated, format: .dateTime.minute().hour().day().month(.abbreviated))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await forceRefresh()
                    isRefreshing = false
                }
            } label: {
                Label(I18n.t("dashboard.refresh"), systemImage: "arrow.clockwise")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16).padding(.horizontal, 20)
    }

    @MainActor
    private func animateBarIfNeeded() {
        startEntryAnimation()
    }

    /// Each range owns its own task. Switching tabs only changes which snapshot
    /// is projected by `activeSnapshot`; it never cancels or overwrites another
    /// range's in-memory data.
    @MainActor
    private func scheduleLoad(for range: TimeRange) {
        rangeLoadTasks[range]?.cancel()
        rangeLoadTasks[range] = Task { await load(range: range) }
    }

    @MainActor
    private func refreshCurrentPulse() async {
        pulseRefreshGeneration &+= 1
        let generation = pulseRefreshGeneration
        let snapshot = await PulseEngine.shared.snapshot()
        guard generation == pulseRefreshGeneration, !Task.isCancelled else { return }
        currentPulse = snapshot?.isCurrent() == true ? snapshot : nil
    }

    @MainActor
    private func startEntryAnimation() {
        entryAnimationToken += 1
        if reduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { barProgress = 1 }
            return
        }
        let token = entryAnimationToken
        barProgress = 0

        // Let SwiftUI commit the zero-progress frame before beginning the
        // spring. One millisecond is enough to avoid transaction coalescing;
        // all actual movement is driven by the spring below.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000)
            guard entryAnimationToken == token, barProgress == 0, !reduceMotion else { return }
            withAnimation(.spring(response: 0.65, dampingFraction: 0.7)) {
                barProgress = 1
            }
        }
    }

    @MainActor
    private func forceRefresh() async {
        // Invalidate before computing, not after publishing. A tab selection
        // during the refresh then reads fresh facts, never the old cache.
        await DashboardCache.invalidateAll()
        let ranges = TimeRange.allCases
        for range in ranges {
            rangeLoadTasks[range]?.cancel()
            loadGenerationByRange[range, default: 0] += 1
        }
        let generations = loadGenerationByRange

        if DemoData.isActive {
            for range in ranges {
                let demo = DemoData.data(for: range)
                rangeSnapshots[range] = Self.demoSnapshot(demo, for: range)
                demoRanges.insert(range)
            }
            return
        }

        for range in ranges {
            let snap = await StatsService.dashboardSnapshot(period: range.periodKind)
            guard !Task.isCancelled,
                  generations[range] == loadGenerationByRange[range] else { continue }
            await storeSnapshot(snap, for: range)
        }
        triggerCloudSync()
        NotificationCenter.default.post(name: .dashboardRefresh, object: nil)
    }

    @MainActor
    private func storeSnapshot(_ rawSnap: DashboardSnapshot, for range: TimeRange, persist: Bool = true) async {
        let snap = rawSnap.sanitized()
        rangeSnapshots[range] = snap
        demoRanges.remove(range)

        let trendValues = (snap.dailyStats + snap.balanceDaily).map(\.value)
        let allFinite = trendValues.allSatisfy(\.isFinite)
            && snap.balanceDaily.allSatisfy { $0.ts.isFinite }
            && snap.dailyStats.allSatisfy { $0.ts.isFinite }
        DiagnosticJournal.log("store_snapshot", [
            "loaded_range": .string(range.cacheKey),
            "daily_count": .int(snap.dailyStats.count),
            "balance_day_count": .int(snap.balanceDaily.count),
            "code_count": .int(snap.codeChanges.count),
            "provider_count": .int(snap.providerBreakdown.count),
            "all_finite": .bool(allFinite),
        ])

        if persist {
            await DashboardCache.write(timeRange: range.cacheKey, json: snap.jsonString())
        }
    }

    private static func demoSnapshot(_ data: DemoData.RangeData, for range: TimeRange) -> DashboardSnapshot {
        DemoData.snapshot(data)
    }

    @MainActor
    func load(range requestedRange: TimeRange) async {
        // Today / Week / 30d are three independent in-memory channels. A newer
        // request invalidates only an older request for the same range.
        loadGenerationByRange[requestedRange, default: 0] += 1
        let myGen = loadGenerationByRange[requestedRange, default: 0]

        if requestedRange == timeRange { await loadUsageData() }
        guard !Task.isCancelled,
              myGen == loadGenerationByRange[requestedRange, default: 0] else { return }

        // ── Cache check — skip on initial load to avoid stale-data flash ──
        // Max age matches Phase 4 refresh intervals: today=5min, week=1h, 30d=12h
        let cacheMaxAge: TimeInterval = {
            switch requestedRange { case .today: return 300; case .thisWeek: return 3600; default: return 43200 }
        }()
        if !DemoData.isActive,
           let cached = await DashboardCache.read(timeRange: requestedRange.cacheKey, maxAge: cacheMaxAge),
           cached.tokenComposition != nil || cached.readFailures.contains("tokenComposition") {
            guard !Task.isCancelled,
                  myGen == loadGenerationByRange[requestedRange, default: 0] else { return }
            // Debounce data-change reloads only when staying on the same range;
            // a tab switch must always apply the new range's snapshot.
            if loadedTimeRange == requestedRange,
               let last = lastSnapshotTS, abs(cached.updatedAt.timeIntervalSince(last)) < 1 {
                // Hydration can restore the current range before this first
                // load runs; show it immediately instead of leaving entry
                // progress at zero.
                if requestedRange == timeRange { animateBarIfNeeded() }
                return
            }
            await storeSnapshot(cached, for: requestedRange)
            Logger.debug("Dashboard: loaded from cache (\(requestedRange.label))")
            return
        }

        // ── Demo mode: auto-activates when no integrations configured ──
        let demoActive = DemoData.isActive
        if demoActive {
            let d = DemoData.data(for: requestedRange)
            let snap = Self.demoSnapshot(d, for: requestedRange)
            guard !Task.isCancelled,
                  myGen == loadGenerationByRange[requestedRange, default: 0] else { return }
            rangeSnapshots[requestedRange] = snap
            demoRanges.insert(requestedRange)
            if requestedRange == timeRange { animateBarIfNeeded() }
            return
        }
        
        // ── Real data: use shared StatsService builder ──
        let snap = await StatsService.dashboardSnapshot(period: requestedRange.periodKind)

        guard !Task.isCancelled,
              myGen == loadGenerationByRange[requestedRange, default: 0] else { return }

        await storeSnapshot(snap, for: requestedRange)

        // ── Trigger entry animations (only when bars were reset by tab switch) ──
        if requestedRange == timeRange { animateBarIfNeeded() }
    }

    @MainActor
    private func hydrateRangeSnapshotCache() async {
        guard !DemoData.isActive else { return }
        let ranges: [(range: TimeRange, maxAge: TimeInterval)] = [
            (.today, 300),
            (.thisWeek, 3600),
            (.days30, 43200),
        ]

        for item in ranges where rangeSnapshots[item.range] == nil {
            guard let cached = await DashboardCache.read(timeRange: item.range.cacheKey, maxAge: item.maxAge) else { continue }
            rangeSnapshots[item.range] = cached.sanitized()
            DiagnosticJournal.log("snapshot_hydrate", [
                "range": .string(item.range.cacheKey),
            ])
        }
    }

}

private struct MatrixViewportWidthPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The one dashboard table cell style. Padding, row tint and hairline border
/// are applied to the same cell frame. The 1px Grid spacing is only the gap
/// between cells; it never becomes a second container around the cell.
private extension View {
    func dashboardTableCell(
        rowIndex: Int? = nil,
        isHeader: Bool = false,
        alignment: Alignment = .trailing,
        width: CGFloat? = nil,
        barFraction: Double? = nil,
        barColor: Color = .accentColor
    ) -> some View {
        frame(maxWidth: .infinity, alignment: alignment)
            .padding(2)
            .frame(width: width, alignment: alignment)
            .background(alignment: .leading) {
                if let barFraction, barFraction > 0 {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(barColor.opacity(0.16))
                            .frame(width: geometry.size.width * barFraction)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .background(cellBackground(rowIndex: rowIndex, isHeader: isHeader))
            .overlay(
                Rectangle()
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
            )
    }

    private func cellBackground(rowIndex: Int?, isHeader: Bool) -> Color {
        if isHeader { return Color.secondary.opacity(0.08) }
        guard let rowIndex else { return .clear }
        return rowIndex.isMultiple(of: 2) ? .clear : Color.secondary.opacity(0.04)
    }
}

// Compact robot overview. Existing range snapshots and drill-downs remain the source of truth.
private extension DashboardView {
    var robotDashboard: some View {
        ZStack {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Circle().fill(robotEarSurface).frame(width: 13, height: 13)
                        .overlay(Circle().stroke(robotLine, lineWidth: 1))
                    Rectangle().fill(Color.marsGreenLight).frame(width: 2, height: 10)
                }.frame(height: 23).accessibilityHidden(true)
                Group {
                    if let toolId = selectedToolForOverlay {
                        ToolDetailOverlayView(toolId: toolId, sinceMs: rangeSinceMs(), onBack: { selectedToolForOverlay = nil }, embedded: true)
                            .padding(14)
                    } else if let detail = robotDetail {
                        robotHeadDetail(detail)
                    } else {
                VStack(spacing: 9) {
                    HStack(alignment: .top) {
                        Button { DashboardWindowManager.shared.close() } label: { Image(systemName: "xmark") }
                            .robotHelp(pulseText("收起仪表盘", "Dismiss dashboard"))
                        Spacer()
                        robotForehead
                        Spacer()
                        Button { DashboardWindowManager.shared.openSettings() } label: { Image(systemName: "gearshape") }
                            .robotHelp(I18n.t("menu.preferences"))
                    }
                    .foregroundStyle(.secondary)
                    periodPicker
                    HStack(alignment: .center, spacing: 16) {
                        VStack(spacing: 7) {
                            toolTokenDonut()
                            robotLink(pulseText("工具与模型", "Tools & models"), detail: "tools")
                        }
                        robotNose
                        VStack(spacing: 7) {
                            repoCodeDonut()
                            robotLink(pulseText("全部仓库", "All repositories"), detail: "repos")
                        }
                    }
                    .frame(height: 200, alignment: .top)
                    robotMouth
                }
                .padding(14)
                    }
                }
                .frame(width: 440, height: 440)
                .background(RoundedRectangle(cornerRadius: 29).fill(robotSurface))
                .overlay(RoundedRectangle(cornerRadius: 29).stroke(Color.primary.opacity(0.14)))
                .overlay(alignment: .leading) { earView(width: 9, height: 39).offset(x: -9) }
                .overlay(alignment: .trailing) { earView(width: 9, height: 39).offset(x: 9) }
                Rectangle().fill(robotSurface).frame(width: 76, height: 8)
                    .overlay(HStack { Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1); Spacer(); Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1) })
                robotBase
            }
            .background(RobotSilhouette().fill(robotSurface).shadow(color: .black.opacity(0.27), radius: 14, y: 5))
            .padding(.horizontal, 60)
            .padding(.vertical, 14)
            .buttonStyle(.plain)
        }
        .overlayPreferenceValue(RobotTooltipPreference.self) { hints in
            GeometryReader { geometry in
                if let hint = hints.last {
                    let bounds = geometry[hint.anchor]
                    let below = bounds.midY < geometry.size.height / 2
                    Text(hint.text)
                        .font(.system(size: 11)).foregroundStyle(Color.primary)
                        .lineSpacing(3).padding(12)
                        .frame(width: 280, alignment: .leading)
                        .background(robotEyeSurface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(robotLine))
                        .frame(width: 280, height: 190, alignment: below ? .top : .bottom)
                        .offset(x: min(max(bounds.midX - 140, 12), geometry.size.width - 292), y: below ? bounds.maxY + 7 : bounds.minY - 197)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .allowsHitTesting(false)
        }
        .onExitCommand {
            if selectedToolForOverlay != nil { selectedToolForOverlay = nil }
            else if robotDetail != nil { robotDetail = nil }
            else { DashboardWindowManager.shared.close() }
        }
    }

    var foreheadMessage: String? {
        if isDemoMode { return I18n.t("demo.banner") }
        if !localDataStatus.canReportCurrentActivity { return SetupCopy.activity(localDataStatus.activity) }
        if healthSeverity >= .impaired { return healthMessages.first ?? robotDataStatus }
        if isImportingHistory { return I18n.t("menu.loading") }
        if showScanCompletion { return SetupCopy.activity(.ready) }
        return nil
    }

    var robotForehead: some View {
        Group {
            if let message = foreheadMessage {
                HStack(spacing: 8) {
                    Text(message).font(.system(size: 11)).lineLimit(2)
                    if localDataStatus.activity == .needsAccess || localDataStatus.activity == .accessExpired {
                        Button {
                            guard BookmarkManager.requestHomeAccess(message: I18n.t("bookmark.home_message")) != nil else { return }
                            LogWatcher.shared.start()
                            DataRefreshCoordinator.shared.triggerIngest()
                            refreshLocalScanStatus()
                        } label: { Image(systemName: "arrow.up.right") }
                        .robotHelp(SetupCopy.text("授权主目录", "Authorize home folder"))
                    } else if localDataStatus.activity == .failed || localDataStatus.activity == .stale || healthSeverity >= .impaired {
                        Button { robotDetail = "metadata" } label: { Image(systemName: "arrow.up.right") }
                    }
                }.padding(.horizontal, 12)
            } else {
                RobotPulseCurve(tier: currentPulse?.isCurrent() == true ? currentPulse?.tier : nil)
                    .stroke(robotPulseColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 125, height: 38)
                    .robotHelp(PulseAppearance(tier: currentPulse?.tier).label + "\n" + PulseCopy.recentFacts(currentPulse?.activityFacts) + "\n" + StatusItemController.detail(snapshot: currentPulse) + "\n" + SetupCopy.text("当前强度不受下方时间范围影响。", "Current intensity is independent of the range below."))
                    .accessibilityLabel(SetupCopy.text("当前 AI 活动强度：", "Current AI activity: ") + PulseAppearance(tier: currentPulse?.tier).label)
            }
        }
        .frame(width: 270, height: 57)
        .background(robotEyeSurface, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(robotLine))
    }

    func robotHeadDetail(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { robotDetail = nil } label: {
                    Label(pulseText("返回", "Back"), systemImage: "arrow.left")
                        .font(.system(size: 11))
                }

            }.foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(robotDetailTitle(detail)).font(.headline)
                Spacer()
                Text(timeRange.label).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                robotDetailContent(detail)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
    }

    var robotSurface: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.14, green: 0.17, blue: 0.15, alpha: 1)
                : NSColor(srgbRed: 233/255, green: 236/255, blue: 229/255, alpha: 1)
        })
    }
    var robotEyeSurface: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.19, green: 0.22, blue: 0.20, alpha: 1)
                : NSColor(srgbRed: 248/255, green: 249/255, blue: 245/255, alpha: 1)
        })
    }

    var robotCacheColor: Color {
        colorScheme == .dark ? Color(red: 0.30, green: 0.43, blue: 0.36) : .marsGreenLight
    }

    var robotEarSurface: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.32, green: 0.40, blue: 0.34, alpha: 1)
                : NSColor(srgbRed: 218/255, green: 229/255, blue: 218/255, alpha: 1)
        })
    }

    var robotLine: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 61/255, green: 73/255, blue: 63/255, alpha: 1)
                : NSColor(srgbRed: 212/255, green: 218/255, blue: 209/255, alpha: 1)
        })
    }

    func robotFlatRing(_ segments: [DonutItem]) -> some View {
        let total = segments.reduce(0.0) { $0 + $1.tokens }
        return ZStack {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, item in
                let start = segments.prefix(index).reduce(0.0) { $0 + $1.tokens } / max(total, 1)
                Circle().trim(from: start, to: start + item.tokens / max(total, 1))
                    .stroke(item.color, style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90)).frame(width: 110, height: 110)
            }
        }.frame(width: 120, height: 120)
    }

    var robotPulseColor: Color {
        switch localDataStatus.canReportCurrentActivity ? currentPulse?.tier : nil {
        case .active: return .marsGreen
        case .elevated, .intense: return .deepRed
        default: return .secondary
        }
    }

    func robotLink(_ title: String, detail: String) -> some View {
        Button { selectedToolForOverlay = nil; robotDetail = detail } label: {
            HStack(spacing: 4) { Text(title); Image(systemName: "arrow.up.right").font(.system(size: 8)) }
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.buttonStyle(.plain)
    }

    var robotNose: some View {
        let composition = activeSnapshot?.tokenComposition
        let values = [Double(composition?.nonCachedInput ?? 0), Double(composition?.cachedInput ?? 0), Double(composition?.output ?? 0)]
        let fractions = DashboardDataPresentation.noseFractions(values: values)
        return Group {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        Rectangle().fill([Color.marsGreen, robotCacheColor, .deepRed][index])
                            .opacity(values[index] > 0 ? 1 : 0.25)
                            .frame(width: geometry.size.width * fractions[index])
                            .overlay {
                                if index == 1 {
                                    let input = values[0] + values[1]
                                    Text(input > 0 ? String(format: "%.0f%%", values[1] / input * 100) : "—")
                                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(Color(nsColor: .labelColor))
                                        .lineLimit(1).minimumScaleFactor(0.5)
                                }
                            }
                    }
                }
                .opacity(composition != nil ? 1 : 0.25)
                .clipShape(CodeChangeTrapezoid())
            }.frame(width: 44, height: 55)
        }
        .frame(width: 60)
        .accessibilityLabel(pulseText("词元构成，已知输入缓存率", "Token composition, cache rate of known input"))
        .accessibilityValue(values[0] + values[1] > 0 ? String(format: "%.1f%%", values[1] / (values[0] + values[1]) * 100) : "—")
    }

    var robotMouth: some View {
        VStack(spacing: 5) {
            HStack {
                Text(pulseText("活动节奏（词元｜行数）", "Activity rhythm (Tokens | Lines)"))
                Spacer()
                Text(timeRange == .today ? pulseText("按小时", "Hourly") : pulseText("按天", "Daily"))
            }.font(.system(size: 9)).foregroundStyle(.secondary)
            robotRhythmRow(label: pulseText("词元", "Tokens"), values: tokenRhythmValues, color: .marsGreen, growsDownward: true)
            robotRhythmRow(label: pulseText("行数", "Lines"), values: codeRhythmValues, color: .deepRed2, growsDownward: false)
        }
        .frame(width: 350, height: 70).padding(10)
        .background(robotEyeSurface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(robotLine, lineWidth: 1))
    }

    func robotRhythmRow(label: String, values: [Double], color: Color, growsDownward: Bool) -> some View {
        let slots = DashboardDataPresentation.rhythmSlots(values: values, count: timeRange == .today ? 24 : chartDays, surroundingWeeks: timeRange == .thisWeek)
        let peak = max(values.max() ?? 0, 1)
        return Group {
            if values.allSatisfy({ $0 == 0 }) && ((growsDownward && !localDataStatus.canReportCurrentActivity) || (!growsDownward && localDataStatus.repositories != .ready)) {
                Text(growsDownward ? SetupCopy.activity(localDataStatus.activity) : SetupCopy.repositories(localDataStatus.repositories))
                    .font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else {
        HStack(alignment: growsDownward ? .top : .bottom, spacing: 3) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, value in
                Capsule()
                    .fill(value.map { $0 > 0 ? color : Color.secondary.opacity(0.14) } ?? Color.secondary.opacity(0.14))
                    .frame(maxWidth: .infinity)
                    .frame(height: value.map { max(3, 21 * $0 / peak) } ?? 3)
                    .robotHelp(value.map { label + ": " + ChartMath.compactCount(Int64($0)) } ?? (index < 7 ? pulseText("上一周占位", "Previous week placeholder") : pulseText("下一周占位", "Next week placeholder")))
            }
        }
            }
        }.frame(height: 23, alignment: growsDownward ? .top : .bottom)
        .accessibilityLabel(label)
    }

    var robotObservedLabel: String {
        guard let snapshot = activeSnapshot, !snapshot.readFailures.contains("observedSpend") else { return "—" }
        let amounts = snapshot.observedSpend ?? []
        guard !amounts.isEmpty else { return pulseText("暂无观测", "No observations") }
        let currencies = Set(amounts.map { $0.currency.uppercased() })
        guard currencies.count == 1, let currency = currencies.first else { return pulseText("多币种 · 查看", "Multiple currencies") }
        return currency + " " + String(format: "%.2f", amounts.reduce(0) { $0 + $1.amount })
    }

    var robotBase: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(I18n.t("dashboard.account_observations")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(robotObservedLabel).font(.system(size: 18, weight: .medium)).monospacedDigit()
                    robotLink(pulseText("账户观测明细", "Observation details"), detail: "spend")
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text(I18n.t("dashboard.fixed_monthly_context")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(activeSnapshot?.declaredMonthlyCostUSD.map { "USD " + String(format: "%.2f", $0) + pulseText(" / 月", " / mo") } ?? "—")
                        .font(.system(size: 18, weight: .medium)).monospacedDigit()
                    robotLink(pulseText("固定费用说明", "Fixed cost context"), detail: "subscription")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            VStack(spacing: 5) {
                HStack {
                    Text(robotDataStatus).foregroundStyle(healthSeverity >= .impaired ? Color.deepRed : Color.secondary)
                    Spacer()
                    robotLink(pulseText("数据说明", "Data details"), detail: "metadata")
                }
                HStack {
                    Text("AI Pulse " + Self.appVersion)
                    Spacer()
                    Text(pulseText("数据版本 ", "Data format ") + (activeSnapshot?.payloadVersion ?? CKSchema.payloadVersion))
                }.foregroundStyle(.secondary)
            }.font(.system(size: 9)).padding(.horizontal, 20).padding(.vertical, 10)
                .background(Color.primary.opacity(0.035))
        }
        .frame(width: 440, height: 128)
        .background(RoundedRectangle(cornerRadius: 16).fill(robotEyeSurface))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.14)))

    }

    var robotDataStatus: String {
        if isDemoMode { return pulseText("演示数据", "Demo data") }
        if !localDataStatus.canReportCurrentActivity { return SetupCopy.activity(localDataStatus.activity) + (lastUpdated.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? "") }
        if healthSeverity != .nominal { return healthBannerText }
        if !(activeSnapshot?.readFailures ?? []).isEmpty { return pulseText("部分读取失败", "Some queries failed") }
        if tokenCoverageNote != nil { return pulseText("部分采集 · ", "Partial coverage · ") + (lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "—") }
        return pulseText("本地数据 · ", "Local data · ") + (lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "—")
    }

    func robotDetailTitle(_ detail: String) -> String {
        switch detail {
        case "pulse": return pulseText("当前 AI 活动强度", "Current AI activity intensity")
        case "tools": return pulseText("工具与模型", "Tools & models")
        case "repos": return pulseText("仓库明细", "Repository details")
        case "composition": return pulseText("词元构成", "Token composition")
        case "rhythm": return pulseText("活动趋势", "Activity trends")
        case "spend": return I18n.t("dashboard.account_observations")
        case "subscription": return I18n.t("dashboard.fixed_monthly_context")
        default: return pulseText("数据说明", "Data details")
        }
    }

    @ViewBuilder func robotDetailContent(_ detail: String) -> some View {
        switch detail {
        case "pulse":
            VStack(alignment: .leading, spacing: 12) {
                Text(PulseAppearance(tier: currentPulse?.tier).label).font(.title2)
                Text(PulseCopy.recentFacts(currentPulse?.activityFacts))
                Text(StatusItemController.detail(snapshot: currentPulse))
                Text(pulseText("基于最近一小时的词元活动，约每 10 分钟权重减半；参照最近 7 天活跃小时的中位数。历史不足时使用固定参考。", "Based on the last hour of token activity, with a ten-minute half-life and a median active-hour baseline over seven days. Limited history uses a fixed reference."))
                Text(pulseText("状态始终代表当前时刻，不表示额度、费用或工作效率。", "This state is current, independent of the selected range; it is not quota, money or productivity."))
            }.font(.callout)
        case "tools":
            VStack(alignment: .leading, spacing: 12) {
                ForEach(activeSnapshot?.toolBreakdown ?? [], id: \.toolId) { tool in
                    Button { selectedToolForOverlay = tool.toolId } label: {
                        HStack { Text(tool.name); Spacer(); Text(tool.tokens.map { ChartMath.compactCount($0) } ?? "—"); Image(systemName: "chevron.right") }
                    }.buttonStyle(.plain).padding(9)
                }
                outputSection
            }
        case "repos": repoListSection
        case "composition":
            if let parts = activeSnapshot?.tokenComposition {
                VStack(alignment: .leading, spacing: 14) {
                    robotCompositionRow(pulseText("未缓存输入", "Uncached input"), value: parts.nonCachedInput, color: .marsGreen)
                    robotCompositionRow(pulseText("缓存命中输入", "Cached input"), value: parts.cachedInput, color: .marsGreenLight)
                    robotCompositionRow(pulseText("输出", "Output"), value: parts.output, color: .deepRed)
                    Text(pulseText("前两段共同构成输入；缓存命中不重复累加，缓存写入不标为缓存命中。鼻梁为可读性给每段保留最小宽度，剩余宽度按真实比例分配；准确数值在明细中显示。", "The first two segments form input. Cache reads are not counted twice; cache creation is not a cache hit. Segment widths include a visibility floor; details show exact amounts."))
                        .font(.caption).foregroundStyle(.secondary)
                    if parts.isPartial { Text(pulseText("部分字段缺失，仅包含已知词元。", "Some components are missing; totals contain known tokens only.")).foregroundStyle(.secondary) }
                }
            } else { Text(pulseText("词元构成暂不可用，刷新后重试。", "Token composition unavailable; refresh and retry.")) }
        case "rhythm": activityRhythmSection
        case "spend":
            VStack(alignment: .leading, spacing: 14) {
                ForEach(activeSnapshot?.observedSpend ?? [], id: \.stableId) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(ProviderRegistry.byId(item.providerId)?.name ?? item.providerId); Spacer(); Text(item.currency.uppercased() + " " + String(format: "%.2f", item.amount)) }
                        Text(observedAmountIntervalHelp(item)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(I18n.t("dashboard.balance_observation_help")).font(.caption).foregroundStyle(.secondary)
                if (activeSnapshot?.observedSpend ?? []).isEmpty { Text(robotObservedLabel) }
            }
        case "subscription":
            VStack(alignment: .leading, spacing: 12) {
                Text(I18n.t("dashboard.fixed_monthly_help"))
                Text(pulseText("声明固定月费：", "Declared monthly cost: ") + (activeSnapshot?.declaredMonthlyCostUSD.map { "USD " + String(format: "%.2f", $0) } ?? "—"))
                ForEach(IntegrationRegistry.activeCostSources(editorMappings: editorMappings)) { source in
                    if case .subscription(_, _, let fee) = source.kind {
                        HStack { Text(source.label); Spacer(); Text("USD " + String(format: "%.2f", fee)) }
                    }
                }
                Button(I18n.t("menu.preferences")) { DashboardWindowManager.shared.openSettings() }
            }
        default:
            VStack(alignment: .leading, spacing: 12) {
                Text(robotDataStatus)
                if let note = tokenCoverageNote { Text(note) }
                ForEach(activeSnapshot?.readFailures ?? [], id: \.self) { Text($0) }
                ForEach(healthMessages, id: \.self) { Text($0) }
                Text(pulseText("本地活动与账户观测分别更新；费用与代码产出分别呈现。", "Local activity and account observations update separately; money and Git output remain independent."))
                Text("AI Pulse " + Self.appVersion + " / " + (activeSnapshot?.payloadVersion ?? CKSchema.payloadVersion))
                Button(pulseText("刷新数据", "Refresh data")) { Task { await forceRefresh() } }.disabled(isRefreshing)
            }
        }
    }

    func robotCompositionRow(_ title: String, value: Int64, color: Color) -> some View {
        HStack { Circle().fill(color).frame(width: 7, height: 7); Text(title); Spacer(); Text(ChartMath.compactCount(value)).monospacedDigit() }
    }
}

// A single filled silhouette casts the shadow without shadowing interior widgets.
private struct RobotSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 0, y: 23, width: 440, height: 440), cornerSize: CGSize(width: 29, height: 29))
        path.addRect(CGRect(x: 182, y: 462, width: 76, height: 10))
        path.addRoundedRect(in: CGRect(x: 0, y: 471, width: 440, height: 128), cornerSize: CGSize(width: 16, height: 16))
        path.addRoundedRect(in: CGRect(x: -9, y: 223.5, width: 10, height: 39), cornerSize: CGSize(width: 4, height: 4))
        path.addRoundedRect(in: CGRect(x: 439, y: 223.5, width: 10, height: 39), cornerSize: CGSize(width: 4, height: 4))
        path.addEllipse(in: CGRect(x: 213.5, y: 0, width: 13, height: 13))
        path.addRect(CGRect(x: 219, y: 12, width: 2, height: 12))
        return path
    }
}

private struct RobotPulseCurve: Shape {
    var tier: PulseTier?
    func path(in rect: CGRect) -> Path {
        let strength: CGFloat = tier == nil || tier == .resting ? 0.15 : tier == .intense ? 1 : tier == .elevated ? 0.88 : 0.72
        // Unequal peaks and troughs follow the approved symbol; not a fabricated time series.
        let points: [(CGFloat, CGFloat)] = [(0,0),(0.18,0),(0.28,-0.28),(0.37,0.22),(0.46,-0.46),(0.57,0.42),(0.67,-0.18),(0.77,0.08),(0.87,0),(1,0)]
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        for index in 1..<points.count {
            let a = points[index-1], b = points[index]
            let x1 = rect.minX + rect.width * a.0, x2 = rect.minX + rect.width * b.0
            let y1 = rect.midY + rect.height * a.1 * strength, y2 = rect.midY + rect.height * b.1 * strength
            path.addCurve(to: CGPoint(x: x2, y: y2), control1: CGPoint(x: (x1+x2)/2, y: y1), control2: CGPoint(x: (x1+x2)/2, y: y2))
        }
        return path
    }
}

struct RobotTooltipHint {
    let text: String
    let anchor: Anchor<CGRect>
}

struct RobotTooltipPreference: PreferenceKey {
    static var defaultValue: [RobotTooltipHint] { [] }
    static func reduce(value: inout [RobotTooltipHint], nextValue: () -> [RobotTooltipHint]) {
        value.append(contentsOf: nextValue())
    }
}

private struct RobotTooltipModifier: ViewModifier {
    let text: String
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .anchorPreference(key: RobotTooltipPreference.self, value: .bounds) { anchor in
                hovered && !text.isEmpty ? [RobotTooltipHint(text: text, anchor: anchor)] : []
            }
    }
}

extension View {
    func robotHelp(_ text: String) -> some View {
        modifier(RobotTooltipModifier(text: text))
    }
}
