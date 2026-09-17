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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    let initialTimeRange: TimeRange

    @State private var timeRange: TimeRange
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
    @State private var isImportingHistory = LogWatcher.backfill.isActive
    @State private var localScanStatus = LogScanObservation.Status.inactive

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


    private var repoTokens: [String: Int64] {
        activeSnapshot?.topRepos.reduce(into: [String: Int64]()) { map, repo in
            map[repo.repoPath, default: 0] += repo.tokens ?? 0
        } ?? [:]
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
        guard activeSnapshot?.readFailures.contains("dashboardUsageStats") != true else {
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
        let failed = AppHealthMonitor.shared.failingIngestSources.contains {
            $0.lowercased().hasPrefix("log.")
        }
        localScanStatus = LogScanObservation.shared.status(hasReadFailure: failed)
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
            .fill(Color.marsGreen.opacity(0.20))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.marsGreen.opacity(0.35), lineWidth: 1.5)
            )
            .frame(width: width, height: height)
    }

    var body: some View {
        ZStack {
            dashboardContent
                .disabled(selectedToolForOverlay != nil)
                .allowsHitTesting(selectedToolForOverlay == nil)
                .accessibilityHidden(selectedToolForOverlay != nil)
            if let toolId = selectedToolForOverlay {
                ToolDetailOverlayView(
                    toolId: toolId,
                    sinceMs: rangeSinceMs(),
                    onClose: { selectedToolForOverlay = nil })
                    .transition(.opacity)
            }
        }
    }

    private var dashboardContent: some View {
        VStack(spacing: 0) {
            // Error banner — visible when health is not nominal
            if healthSeverity >= .degraded {
                VStack(spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? nil : .default) { showHealthDetails.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: healthSeverity == .critical
                                  ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            Text(healthBannerText)
                                .font(.caption).fontWeight(.medium)
                            Spacer()
                            if !healthMessages.isEmpty {
                                Image(systemName: showHealthDetails
                                      ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundColor(healthSeverity == .critical ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .background(healthBannerColor)

                    if showHealthDetails {
                        VStack(alignment: .leading, spacing: 4) {
                            if !healthMessages.isEmpty {
                                ForEach(healthMessages.suffix(5), id: \.self) { msg in
                                    Text(msg).font(.caption2).foregroundColor(.secondary)
                                }
                            }

                            HStack(spacing: 4) {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [Logger.logFileURL])
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "folder").font(.caption2)
                                        Text(I18n.t("health.open_log")).font(.caption2)
                                    }
                                }
                                .buttonStyle(.link)

                                Text(I18n.t("health.send_to_dev"))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(healthBannerColor.opacity(0.3))
                    }
                }
                .cornerRadius(6)
                .padding(.horizontal).padding(.bottom, 8)
            }

            HStack {
                Text(I18n.t("dashboard.title")).font(.title2).fontWeight(.bold)
                Spacer()
                Picker("", selection: Binding(
                    get: { timeRange },
                    set: { newValue in
                        // Child .task runs before onChange, so stamp the intent
                        // before committing the range to keep render timing honest.
                        rangeChangeStartedAt = Date()
                        timeRange = newValue
                    }
                )) {
                    Text(I18n.t("dashboard.today")).tag(TimeRange.today)
                    Text(I18n.t("dashboard.this_week")).tag(TimeRange.thisWeek)
                    Text(I18n.t("dashboard.days_30")).tag(TimeRange.days30)
                }.pickerStyle(.segmented).frame(width: 240).pointingHandCursor()
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 0) {
                    if isDemoMode {
                        HStack(spacing: 6) {
                            Text(I18n.t("demo.banner"))
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.08))
                    }
                    if isImportingHistory {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                            Text(I18n.t("menu.loading"))
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.08))
                    }
                    if !isDemoMode {
                        Text(localScanStatusText)
                            .font(.caption2).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                    }
                    if hasActiveCostSources || !balanceSpend.isEmpty || hasPulseActivity || isDemoMode {
                        // ── Robot head frame — pulse, activity, distribution, output ──
                        VStack(spacing: 16) {
                            spendingOverview
                            activityRhythmSection
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.marsGreen.opacity(0.3), lineWidth: 2)
                                .overlay(alignment: .top) {
                                    ZStack(alignment: .top) {
                                        Path { p in
                                            p.addArc(center: CGPoint(x: 20, y: 2),
                                                     radius: 20,
                                                     startAngle: .degrees(180), endAngle: .degrees(0),
                                                     clockwise: false)
                                        }
                                        .stroke(Color.marsGreen.opacity(0.3), lineWidth: 2)
                                        .frame(width: 40, height: 22)
                                        Circle()
                                            .fill(Color.marsGreen.opacity(0.4))
                                            .frame(width: 6, height: 6)
                                            .offset(y: -10)
                                    }
                                    .offset(y: -6)
                                }
                                .overlay(alignment: .leading) {
                                    HStack(spacing: 6) {
                                        earView(width: 14, height: 34)
                                        earView(width: 8, height: 22)
                                    }
                                    .offset(x: -16, y: -80)
                                }
                                .overlay(alignment: .trailing) {
                                    HStack(spacing: 6) {
                                        earView(width: 8, height: 22)
                                        earView(width: 14, height: 34)
                                    }
                                    .offset(x: 16, y: -80)
                                }
                        )
                        .padding(.horizontal, 60).padding(.top, 60).padding(.bottom, 12)

                        // Body: one outer frame hosting trend/balance + repos
                        VStack(spacing: 12) {
                            pulseFactsSection
                            outputSection
                            repoListSection
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.marsGreen.opacity(0.25), lineWidth: 2)
                        )
                        .padding(.horizontal, 60)
                        Spacer().frame(height: 60)
                    } else {
                        emptyStateCard
                    }

                    lastUpdatedFooter
                }
            }
        }
        .frame(width: 700, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
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
        .help(clamped > 90 ? I18n.t("dashboard.usage_help") : I18n.t("dashboard.usage_percent"))
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

    /// Nose: vertical overlapping bars. Added runs top-down, deleted runs
    /// bottom-up; the overlap is the net line change. Max height is the larger
    /// of the two, so the visible difference is exactly |added−deleted|/max.
    /// Labels sit inside the bar at top (added), middle (net), bottom (deleted).
    @ViewBuilder var noseStatCards: some View {
        let added = codeChanges.reduce(0) { $0 + $1.added }
        let deleted = codeChanges.reduce(0) { $0 + $1.deleted }
        let netLines = added - deleted
        let maxVal = Double(max(added, deleted, 1))
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .quaternarySystemFill).opacity(0.35))
                VStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.deepRed.opacity(0.55))
                        .frame(height: geo.size.height * Double(deleted) / maxVal)
                }
                VStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.marsGreen.opacity(0.85))
                        .frame(height: geo.size.height * Double(added) / maxVal)
                    Spacer()
                }
                VStack(spacing: 0) {
                    Text("+\(ChartMath.compactCount(Int64(added)))")
                        .font(.caption2).fontWeight(.semibold).monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.marsGreen.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                    Spacer()
                    Text(netLines >= 0
                         ? "+\(ChartMath.compactCount(Int64(netLines)))"
                         : ChartMath.compactCount(Int64(netLines)))
                        .font(.system(size: 13, weight: .bold)).monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    Spacer()
                    Text("-\(ChartMath.compactCount(Int64(deleted)))")
                        .font(.caption2).fontWeight(.semibold).monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.deepRed.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .frame(width: 64, height: 150)
    }

    // MARK: - Head overview (forehead activity · eyes distributions · nose output)

    var spendingOverview: some View {
        // Forehead: usage is the primary number — pure JSONL facts.
        let rangeTokens = dailyStats.reduce(Int64(0)) { $0 + Int64($1.tokens) }
        let pulseTier = currentPulse?.isCurrent() == true ? currentPulse?.tier : nil

        return VStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle().fill(pulseColor(pulseTier)).frame(width: 8, height: 8)
                    .help(currentPulse?.isCurrent() == true
                          ? StatusItemController.detail(snapshot: currentPulse) + "\n" + I18n.t("pulse.activity.legend")
                          : I18n.t("pulse.reason.unavailable"))
                Text(rangeTokenRateText)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            // ── Forehead: usage ──
            VStack(spacing: 4) {
                Text(activeSnapshot?.readFailures.contains("dashboardUsageStats") == true
                     ? "—" : tokenShort(Int(clamping: rangeTokens)))
                    .font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.marsGreen)
                    .scaleEffect(loadedTimeRange == timeRange ? (0.8 + 0.2 * barProgress) : 0.8)
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6), value: barProgress)
                HStack(spacing: 4) {
                    Text("\(timeRange.label) · \(activeSnapshot?.readFailures.contains("toolUsage") == true ? "—" : String(periodSessionCount)) \(pulseText("个会话", "sessions")) · \(activeSnapshot?.readFailures.contains("dashboardUsageStats") == true ? "—" : String(periodActiveDays)) \(pulseText("个活跃日", "active days")) · \(pulseText("词元", "tokens"))")
                        .font(.caption).foregroundColor(.secondary)
                    Text(I18n.t("dashboard.source_logs"))
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 3)

            // ── Eyes + nose ──
            HStack(alignment: .top, spacing: 12) {
                toolTokenDonut()

                // Nose: code lines
                VStack(spacing: 6) {
                    noseStatCards
                    Text("\(ChartMath.compactCount(Int64(periodCommitCount))) \(I18n.t("dashboard.commits"))")
                        .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                }
                .frame(width: 100)

                repoTokenDonut()
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
    }

    /// Left eye: observed token share by AI tool. Money and subscriptions do
    /// not enter the robot face.
    @ViewBuilder
    func toolTokenDonut() -> some View {
        let rawSegments = (activeSnapshot?.toolBreakdown ?? []).compactMap { item -> DonutItem? in
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
            ZStack {
                if !segments.isEmpty {
                    Chart(segments) { item in
                        SectorMark(angle: .value("Tokens", item.tokens), innerRadius: .ratio(0.5), angularInset: 1)
                            .foregroundStyle(item.color)
                    }
                    .chartLegend(.hidden)
                    .chartForegroundStyleScale(
                        domain: segments.map(\.label),
                        range: segments.map(\.color))
                    .frame(width: 120, height: 120)
                    .id("tool-\(timeRange.cacheKey)")
                    .transaction { $0.animation = nil }
                } else {
                    emptyDonut()
                }
                Text(tokenShort(Int(clamping: Int64(totalTokens))))
                    .font(.system(size: Self.donutCenterFontSize(for: totalTokens), weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.deepRed)
            }
            VStack(spacing: 2) {
                ForEach(segments.prefix(3)) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.label).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                        Spacer()
                        Text(verbatim: ChartMath.safeInt(item.pct).formatted(.percent))
                            .font(.caption2).monospacedDigit().foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 150)
    }

    /// Right eye: usage donut — token share per repo (log facts). Users often
    /// work across several repos with one tool, so repo is the more useful
    /// split than tool. Center shows the attributed token total.
    @ViewBuilder
    func repoTokenDonut() -> some View {
        let labels = RepositoryLabels.make(for: Array(repoTokens.keys))
        let items = repoTokens.compactMap { (name, tokens) -> DonutItem? in
            guard tokens > 0 else { return nil }
            return DonutItem(label: labels[name] ?? name, tokens: Double(tokens), pct: 0, color: .secondary, id: name)
        }
        let totalTokens = items.reduce(0.0) { $0 + $1.tokens }
        let segments = Self.topSegments(items).enumerated().map { i, s in
            DonutItem(label: s.label, tokens: s.tokens,
                      pct: totalTokens > 0 ? s.tokens / totalTokens * 100 : 0,
                      color: Self.donutPalette[i % Self.donutPalette.count], id: s.id)
        }
        let centerText = tokenShort(Int(clamping: Int64(totalTokens)))
        VStack(spacing: 6) {
            ZStack {
                if !segments.isEmpty {
                    Chart(segments) { item in
                        SectorMark(angle: .value("Tokens", item.tokens), innerRadius: .ratio(0.5), angularInset: 1)
                            .foregroundStyle(item.color)
                    }
                    .chartLegend(.hidden)
                    .chartForegroundStyleScale(
                        domain: segments.map(\.label),
                        range: segments.map(\.color))
                    .frame(width: 120, height: 120)
                    .id("repo-\(timeRange.cacheKey)")
                    .transaction { $0.animation = nil }
                } else {
                    emptyDonut()
                }
                Text(centerText)
                    .font(.system(size: Self.donutCenterFontSize(for: totalTokens), weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.marsGreen)
            }
            VStack(spacing: 2) {
                ForEach(segments.prefix(3)) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.label).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            .help(repoTokens[item.id] == nil ? item.label : item.id)
                        Spacer()
                        Text(verbatim: ChartMath.safeInt(item.pct).formatted(.percent))
                            .font(.caption2).monospacedDigit().foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 150)
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
        let sorted = items.sorted { $0.tokens > $1.tokens }
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
        .help(String(format: I18n.t("dashboard.quota_help"),
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
        let displayedValues = Array((values + Array(repeating: 0, count: slotCount)).prefix(slotCount))
        let peak = max(displayedValues.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            if growsDownward {
                Text(label).font(.caption2).foregroundColor(.secondary)
            }
            HStack(alignment: growsDownward ? .top : .bottom, spacing: timeRange == .today ? 3 : 5) {
                ForEach(Array(displayedValues.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(value > 0 ? color : Color.secondary.opacity(0.14))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, 26 * value / peak))
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
        let observed = (activeSnapshot?.observedSpend ?? []).filter { $0.amount > 0 }
        let freshQuotas = (activeSnapshot?.quotaStatus ?? usageData).filter { !$0.isStale() }
        VStack(alignment: .leading, spacing: 10) {
            Text(timeRange == .days30
                 ? pulseText("近 30 天的订阅与工具使用", "Subscription and tool use · 30 days")
                 : pulseText("已观察到的事实", "Observed facts"))
                .font(.caption).foregroundColor(.secondary)

            if !isDemoMode {
                if let failures = activeSnapshot?.readFailures, !failures.isEmpty {
                    Label(pulseText("部分统计读取失败，空图和零值不代表没有活动。", "Some statistics could not be read; empty charts and zero values do not mean no activity."),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.orange)
                        .help(failures.joined(separator: ", "))
                }
                if activeSnapshot?.activityCoverage.isPartial == true {
                    Text(pulseText("部分日志缺少词元分项，当前总量只包含可确认部分，可能偏低。",
                                   "Some logs lack token components. Totals include confirmed components only and may be lower."))
                        .font(.caption2).foregroundColor(.secondary)
                } else if activeSnapshot?.activityCoverage.isPartial == nil {
                    Text(pulseText("观察完整性暂不可用，不能据此判断没有活动。",
                                   "Observation completeness is unavailable; this does not mean there was no activity."))
                        .font(.caption2).foregroundColor(.secondary)
                }
                Text(pulseText("词元来自支持的本地工具日志，不代表整个 AI 账户用量或账单。",
                               "Tokens come from supported local tool logs—not entire-account usage or billing."))
                    .font(.caption2).foregroundColor(.secondary)
            }

            if timeRange == .days30 {
                HStack(spacing: 14) {
                    Label("\(periodActiveDays) \(pulseText("个活跃日", "active days"))", systemImage: "calendar")
                    Label("\(periodSessionCount) \(pulseText("个会话", "sessions"))", systemImage: "bubble.left.and.bubble.right")
                    Label("\(tokenShort(todayTokens)) \(pulseText("词元", "tokens"))", systemImage: "waveform.path.ecg")
                }
                .font(.caption).foregroundColor(.secondary)
            }

            if !observed.isEmpty {
                Text(pulseText("以下为采样间余额净下降，可能包含充值、退款及其他活动的影响，并非逐笔账单。",
                               "Net balance decreases between samples, affected by top-ups, refunds and other activity—not itemized bills."))
                    .font(.caption2).foregroundColor(.secondary)
            }
            ForEach(observed, id: \.stableId) { item in
                HStack {
                    Text(ProviderRegistry.byId(item.providerId)?.name ?? item.providerId)
                    Spacer()
                    Text("\(item.currency.uppercased()) \(String(format: "%.1f", item.amount))")
                        .monospacedDigit()
                }
                .font(.caption)
                .help(observedAmountIntervalHelp(item))
            }
            ForEach(freshQuotas, id: \.stableId) { quota in quotaRow(data: quota) }

            if observed.isEmpty && freshQuotas.isEmpty && timeRange != .days30 {
                Text(pulseText("这个时段没有观察到余额净下降或新鲜额度数据。", "No net balance decrease or fresh quota was observed in this period."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
        let cellTokens = { (model: ActivityMatrix.ModelKey, tool: String) in matrix.tokens(model: model, tool: tool) }
        let toolTokens = { (tool: String) in matrix.tokens(tool: tool) }
        let modelTokens = { (model: ActivityMatrix.ModelKey) in matrix.tokens(model: model) }
        let grandTotal = matrix.grandTotal

        // ── Tool × model matrix ──
        if !matrixRows.isEmpty {
            VStack(spacing: 12) {
                Text(I18n.t("dashboard.by_tool_model"))
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(I18n.t("panel.detail_entry_hint"))
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Menu(I18n.t("panel.view_tool_details")) {
                        ForEach(Array(Set(matrixRows.compactMap(\.toolId))).sorted(), id: \.self) { tool in
                            Button(toolIdToDisplay(tool) ?? tool) { selectedToolForOverlay = tool }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                ScrollView(.horizontal) {
                Grid(alignment: .trailing, horizontalSpacing: 1, verticalSpacing: 1) {
	                        GridRow {
	                            Text(I18n.t("dashboard.model"))
	                                .font(.caption2).bold().foregroundColor(.secondary)
	                                .dashboardTableCell(isHeader: true, alignment: .leading)
	                            ForEach(toolIds, id: \.self) { t in
	                                Text(t.isEmpty ? I18n.t("dashboard.unattributed_tool") : (toolIdToDisplay(t) ?? t))
	                                    .font(.caption2).bold().foregroundColor(.secondary).lineLimit(1)
	                                    .dashboardTableCell(isHeader: true, alignment: .trailing)
	                                    .contentShape(Rectangle())
	                                    .onTapGesture { if !t.isEmpty { selectedToolForOverlay = t } }
	                                    .pointingHandCursor()
	                            }
	                            Text(I18n.t("dashboard.total"))
	                                .font(.caption2).bold().foregroundColor(.secondary)
	                                .dashboardTableCell(isHeader: true)
	                        }
	                        ForEach(Array(modelNames.enumerated()), id: \.element) { idx, m in
	                            GridRow {
	                                Text((m.model.isEmpty ? I18n.t("dashboard.unknown_model") : m.model) + " · " + m.provider)
	                                    .font(.caption).lineLimit(1)
	                                    .dashboardTableCell(rowIndex: idx, alignment: .leading)
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
	                                        .dashboardTableCell(rowIndex: idx)
	                                }
	                                Text(tokenShort(Int(clamping: modelTokens(m))))
	                                    .font(.caption).bold().monospacedDigit()
	                                    .dashboardTableCell(rowIndex: idx)
	                            }
	                        }
	                        // Total row participates in the zebra pattern (its shade
	                        // continues from the last data row).
	                        GridRow {
	                            Text(I18n.t("dashboard.total"))
	                                .font(.caption).bold()
	                                .dashboardTableCell(rowIndex: modelNames.count, alignment: .leading)
	                            ForEach(toolIds, id: \.self) { t in
	                                Text(tokenShort(Int(clamping: toolTokens(t))))
	                                    .font(.caption).bold().monospacedDigit()
	                                    .dashboardTableCell(rowIndex: modelNames.count)
	                            }
	                            Text(tokenShort(Int(clamping: grandTotal)))
	                                .font(.caption).bold().monospacedDigit()
	                                .dashboardTableCell(rowIndex: modelNames.count)
	                            }
                }
                .frame(maxWidth: .infinity)
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
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n.t("dashboard.by_repo")).font(.caption).foregroundColor(.secondary)
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
                            Text(r.name).help(r.repoPath)
                                .font(.caption).fontWeight(.medium).lineLimit(1)
                                .dashboardTableCell(rowIndex: idx, alignment: .leading)
                            Text(tokenShort(Int(clamping: r.tokens ?? 0)))
                                .font(.caption).monospacedDigit()
                                .dashboardTableCell(rowIndex: idx)
                            Text("+\(r.added)")
                                .font(.caption).monospacedDigit().foregroundColor(.marsGreen)
                                .dashboardTableCell(rowIndex: idx)
                            Text("-\(r.deleted)")
                                .font(.caption).monospacedDigit().foregroundColor(.red)
                                .dashboardTableCell(rowIndex: idx)
                            Text(ChartMath.compactCount(Int64(r.commits)))
                                .font(.caption).monospacedDigit()
                                .dashboardTableCell(rowIndex: idx)
                        }
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
            .frame(width: 120, height: 120)
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
           let cached = await DashboardCache.read(timeRange: requestedRange.cacheKey, maxAge: cacheMaxAge) {
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

/// The one dashboard table cell style. Padding, row tint and hairline border
/// are applied to the same cell frame. The 1px Grid spacing is only the gap
/// between cells; it never becomes a second container around the cell.
private extension View {
    func dashboardTableCell(
        rowIndex: Int? = nil,
        isHeader: Bool = false,
        alignment: Alignment = .trailing
    ) -> some View {
        frame(maxWidth: .infinity, alignment: alignment)
            .padding(2)
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
