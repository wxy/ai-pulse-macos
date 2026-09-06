import SwiftUI
import Charts
import GRDB
import AIPulseShared

enum TimeRange: Hashable {
    case today
    case thisWeek
    case days30

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
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    let initialTimeRange: TimeRange

    @State private var timeRange: TimeRange
    @State private var costHoverDate: Date? = nil
    @State private var isRefreshing = false
    @State private var dataChangeThrottle = DashboardLoadThrottle()
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
    @State private var usageData: [String: (percent: Double, limitStatus: String, resetAt: Double, windowSeconds: Double)] = [:]  // toolId → quota state
    @State private var i18nToken = 0  // bumped on language change to force re-render
    @State private var barProgress: CGFloat = 0  // 0→1 drives all entry animations
    @State private var balanceErrors: Set<String> = []     // provider IDs whose API fetch failed
    @State private var loadGeneration: Int = 0   // guards against stale concurrent loads
    @State private var entryAnimationToken = 0   // cancels a stale zero→one entry run
    @State private var rangeChangeStartedAt: Date? = nil
    @State private var rangeSnapshots: [TimeRange: DashboardSnapshot] = [:]
    @State private var demoRanges: Set<TimeRange> = []
    @State private var toolsExpanded = false
    @State private var claudeDetailExpanded = false
    @State private var codexDetailExpanded = false
    @State private var selectedToolForOverlay: String? = nil
    @State private var reposExpanded = false
    @State private var isImportingHistory = LogWatcher.backfill.isActive

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

    private var providerCosts: [ProviderDailyCost] {
        guard let snapshot = activeSnapshot else { return [] }
        return snapshot.providerBreakdown.map {
            ProviderDailyCost(date: snapshot.updatedAt,
                              providerId: $0.providerId,
                              cost: $0.cost)
        }
    }

    private var balanceSpend: [(providerId: String, name: String, spend: Double)] {
        (activeSnapshot?.providerBreakdown ?? []).map {
            (providerId: $0.providerId, name: $0.name, spend: $0.cost)
        }
    }

    private var toolCostBreakdown: [(name: String, cost: Double)] {
        (activeSnapshot?.toolBreakdown ?? []).map { (name: $0.name, cost: $0.cost) }
    }

    private var dailyStats: [DailyStat] {
        (activeSnapshot?.dailyStats ?? []).map {
            DailyStat(date: Date(timeIntervalSince1970: $0.ts),
                      cost: $0.value,
                      calls: Int($0.calls),
                      tokens: Int($0.tokens),
                      netLines: $0.netLines,
                      costPerLine: 0)
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
                            deleted: $0.deleted)
        }
    }

    private var paddedChanges: [DailyCodeChange] {
        Self.padChanges(codeChanges, chartStart: chartStart, chartDays: chartDays)
    }

    private var repos: [RepoBreakdown] {
        (activeSnapshot?.topRepos ?? []).map {
            RepoBreakdown(repo: $0.name,
                          cost: $0.cost,
                          added: $0.added,
                          deleted: $0.deleted,
                          apiSources: [],
                          subscriptionSources: [])
        }
    }

    private var prediction: Prediction? {
        activeSnapshot?.prediction.map {
            Prediction(monthProjected: $0.monthProjected,
                       dailyRate: $0.dailyRate,
                       daysRemaining: $0.daysRemaining,
                       monthSoFar: $0.monthSoFar)
        }
    }

    private var remainingBalances: [RemainingBalanceItem] {
        activeSnapshot?.remainingBalances ?? []
    }

    private var todayCombinedSpend: Double { activeSnapshot?.todayCost ?? 0 }
    private var weekCombinedSpend: Double { activeSnapshot?.weekCost ?? 0 }
    private var monthCombinedSpend: Double { activeSnapshot?.monthCost ?? 0 }
    private var todayCalls: Int { Int(activeSnapshot?.todayCalls ?? 0) }
    private var todayTokens: Int { Int(activeSnapshot?.todayTokens ?? 0) }
    private var yesterdaySpend: Double { activeSnapshot?.yesterdaySpend ?? 0 }
    private var previousPeriodSpend: Double { activeSnapshot?.previousPeriodSpend ?? 0 }

    private var providerSourceKinds: [String: String] {
        Dictionary(activeSnapshot?.providerBreakdown.map {
            ($0.providerId, $0.sourceKind ?? "balance")
        } ?? [], uniquingKeysWith: { _, latest in latest })
    }

    private var repoTokens: [String: Int64] {
        activeSnapshot?.topRepos.reduce(into: [String: Int64]()) { map, repo in
            map[repo.name, default: 0] += repo.tokens ?? 0
        } ?? [:]
    }

    private var modelBreakdownItems: [ModelCostItem] {
        activeSnapshot?.modelBreakdown ?? []
    }

    private var rateSeriesItems: [RateSeriesItem] {
        activeSnapshot?.rateSeries ?? []
    }

    private var subscriptionCycle: (start: Date?, periodDays: Int?) {
        (activeSnapshot?.subscriptionStart, activeSnapshot?.subscriptionPeriodDays)
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
    nonisolated static func shouldShowRepository(totalChanges: Int, tokens: Int64) -> Bool {
        totalChanges > 0 || tokens > 0
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
        VStack(spacing: 0) {
            // Error banner — visible when health is not nominal
            if healthSeverity >= .degraded {
                VStack(spacing: 0) {
                    Button {
                        withAnimation { showHealthDetails.toggle() }
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
                    if hasActiveCostSources || !providerCosts.isEmpty || isDemoMode {
                        // ── Robot head frame (face) — spending + output ──
                        VStack(spacing: 16) {
                            spendingOverview
                            outputSection
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
                            if timeRange != .today, loadedTimeRange == timeRange {
                                trendSection
                            } else {
                                remainingBalanceSection
                            }
                            repoListSection
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.marsGreen.opacity(0.25), lineWidth: 2)
                        )
                        .padding(.horizontal, 60)
                        // Effective-rate chart — only when attributable data exists
                        effectiveRateSection
                            .padding(20)
                            .background(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(Color.marsGreen.opacity(0.25), lineWidth: 2)
                            )
                            .padding(.horizontal, 60).padding(.bottom, 60)
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
        .task {
            await hydrateRangeSnapshotCache()
            await load()
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
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardRefresh)) { _ in
            // Manual refresh / forceRefresh — immediate, no throttle
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataDidChange)) { _ in
            // Background data change — throttle to avoid redundant work
            let now = Date()
            guard dataChangeThrottle.shouldLoad(now: now, minimumInterval: 15) else { return }
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appHealthDidChange)) { _ in
            let snap = AppHealthMonitor.shared.current
            healthSeverity = snap.severity
            healthMessages = snap.messages
        }
        .onReceive(NotificationCenter.default.publisher(for: IngestionBackfillState.changeNotification)) { _ in
            isImportingHistory = LogWatcher.backfill.isActive
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardSwitchTab)) { notification in
            if let tr = notification.userInfo?["timeRange"] as? TimeRange, tr != timeRange {
                timeRange = tr
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: I18n.didChangeLanguage)) { _ in
            i18nToken += 1
        }
        .id(i18nToken)
        .overlay {
            if let toolId = selectedToolForOverlay {
                ToolDetailOverlayView(
                    toolId: toolId,
                    sinceMs: rangeSinceMs(),
                    onClose: { selectedToolForOverlay = nil })
                    .transition(.opacity)
            }
        }
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

    // MARK: - CPL guidance (no A-grade)

    var cplGuidanceCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 32)).foregroundColor(.secondary)
            Text(I18n.t("dashboard.cpl_unavailable_title")).font(.headline)
            Text(I18n.t("dashboard.cpl_unavailable_desc"))
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Text(I18n.t("dashboard.cpl_claude_path")).font(.caption2).foregroundColor(.secondary)
                Text(I18n.t("dashboard.cpl_aider_path")).font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(24).frame(maxWidth: .infinity)
        .background(Color(nsColor: .quaternarySystemFill).opacity(0.3))
        .cornerRadius(10)
    }

    /// Per-provider spend from balance API (single source of truth).
    var apiBreakdownCard: some View {
        guard !balanceSpend.isEmpty else { return AnyView(EmptyView()) }
        let total = balanceSpend.reduce(0.0) { $0 + $1.spend }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text(I18n.t("dashboard.api_total_title")).font(.headline)
                HStack {
                    Text(I18n.t("dashboard.total")).font(.body)
                    Spacer()
                    Text("$\(String(format: "%.2f", total))").font(.callout).monospacedDigit().fontWeight(.semibold)
                }
                Divider()
                ForEach(balanceSpend, id: \.providerId) { item in
                    HStack {
                        Text(item.name).font(.caption)
                        Spacer()
                        Text("$\(String(format: "%.2f", item.spend))").font(.caption).monospacedDigit()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .quaternarySystemFill).opacity(0.3)).cornerRadius(10)
        )
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

    func confidenceBadge(_ c: CostConfidence) -> some View {
        let (label, color): (String, Color) = switch c {
        case .exact:       ("", .marsGreen)
        case .estimated:   ("~", .marsGreen2)
        case .amortized:   ("", .deepRed)
        case .uncertain:   ("?", .deepRed2)
        case .incomplete:  ("…", .deepRed)
        }
        return Text(label)
            .font(.caption2).fontWeight(.bold).foregroundColor(color)
            .frame(width: 16)
    }

    func confidenceColor(_ c: CostConfidence) -> Color {
        switch c {
        case .exact:       return .marsGreen
        case .estimated:   return .secondary
        case .amortized:   return .secondary
        case .uncertain:   return .secondary
        case .incomplete:  return .deepRed
        }
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
            else { result.append(DailyCodeChange(date: date, added: 0, deleted: 0)) }
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

    // MARK: - CPL info card (demoted from trend chart to small window)

    var cplInfoCard: some View {
        let cplRepos = repos.filter { $0.totalChanges > 0 && !$0.allSources.isEmpty }
        return VStack(alignment: .leading, spacing: 8) {
            Text(I18n.t("dashboard.cpl_card")).font(.headline)
            if cplRepos.isEmpty {
                Text(I18n.t("dashboard.no_cpl_data"))
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(cplRepos.prefix(5)) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(r.repo).font(.caption).fontWeight(.medium).lineLimit(1)
                            Text("+\(r.added)/-\(r.deleted)").font(.caption2).foregroundColor(.secondary).monospacedDigit()
                            Spacer()
                        }
                        // Show CPL contribution per source
                        ForEach(r.allSources) { src in
                            HStack {
                                Text(src.label).font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                Text("\(confidencePrefixForCPLLabel(src.label))$\(String(format: "%.2f", src.cpl))\(I18n.t("menu.per_line"))")
                                    .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                            }
                            .padding(.leading, 8)
                        }
                    }
                    if r.id != cplRepos.prefix(5).last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .quaternarySystemFill).opacity(0.3))
        .cornerRadius(10)
    }

    /// Show confidence prefix for CPL source labels.
    func confidencePrefixForCPLLabel(_ label: String) -> String {
        // Check if this source has estimated/anortized confidence
        let sources = IntegrationRegistry.activeCostSources(editorMappings: editorMappings)
        if let cs = sources.first(where: { label.contains($0.label) || $0.label.contains(label) }) {
            switch cs.confidence {
            case .estimated: return "~"
            case .amortized: return ""
            case .incomplete: return ""
            default: return ""
            }
        }
        return ""
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
                    Text("+\(added)")
                        .font(.caption2).fontWeight(.semibold).monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.marsGreen.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                    Spacer()
                    Text(netLines >= 0 ? "+\(netLines)" : "\(netLines)")
                        .font(.system(size: 13, weight: .bold)).monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    Spacer()
                    Text("-\(deleted)")
                        .font(.caption2).fontWeight(.semibold).monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.deepRed.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .frame(width: 64, height: 150)
    }

    // MARK: - Head overview (forehead usage · eyes expense/output · nose lines)

    var spendingOverview: some View {
        // Forehead: usage is the primary number — pure JSONL facts.
        let rangeTokens = dailyStats.reduce(Int64(0)) { $0 + Int64($1.tokens) }
        let rangeCalls = dailyStats.reduce(0) { $0 + $1.calls }
        // Left eye: actual spend = balance deltas only (facts). Subscription is
        // shown as a fixed-cycle label, never amortized into the number.
        let actualSpend = ChartMath.finite(balanceSpend.reduce(0.0) { $0 + $1.spend }, fallback: 0)
        let subDaily = ChartMath.finite(activeSnapshot?.subDaily ?? 0, fallback: 0)
        let daysInMonth = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
        let subMonthly = subDaily * daysInMonth

        return VStack(spacing: 16) {
            // ── Forehead: usage ──
            VStack(spacing: 4) {
                Text(tokenShort(Int(clamping: rangeTokens)))
                    .font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.marsGreen)
                    .scaleEffect(loadedTimeRange == timeRange ? (0.8 + 0.2 * barProgress) : 0.8)
                    .animation(.spring(response: 0.5, dampingFraction: 0.6), value: barProgress)
                HStack(spacing: 4) {
                    Text("\(timeRange.label) · \(rangeCalls) \(I18n.t("dashboard.calls"))")
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
                providerExpenseDonut(actualSpend: actualSpend, subMonthly: subMonthly)

                // Nose: code lines
                VStack(spacing: 6) {
                    noseStatCards
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

    /// Left eye: expense donut — balance deltas per provider (facts), with the
    /// subscription fixed cost as the eyebrow label.
    @ViewBuilder
    func providerExpenseDonut(actualSpend: Double, subMonthly: Double) -> some View {
        // Subscription participates as a fixed-cycle share (like a balance
        // delta) so the cost composition has both factual expense kinds.
        let subscriptionSegment: [DonutItem] = subMonthly > 0.001
            ? [DonutItem(label: I18n.t("dashboard.sub_label"), cost: subMonthly, pct: 0, color: .secondary)]
            : []
        let rawSegments = balanceSpend.map {
            DonutItem(label: $0.name, cost: $0.spend, pct: 0, color: .secondary)
        } + subscriptionSegment
        let totalCost = actualSpend + subMonthly
        let segments = Self.topSegments(
            Self.renderableDonutSegments(rawSegments)
        ).enumerated().map { i, s in
            DonutItem(label: s.label, cost: s.cost,
                      pct: totalCost > 0 ? s.cost / totalCost * 100 : 0,
                      color: Self.donutPalette[i % Self.donutPalette.count])
        }
        VStack(spacing: 6) {
            ZStack {
                if !segments.isEmpty {
                    Chart(segments) { item in
                        let isUsage = item.label == I18n.t("dashboard.sub_label")
                            ? false
                            : providerSourceKinds[providerId(for: item.label)] == "usage"
                        SectorMark(angle: .value("Cost", item.cost), innerRadius: .ratio(0.5), angularInset: 1)
                            .foregroundStyle(item.color.opacity(isUsage ? 0.45 : 1))
                    }
                    .chartLegend(.hidden)
                    .chartForegroundStyleScale(
                        domain: segments.map(\.label),
                        range: segments.map(\.color))
                    .frame(width: 120, height: 120)
                } else {
                    emptyDonut()
                }
                Text("$\(String(format: "%.2f", totalCost))")
                    .font(.system(size: Self.donutCenterFontSize(for: totalCost), weight: .semibold, design: .rounded)).monospacedDigit()
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
        .animation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.15), value: barProgress)
    }

    /// Right eye: usage donut — token share per repo (log facts). Users often
    /// work across several repos with one tool, so repo is the more useful
    /// split than tool. Center shows the attributed token total.
    @ViewBuilder
    func repoTokenDonut() -> some View {
        let items = repoTokens.compactMap { (name, tokens) -> DonutItem? in
            guard tokens > 0 else { return nil }
            return DonutItem(label: name, cost: Double(tokens), pct: 0, color: .secondary)
        }
        let totalTokens = items.reduce(0.0) { $0 + $1.cost }
        let segments = Self.topSegments(items).enumerated().map { i, s in
            DonutItem(label: s.label, cost: s.cost,
                      pct: totalTokens > 0 ? s.cost / totalTokens * 100 : 0,
                      color: Self.donutPalette[i % Self.donutPalette.count])
        }
        let centerText = tokenShort(Int(clamping: Int64(totalTokens)))
        VStack(spacing: 6) {
            ZStack {
                if !segments.isEmpty {
                    Chart(segments) { item in
                        SectorMark(angle: .value("Tokens", item.cost), innerRadius: .ratio(0.5), angularInset: 1)
                            .foregroundStyle(item.color)
                    }
                    .chartLegend(.hidden)
                    .chartForegroundStyleScale(
                        domain: segments.map(\.label),
                        range: segments.map(\.color))
                    .frame(width: 120, height: 120)
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
                        Spacer()
                        Text(verbatim: ChartMath.safeInt(item.pct).formatted(.percent))
                            .font(.caption2).monospacedDigit().foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 150)
        .animation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.2), value: barProgress)
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
        let sorted = items.sorted { $0.cost > $1.cost }
        guard sorted.count > limit else { return sorted }
        let top = Array(sorted.prefix(limit))
        let otherCost = sorted.dropFirst(limit).reduce(0.0) { $0 + $1.cost }
        return top + [DonutItem(label: I18n.t("dashboard.other"), cost: otherCost, pct: 0, color: .secondary)]
    }

    /// Reverse lookup from a donut label back to a provider id.
    private func providerId(for label: String) -> String {
        balanceSpend.first(where: { $0.name == label })?.providerId ?? label
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
    func quotaRow(toolId: String, data: (percent: Double, limitStatus: String, resetAt: Double, windowSeconds: Double)) -> some View {
        let icon = toolId.contains("claude") ? "sparkles" : "bubble.left.and.bubble.right"
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2).foregroundColor(quotaColor(for: data.percent))
            Text(toolDisplayName(toolId)).font(.caption).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            usageBarView(percent: data.percent)
            if data.resetAt > 0 {
                Text(resetCountdownText(data.resetAt))
                    .font(.caption2).monospacedDigit().foregroundColor(.secondary)
            }
        }
        .help(String(format: I18n.t("dashboard.quota_help"),
                     (data.percent / 100).formatted(.percent.precision(.fractionLength(0))),
                     data.limitStatus))
    }

    private func toolDisplayName(_ toolId: String) -> String {
        IntegrationRegistry.toolDisplayName(for: toolId)
    }

    /// Load subscription quota state (utilization + next reset) from quota_status.
    /// Independent of whether the user configured a subscription tier.
    private func loadUsageData() async {
        guard !isDemoMode else { return }
        do {
            let rows = try await AppDatabase.shared.read { db -> [(String, Double, String, Double, Double)] in
                try Row.fetchAll(db, sql: """
                    SELECT tool_id, utilization, limit_status, reset_at, window_seconds
                    FROM quota_status
                    """).map { r in
                    (r["tool_id"] as String? ?? "",
                     r["utilization"] as Double? ?? 0,
                     r["limit_status"] as String? ?? "",
                     r["reset_at"] as Double? ?? 0,
                     r["window_seconds"] as Double? ?? 0)
                }
            }
            var map: [String: (percent: Double, limitStatus: String, resetAt: Double, windowSeconds: Double)] = [:]
            for (id, pct, status, resetAt, window) in rows where !id.isEmpty {
                map[id] = (pct, status, resetAt, window)
            }
            let unchanged = map.count == usageData.count && map.allSatisfy { key, next in
                guard let current = usageData[key] else { return false }
                return current.percent == next.percent
                    && current.limitStatus == next.limitStatus
                    && current.resetAt == next.resetAt
                    && current.windowSeconds == next.windowSeconds
            }
            if !unchanged {
                usageData = map
            }
        } catch {
            Logger.debug("Dashboard: loadUsageData failed: \(error)")
        }
    }

    struct DonutItem: Identifiable {
        // Labels are unique within each donut. Stable identity avoids turning
        // every refresh into a destroy/create transition for ring geometry.
        let id: String
        let label: String
        let cost: Double
        let pct: Double
        let color: Color

        init(label: String, cost: Double, pct: Double, color: Color) {
            self.id = label
            self.label = label
            self.cost = cost
            self.pct = pct
            self.color = color
        }
    }

    /// SectorMark receives only positive, finite angles. All-zero/error entries
    /// stay out of chart geometry and are represented by the caller's placeholder.
    static func renderableDonutSegments(_ segments: [DonutItem]) -> [DonutItem] {
        segments.filter { $0.cost.isFinite && $0.cost > 0.001 }
    }

    private func toolIdToDisplay(_ id: String) -> String? {
        IntegrationRegistry.toolDisplayName(for: id)
    }

    // MARK: - Output section

    @ViewBuilder
    var outputSection: some View {
        // Matrix: one column per dev tool, one row per model; a cell is the
        // token usage of that tool for that model. Row/column totals plus the
        // grand total make both dimensions readable. Calls are not shown.
        let matrixRows = modelBreakdownItems
        let toolIds = Array(Set(matrixRows.compactMap(\.toolId)))
            .sorted { a, b in
                let ta = matrixRows.filter { $0.toolId == a }.reduce(Int64(0)) { $0 + $1.tokens }
                let tb = matrixRows.filter { $0.toolId == b }.reduce(Int64(0)) { $0 + $1.tokens }
                return ta > tb
            }
            .prefix(6)
        let modelNames = Array(Set(matrixRows.map(\.model)))
            .sorted { a, b in
                let ta = matrixRows.filter { $0.model == a }.reduce(Int64(0)) { $0 + $1.tokens }
                let tb = matrixRows.filter { $0.model == b }.reduce(Int64(0)) { $0 + $1.tokens }
                return ta > tb
            }
            .prefix(8)
        let cellTokens: (String, String) -> Int64 = { model, tool in
            matrixRows.first { $0.model == model && $0.toolId == tool }?.tokens ?? 0
        }
        let toolTokens: (String) -> Int64 = { tool in
            matrixRows.filter { $0.toolId == tool }.reduce(Int64(0)) { $0 + $1.tokens }
        }
        let modelTokens: (String) -> Int64 = { model in
            matrixRows.filter { $0.model == model }.reduce(Int64(0)) { $0 + $1.tokens }
        }
        let grandTotal = matrixRows.reduce(Int64(0)) { $0 + $1.tokens }

        VStack(spacing: 12) {
            // ── Tool × model matrix ("mouth") ──
            if !matrixRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Grid(alignment: .trailing, horizontalSpacing: 1, verticalSpacing: 1) {
	                        GridRow {
	                            Text(I18n.t("dashboard.by_tool_model"))
	                                .font(.caption2).bold().foregroundColor(.secondary)
	                                .dashboardTableCell(isHeader: true)
	                            ForEach(toolIds, id: \.self) { t in
	                                Text(toolIdToDisplay(t) ?? t)
	                                    .font(.caption2).bold().foregroundColor(.secondary).lineLimit(1)
	                                    .dashboardTableCell(isHeader: true, alignment: .leading)
	                                    .contentShape(Rectangle())
	                                    .onTapGesture { selectedToolForOverlay = t }
	                                    .pointingHandCursor()
	                            }
	                            Text(I18n.t("dashboard.total"))
	                                .font(.caption2).bold().foregroundColor(.secondary)
	                                .dashboardTableCell(isHeader: true)
	                        }
	                        ForEach(Array(modelNames.enumerated()), id: \.element) { idx, m in
	                            GridRow {
	                                Text(m).font(.caption).lineLimit(1)
	                                    .dashboardTableCell(rowIndex: idx, alignment: .leading)
	                                    .contentShape(Rectangle())
	                                    .onTapGesture {
	                                        if let tool = matrixRows.first(where: { $0.model == m })?.toolId {
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
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }

            // ── Mouth line — short horizontal connector ──
            HStack(spacing: 0) {
                Spacer()
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.marsGreen.opacity(0.2))
                    .frame(width: 60, height: 3)
                Spacer()
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
    }

    // MARK: - Body sections

    /// Repo list in the body: per-repo output (Git facts) + token usage
    /// (log facts). No estimated costs or CPL here.
    @ViewBuilder
    private var repoListSection: some View {
        let shownRepos = repos.filter {
            Self.shouldShowRepository(
                totalChanges: $0.totalChanges,
                tokens: repoTokens[$0.repo] ?? 0)
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
                        Text("Token")
                            .font(.caption2).bold().foregroundColor(.secondary)
                            .dashboardTableCell(isHeader: true)
                        Text(I18n.t("dashboard.code_added"))
                            .font(.caption2).bold().foregroundColor(.secondary)
                            .dashboardTableCell(isHeader: true)
                        Text(I18n.t("dashboard.code_deleted"))
                            .font(.caption2).bold().foregroundColor(.secondary)
                            .dashboardTableCell(isHeader: true)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, r in
                        GridRow {
                            Text(r.repo)
                                .font(.caption).fontWeight(.medium).lineLimit(1)
                                .dashboardTableCell(rowIndex: idx, alignment: .leading)
                            Text(tokenShort(Int(clamping: repoTokens[r.repo] ?? 0)))
                                .font(.caption).monospacedDigit()
                                .dashboardTableCell(rowIndex: idx)
                            Text("+\(r.added)")
                                .font(.caption).monospacedDigit().foregroundColor(.marsGreen)
                                .dashboardTableCell(rowIndex: idx)
                            Text("-\(r.deleted)")
                                .font(.caption).monospacedDigit().foregroundColor(.red)
                                .dashboardTableCell(rowIndex: idx)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                if shownRepos.count > 5 {
                    Button(reposExpanded ? I18n.t("dashboard.show_less") : I18n.t("dashboard.show_all")) {
                        withAnimation { reposExpanded.toggle() }
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

    /// Effective-price chart: X = time, Y = $ per million tokens. Only
    /// attributable (exclusive-provider) tools produce lines, so both
    /// coordinates stay facts.
    @ViewBuilder
    private var effectiveRateSection: some View {
        if rateSeriesItems.isEmpty {
            // No attributable balance source — this is a data boundary, not an
            // error. Hide the whole section instead of explaining absence.
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(I18n.t("dashboard.effective_rate")).font(.headline)
                Chart {
                    ForEach(rateSeriesItems, id: \.toolId) { series in
                        ForEach(series.points, id: \.ts) { point in
                            let perM = point.tokens > 0
                                ? point.cost / Double(point.tokens) * 1_000_000
                                : 0
                            LineMark(
                                x: .value("Date", Date(timeIntervalSince1970: point.ts)),
                                y: .value("Rate", perM)
                            )
                            .foregroundStyle(by: .value("Tool", series.label))
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: dateLabelFormat, orientation: .horizontal)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        if let v = value.as(Double.self) {
                            AxisValueLabel("$\(String(format: "%.2f", v))/M")
                        }
                    }
                }
                .frame(height: 160)
                Text(I18n.t("dashboard.effective_rate_note"))
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Trend section

    /// Target grid-line count — both axes share the same number of sections.
    private let targetGrid = 4.0

    private struct TrendAxes {
        let spend: (max: Double, step: Double, values: [Double], sections: Int)
        let code: (max: Double, step: Double, values: [Double], scale: Double)
    }

    private func makeTrendAxes(
        paddedStats: [DailyStat],
        paddedCode: [DailyCodeChange],
        balanceSpendByDay: [Date: Double]
    ) -> TrendAxes {
        let cal = Calendar.current
        let subDaily = ChartMath.finite(activeSnapshot?.subDaily ?? 0, fallback: 0)
        let rawSpendMax = paddedStats.map { s -> Double in
            let d = cal.startOfDay(for: s.date)
            return (balanceSpendByDay[d] ?? 0) + subDaily  // stacked total
        }.max() ?? 5
        let safeRawMax = ChartMath.axisMax(rawSpendMax, fallback: 5)
        let step = ChartMath.niceStep(safeRawMax / targetGrid)
        let max = ChartMath.axisMax(ceil(safeRawMax / step) * step, fallback: step)
        let sections = Swift.max(1, Int((max / step).rounded(.toNearestOrEven)))
        var spendValues = [Double]()
        var spendValue = 0.0
        while spendValue <= max + step / 2 {
            spendValues.append(ChartMath.finite(spendValue, fallback: max))
            spendValue += step
        }

        let rawCodeMax = Double(paddedCode.map { $0.added + $0.deleted }.max() ?? 1)
        let codeSections = Double(sections)
        var codeStep = ChartMath.niceStep(rawCodeMax / codeSections)
        while codeStep * codeSections < rawCodeMax { codeStep = ChartMath.nextNiceStep(codeStep) }
        let codeMax = codeStep * codeSections
        var codeValues = [Double]()
        var codeValue = 0.0
        while codeValue <= codeMax + codeStep / 2 {
            codeValues.append(ChartMath.finite(codeValue, fallback: codeMax))
            codeValue += codeStep
        }

        let spend = (max: max, step: step, values: spendValues, sections: sections)
        let code = (
            max: codeMax,
            step: codeStep,
            values: codeValues,
            scale: ChartMath.scale(max, denominator: codeMax, fallback: 1)
        )
        return TrendAxes(spend: spend, code: code)
    }

    var remainingBalanceSection: some View {
        // Hide providers with no usable balance (missing/invalid key) — same
        // filter iOS applies, so 0.00 rows never render.
        let balances = remainingBalances.filter { $0.balance > 0.001 }
        let maxBalance = balances.map(\.balance).max() ?? 0
        let hasAny = !balances.isEmpty || !usageData.isEmpty
        return VStack(spacing: 12) {
            if hasAny {
                Text(I18n.t("dashboard.remaining_balance")).font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            // Subscription cycle — fixed cost + time position, never amortized.
            if let start = subscriptionCycle.start, let period = subscriptionCycle.periodDays {
                let progress = StatsService.subscriptionProgress(start: start, periodDays: period, now: Date())
                let subDaily = ChartMath.finite(StatsService.subscriptionDailyAmortization(), fallback: 0)
                let daysInMonth = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
                let subMonthly = subDaily * daysInMonth
                let resetText = progress.nextReset.map {
                    $0.formatted(.dateTime.month(.abbreviated).day())
                } ?? "—"
                HStack(spacing: 6) {
                    Text("\(I18n.t("dashboard.sub_label")) \(String(format: "$%.0f", subMonthly))/\(I18n.t("dashboard.month"))")
                        .font(.caption).fontWeight(.medium)
                    Spacer()
                    Text(String(format: I18n.t("dashboard.cycle_progress"), progress.elapsedDays, progress.totalDays))
                        .font(.caption2).foregroundColor(.secondary)
                    Text(String(format: I18n.t("dashboard.cycle_reset"), resetText))
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            // API balances — bar length is relative to the largest balance in the
            // list (balances have no limit to derive a % from).
            ForEach(balances, id: \.providerId) { item in
                VStack(spacing: 3) {
                    HStack {
                        Text(item.displayName)
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text(balanceString(item.balance, currency: item.currency))
                            .font(.caption).fontWeight(.semibold).monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(nsColor: .quaternarySystemFill))
                                .frame(height: 5)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.marsGreen)
                                .frame(width: max(geo.size.width * (maxBalance > 0 ? item.balance / maxBalance : 0), 2), height: 5)
                        }
                    }
                    .frame(height: 5)
                }
            }
            // Subscription quotas (Claude / Copilot window utilization + reset)
            ForEach(Array(usageData.keys.sorted()), id: \.self) { toolId in
                if let d = usageData[toolId] {
                    quotaRow(toolId: toolId, data: d)
                }
            }
        }
    }

    var trendSection: some View {
        let dataReady = loadedTimeRange == timeRange
        guard dataReady else { return AnyView(EmptyView()) }

        let dataPreparationStartedAt = Date()
        let padStats = padStats(dailyStats, days: timeRange.days)
        let padCode = Self.padChanges(codeChanges, chartStart: chartStart, chartDays: chartDays)
        let balanceSpendByDay = dailyBalanceSpend
        let axes = makeTrendAxes(
            paddedStats: padStats,
            paddedCode: padCode,
            balanceSpendByDay: balanceSpendByDay
        )
        let spendAxis = axes.spend
        let codeAxis = axes.code
        let scale = ChartMath.finite(codeAxis.scale, fallback: 1)
        let leftMax = ChartMath.axisMax(spendAxis.max, fallback: 10)
        let leftValues = spendAxis.values
        let rightMax = ChartMath.axisMax(codeAxis.max, fallback: 10)
        let tokenMax = ChartMath.axisMax(Double(padStats.map(\.tokens).max() ?? 0), fallback: 1)
        let tokenStep = ChartMath.niceStep(tokenMax / 4)
        var tokenVals: [Double] = []
        var tv = 0.0
        while tv <= tokenMax + tokenStep / 2 {
            tokenVals.append(tv)
            tv += tokenStep
        }
        let tokenScale = ChartMath.finite(leftMax / tokenMax, fallback: 1)
        let chartJournalKey = [
            timeRange.cacheKey,
            String(padStats.count),
            String(padCode.count),
            String(Int((lastUpdated?.timeIntervalSince1970 ?? 0) * 1000)),
            String(leftMax),
        ].joined(separator: "|")
        let dataPreparationMs = Date().timeIntervalSince(dataPreparationStartedAt) * 1_000

        return AnyView(VStack(spacing: 12) {
            Text(I18n.t("dashboard.daily_trend")).font(.headline)
            let subDaily = ChartMath.finite(activeSnapshot?.subDaily ?? 0, fallback: 0)
                let now = Date()

                Chart {
                    // API spend bars
                    ForEach(padStats) { s in
                        let cal = Calendar.current; let d = cal.startOfDay(for: s.date)
                        let spend = ChartMath.barValue(
                            base: balanceSpendByDay[d] ?? 0,
                            progress: 1
                        )
                        BarMark(x: .value("Date", s.date, unit: .day), y: .value("Spend", spend))
                            .foregroundStyle(Color.marsGreen)
                            .position(by: .value("Series", I18n.t("dashboard.chart_cost")))
                    }
                    // Subscription bars (only up to today)
                    ForEach(padStats.filter { $0.date <= now }) { s in
                        BarMark(
                            x: .value("Date", s.date, unit: .day),
                            y: .value("Sub", ChartMath.barValue(base: subDaily, progress: 1))
                        )
                            .foregroundStyle(Color.marsGreenLight)
                            .position(by: .value("Series", I18n.t("dashboard.chart_cost")))
                    }
                    // Added lines
                    ForEach(padCode) { c in
                        BarMark(
                            x: .value("Date", c.date, unit: .day),
                            y: .value("Added", ChartMath.barValue(base: Double(c.added), progress: 1, scale: scale))
                        )
                            .foregroundStyle(Color.deepRed2)
                            .position(by: .value("Series", I18n.t("dashboard.chart_code")))
                    }
                    // Deleted lines
                    ForEach(padCode) { c in
                        BarMark(
                            x: .value("Date", c.date, unit: .day),
                            y: .value("Deleted", ChartMath.barValue(base: Double(c.deleted), progress: 1, scale: scale))
                        )
                            .foregroundStyle(Color.deepRed.opacity(0.35))
                            .position(by: .value("Series", I18n.t("dashboard.chart_code")))
                    }
                    // Token usage is a log fact and uses the right-hand axis.
                    ForEach(padStats) { s in
                        LineMark(
                            x: .value("Date", s.date, unit: .day),
                            y: .value("Tokens", ChartMath.barValue(base: Double(s.tokens), progress: 1, scale: tokenScale))
                        )
                            .foregroundStyle(Color.marsGreenLight)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.catmullRom)
                            .position(by: .value("Series", I18n.t("dashboard.chart_tokens")))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: dateStride) { _ in
                        AxisValueLabel(format: dateLabelFormat, orientation: .horizontal)
                    }
                }
                .chartXScale(domain: Self.chartXDomain(start: chartStart, days: chartDays))
                .chartYScale(domain: 0...leftMax)
                .chartYAxis {
                    AxisMarks(position: .leading, values: leftValues) { value in
                        AxisGridLine()
                        if let v = value.as(Double.self) { AxisValueLabel("$\(String(format: "%.1f", v))") }
                    }
                    AxisMarks(position: .trailing,
                              values: tokenVals.map { $0 * leftMax / tokenMax }) { value in
                        let idx = value.index
                        if idx < tokenVals.count {
                            AxisValueLabel(shortNum(ChartMath.safeInt(tokenVals[idx])))
                        }
                    }
                }
                .chartOverlay { proxy in
                    TrendChartOverlay(
                        proxy: proxy,
                        stats: padStats,
                        codeChanges: padCode,
                        subDaily: subDaily,
                        now: now,
                        tokenFormatter: Self.formattedTokenCount
                    )
                }
                .frame(height: 180)
                .id(timeRange)
                .transaction { $0.animation = nil }
                .task(id: chartJournalKey) {
                    guard dataReady, lastChartJournalKey != chartJournalKey else { return }
                    lastChartJournalKey = chartJournalKey
                    let now = Date()
                    DiagnosticJournal.log("chart_render", [
                        "range": .string(timeRange.cacheKey),
                        "daily_count": .int(padStats.count),
                        "code_count": .int(padCode.count),
                        "data_preparation_ms": .double(dataPreparationMs.isFinite ? dataPreparationMs : 0),
                        "range_to_chart_task_ms": .double(
                            rangeChangeStartedAt.map { max(0, now.timeIntervalSince($0) * 1_000) } ?? 0
                        ),
                        "spend_axis_max": .double(leftMax),
                        "code_axis_max": .double(rightMax),
                        "progress": .double(1),
                        "all_finite": .bool(
                            leftMax.isFinite && rightMax.isFinite
                                && scale.isFinite
                        ),
                    ])
                }
                // Legend
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.marsGreen).frame(width: 10, height: 10)
                        Text(I18n.t("dashboard.api_spend_label")).font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Capsule().fill(Color.marsGreenLight).frame(width: 10, height: 3)
                        Text(I18n.t("dashboard.chart_tokens")).font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.deepRed2).frame(width: 10, height: 10)
                        Text(I18n.t("dashboard.added_lines")).font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.deepRed).frame(width: 10, height: 10)
                        Text(I18n.t("dashboard.deleted_lines")).font(.caption).foregroundColor(.secondary)
                    }
                }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
        .opacity(Double(barProgress))
        .scaleEffect(0.98 + 0.02 * Double(barProgress))
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: barProgress))
    }

    /// Keeps cursor tracking local so hover changes in a 30-day chart cannot
    /// invalidate the whole dashboard while the page is being scrolled.
    private struct TrendChartOverlay: View {
        let proxy: ChartProxy
        let stats: [DailyStat]
        let codeChanges: [DailyCodeChange]
        let subDaily: Double
        let now: Date
        let tokenFormatter: (Int) -> String

        @State private var hoverDate: Date? = nil
        @State private var hoverX: CGFloat = 0
        @State private var hoverY: CGFloat = 0
        @State private var plotFrame: CGRect = .zero

        var body: some View {
            GeometryReader { geo in
                Color.clear
                    .onContinuousHover { phase in
                        if case .active(let loc) = phase,
                           let frame = proxy.plotFrame {
                            let pf = geo[frame]
                            let x = loc.x - pf.origin.x
                            let y = loc.y - pf.origin.y
                            guard x >= 0, x <= pf.width else {
                                hoverDate = nil
                                return
                            }
                            hoverX = x
                            hoverY = y
                            plotFrame = pf
                            hoverDate = proxy.value(atX: x)
                        } else {
                            hoverDate = nil
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let date = hoverDate,
                           let stat = stats.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }),
                           let code = codeChanges.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }),
                           stat.cost > 0 || code.added > 0 || code.deleted > 0 {
                            tooltip(
                                for: date,
                                stat: stat,
                                code: code,
                                tokenText: tokenFormatter(stat.tokens)
                            )
                        }
                    }
            }
        }

        private func tooltip(
            for date: Date,
            stat: DailyStat,
            code: DailyCodeChange,
            tokenText: String
        ) -> some View {
            let subCost = date <= now ? subDaily : 0
            let tipWidth: CGFloat = 120
            let tipHeight: CGFloat = 82
            let gap: CGFloat = 8
            let fitsRight = hoverX + gap + tipWidth <= plotFrame.width
            let rawX = fitsRight
                ? hoverX + gap
                : hoverX - tipWidth - gap
            let fitsAbove = hoverY - tipHeight - gap >= 0
            let rawY = fitsAbove
                ? hoverY - tipHeight - gap
                : hoverY + gap
            let x = plotFrame.origin.x + max(0, min(rawX, plotFrame.width - tipWidth))
            let y = plotFrame.origin.y + max(0, min(rawY, plotFrame.height - tipHeight))

            return VStack(alignment: .leading, spacing: 2) {
                Text(date, format: .dateTime.month(.abbreviated).day()).font(.caption).fontWeight(.semibold)
                Text(String(format: I18n.t("dashboard.tooltip_api"), String(format: "%.2f", stat.cost))).font(.caption2).monospacedDigit()
                Text(String(format: I18n.t("dashboard.tooltip_tokens"), tokenText)).font(.caption2).monospacedDigit()
                Text(String(format: I18n.t("dashboard.tooltip_sub"), String(format: "%.2f", subCost))).font(.caption2).monospacedDigit()
                Text(String(format: I18n.t("dashboard.tooltip_added"), code.added)).font(.caption2).monospacedDigit()
                Text(String(format: I18n.t("dashboard.tooltip_deleted"), code.deleted)).font(.caption2).monospacedDigit()
            }
            .padding(6).background(.regularMaterial).cornerRadius(6)
            .offset(x: max(0, x), y: max(0, y))
        }
    }

    // MARK: - Axis helpers

    func niceStep(_ rough: Double) -> Double {
        let magnitude = pow(10, floor(log10(max(rough, 1))))
        let normalized = rough / magnitude
        let nice: Double
        if normalized <= 1.5 { nice = 1 }
        else if normalized <= 3 { nice = 2 }
        else if normalized <= 7 { nice = 5 }
        else { nice = 10 }
        return nice * magnitude
    }

    func nextNiceStep(_ step: Double) -> Double {
        let niceSteps: [Double] = [1, 2, 5, 10]
        let magnitude = pow(10, floor(log10(max(step, 1))))
        let mantissa = step / magnitude
        if let idx = niceSteps.firstIndex(where: { $0 > mantissa + 0.001 }) {
            return niceSteps[idx] * magnitude
        }
        return 10 * magnitude
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
                result.append(DailyStat(date: date, cost: 0, calls: 0, tokens: 0, netLines: 0, costPerLine: 0))
            }
        }
        return result
    }

    // MARK: - Helpers



    /// Format integer to short form (e.g. "1K", "15K", "1M", "980").
    func shortNum(_ n: Int) -> String {
        if n >= 1_000_000 { return "\(n / 1_000_000)M" }
        if n >= 1_000     { return "\(n / 1_000)K" }
        return "\(n)"
    }

    /// Format token count to short human-readable form (e.g. "12.3K", "1.2M").
    static func formattedTokenCount(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16).padding(.horizontal, 20)
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onTapGesture {
            guard !isRefreshing else { return }
            isRefreshing = true
            Task {
                await forceRefresh()
                isRefreshing = false
            }
        }
    }

    @MainActor
    private func animateBarIfNeeded() {
        startEntryAnimation()
    }

    @MainActor
    private func startEntryAnimation() {
        entryAnimationToken += 1
        let token = entryAnimationToken
        barProgress = 0

        // Let SwiftUI commit the zero-progress frame before beginning the
        // spring. One millisecond is enough to avoid transaction coalescing;
        // all actual movement is driven by the spring below.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000)
            guard entryAnimationToken == token, barProgress == 0 else { return }
            withAnimation(.spring(response: 0.65, dampingFraction: 0.7)) {
                barProgress = 1
            }
        }
    }

    @MainActor
    private func forceRefresh() async {
        // Recompute and cache all three time ranges.
        // Then post a dashboardRefresh notification — the onReceive handler
        // calls load(), which reads the fresh cache. Single code path, no races.
        let sTodayStart = Calendar.current.startOfDay(for: Date())
        let weekDays = max((Calendar.current.dateComponents([.day], from: Calendar.mondayOfWeek(), to: sTodayStart).day ?? 0) + 1, 1)
        let ranges: [(range: TimeRange, days: Int)] = [
            (.today, 1),
            (.thisWeek, weekDays),
            (.days30, 30),
        ]

        if DemoData.isActive {
            for item in ranges {
                let demo = DemoData.data(for: item.range)
                rangeSnapshots[item.range] = Self.demoSnapshot(demo, for: item.range)
                demoRanges.insert(item.range)
            }
            return
        }

        for item in ranges {
            let snap = await StatsService.dashboardSnapshot(days: item.days)
            await storeSnapshot(snap, for: item.range)
        }
        triggerCloudSync()
        // Invalidate any in-flight load so the cache we just wrote is used
        loadGeneration += 1
        NotificationCenter.default.post(name: .dashboardRefresh, object: nil)
    }

    @MainActor
    private func storeSnapshot(_ rawSnap: DashboardSnapshot, for range: TimeRange, persist: Bool = true) async {
        let snap = rawSnap.sanitized()
        rangeSnapshots[range] = snap
        demoRanges.remove(range)

        let scalarValues = [
            snap.todayCost, snap.weekCost, snap.monthCost,
            snap.yesterdaySpend, snap.previousPeriodSpend,
        ]
        let trendValues = (snap.dailyStats + snap.balanceDaily).map(\.value)
        let allFinite = scalarValues.allSatisfy(\.isFinite)
            && trendValues.allSatisfy(\.isFinite)
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
        let dailyStats = data.dailyStats.map {
            TrendPoint(ts: $0.date.timeIntervalSince1970,
                       value: $0.cost,
                       calls: Int64($0.calls),
                       tokens: Int64($0.tokens),
                       netLines: $0.netLines)
        }
        let codeChanges = data.codeChanges.map {
            TrendPoint(ts: $0.date.timeIntervalSince1970,
                       value: Double($0.added),
                       calls: 0,
                       tokens: 0,
                       netLines: $0.added - $0.deleted,
                       added: $0.added,
                       deleted: $0.deleted)
        }
        let balanceDaily = data.dailyBalanceSpend.map { date, spend in
            TrendPoint(ts: date.timeIntervalSince1970,
                       value: spend,
                       calls: 0,
                       tokens: 0,
                       netLines: 0)
        }.sorted { $0.ts < $1.ts }

        return DashboardSnapshot(
            todayCost: range == .today ? data.combinedSpend : 0,
            weekCost: range == .thisWeek ? data.combinedSpend : 0,
            monthCost: range == .days30 ? data.combinedSpend : 0,
            yesterdaySpend: data.yesterdaySpend,
            previousPeriodSpend: data.previousPeriodSpend,
            subDaily: 0.67,
            todayCalls: Int64(data.todayCalls),
            todayTokens: Int64(data.todayTokens),
            providerBreakdown: data.balanceSpend.map {
                ProviderItem(providerId: $0.providerId, name: $0.name, cost: $0.spend)
            },
            toolBreakdown: data.toolCostBreakdown.map {
                NameCostItem(name: $0.name, cost: $0.cost)
            },
            topRepos: data.repos.map { repo in
                let totalChanges = repo.totalChanges
                return RepoItem(name: repo.repo,
                                cost: repo.cost,
                                added: repo.added,
                                deleted: repo.deleted,
                                cpl: totalChanges > 0 ? repo.cost * 1000 / Double(totalChanges) : 0)
            },
            prediction: PredictionItem(monthProjected: data.prediction.monthProjected,
                                       dailyRate: data.prediction.dailyRate,
                                       daysRemaining: data.prediction.daysRemaining,
                                       monthSoFar: data.prediction.monthSoFar),
            dailyStats: dailyStats,
            codeChanges: codeChanges,
            balanceDaily: balanceDaily
        ).sanitized()
    }

    @MainActor
    func load() async {
        // Every request runs (tab switch / refresh / data-change) — a hard
        // isLoading mutex would drop the newest tab's request while a slow load
        // is in flight, stranding the dashboard on the previous range. Instead
        // loadGeneration is the only gate: a stale generation discards itself.
        loadGeneration += 1
        let myGen = loadGeneration
        let requestedRange = timeRange  // capture this request's range so data can't drift tabs

        await loadUsageData()
        guard myGen == loadGeneration else { return }

        // ── Cache check — skip on initial load to avoid stale-data flash ──
        // Max age matches Phase 4 refresh intervals: today=5min, week=1h, 30d=12h
        let cacheMaxAge: TimeInterval = {
            switch requestedRange { case .today: return 300; case .thisWeek: return 3600; default: return 43200 }
        }()
        if let cached = await DashboardCache.read(timeRange: requestedRange.cacheKey, maxAge: cacheMaxAge) {
            guard myGen == loadGeneration else { return }
            // Debounce data-change reloads only when staying on the same range;
            // a tab switch must always apply the new range's snapshot.
            if loadedTimeRange == requestedRange,
               let last = lastSnapshotTS, abs(cached.updatedAt.timeIntervalSince(last)) < 1 {
                // Hydration can restore the current range before this first
                // load runs; show it immediately instead of leaving entry
                // progress at zero.
                animateBarIfNeeded()
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
            guard myGen == loadGeneration else { return }
            rangeSnapshots[requestedRange] = snap
            demoRanges.insert(requestedRange)
            animateBarIfNeeded()
            return
        }
        
        // ── Real data: use shared StatsService builder ──
        let snap = await StatsService.dashboardSnapshot(days: requestedRange.days)

        guard myGen == loadGeneration else { return }

        await storeSnapshot(snap, for: requestedRange)

        // ── Trigger entry animations (only when bars were reset by tab switch) ──
        animateBarIfNeeded()
    }

    @MainActor
    private func hydrateRangeSnapshotCache() async {
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
