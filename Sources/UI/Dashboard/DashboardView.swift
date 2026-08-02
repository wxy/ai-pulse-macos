import SwiftUI
import Charts
import GRDB

// MARK: - Color palette (#2C5B48 green / #AD2E23 red)
extension Color {
    static let marsGreen  = Color(red: 44/255, green: 91/255, blue: 72/255)   // #2C5B48
    static let marsGreen2 = Color(red: 61/255, green: 122/255, blue: 96/255)  // #3D7A60
    static let marsGreenLight = Color(red: 140/255, green: 196/255, blue: 170/255)  // #8CC4AA — subscription bars
    static let deepRed    = Color(red: 173/255, green: 46/255, blue: 35/255)  // #AD2E23
    static let deepRed2   = Color(red: 196/255, green: 74/255, blue: 63/255)  // #C44A3F
}

enum TimeRange: Hashable {
    case today
    case thisWeek
    case days30

    var days: Int {
        switch self {
        case .today: return 1
        case .thisWeek:
            return Calendar.current.dateComponents([.day], from: Calendar.mondayOfWeek(), to: Calendar.current.startOfDay(for: Date())).day! + 1
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

struct DashboardView: View {
    let initialTimeRange: TimeRange

    @State private var dailyStats: [DailyStat] = []
    @State private var providerCosts: [ProviderDailyCost] = []
    @State private var codeChanges: [DailyCodeChange] = []
    @State private var paddedChanges: [DailyCodeChange] = []
    @State private var repos: [RepoBreakdown] = []
    @State private var prediction: Prediction?
    @State private var timeRange: TimeRange
    @State private var costHoverDate: Date? = nil
    @State private var lastUpdated: Date? = nil
    @State private var isRefreshing = false
    @State private var isLoading = false
    @State private var lastSnapshotTS: Date? = nil
    @State private var lastDataChangeLoad: Date = .distantPast
    private let dataChangeThrottle: TimeInterval = 15  // min interval for data-change-driven reloads

    init(initialTimeRange: TimeRange = .today) {
        self.initialTimeRange = initialTimeRange
        self._timeRange = State(initialValue: initialTimeRange)
    }
    @State private var codeHoverDate: Date? = nil
    @State private var costHoverX: CGFloat = 0
    @State private var codeHoverX: CGFloat = 0
    @State private var editorMappings: [EditorDetector.Mapping] = []
    @State private var balanceSpend: [(providerId: String, name: String, spend: Double)] = []
    @State private var loadError: String? = nil
    @State private var healthSeverity = AppHealthMonitor.Severity.nominal
    @State private var healthMessages: [String] = []
    @State private var showHealthDetails = false
    @State private var usageData: [String: (percent: Double, limitStatus: String, resetAt: Double, windowSeconds: Double)] = [:]  // toolId → quota state
    @State private var trendHoverDate: Date? = nil
    @State private var trendHoverX: CGFloat = 0
    @State private var trendHoverY: CGFloat = 0
    @State private var trendPlotFrame: CGRect = .zero  // plot area in chart-view coords
    @State private var toolCostBreakdown: [(name: String, cost: Double)] = []
    @State private var dailyBalanceSpend: [Date: Double] = [:]  // date → USD spend
    @State private var i18nToken = 0  // bumped on language change to force re-render
    @State private var todayCombinedSpend: Double = 0
    @State private var weekCombinedSpend: Double = 0
    @State private var monthCombinedSpend: Double = 0
    @State private var todayCalls: Int = 0
    @State private var todayTokens: Int = 0
    @State private var yesterdaySpend: Double = 0
    @State private var previousPeriodSpend: Double = 0  // for 30-day comparison
    @State private var barProgress: CGFloat = 0  // 0→1 drives all entry animations
    @State private var loadedTimeRange: TimeRange? = nil  // set after data lands; gates bars against stale renders
    @State private var balanceErrors: Set<String> = []     // provider IDs whose API fetch failed
    @State private var remainingBalances: [RemainingBalanceItem] = []
    @State private var isDemoMode = false
    @State private var loadGeneration: Int = 0   // guards against stale concurrent loads
    @State private var toolsExpanded = false
    @State private var claudeDetailExpanded = false
    @State private var claudeStats: StatsService.ClaudeCodeStats?
    @State private var claudeStatsTS: Int64 = 0
    @State private var reposExpanded = false

    var hasActiveCostSources: Bool {
        !IntegrationRegistry.activeCostSources(editorMappings: editorMappings).isEmpty
    }


    /// Rounded-rect "ear" for the robot-head frame.
    /// Adaptive font size for donut chart center numbers — smaller for longer values.
    static func donutCenterFontSize(for value: Double) -> CGFloat {
        let chars = String(format: "%.2f", abs(value)).count  // e.g. "12345.67" = 8
        if chars <= 5 { return 16 }
        if chars <= 7 { return 14 }
        return 12
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
                Picker("", selection: $timeRange) {
                    Text(I18n.t("dashboard.today")).tag(TimeRange.today)
                    Text(I18n.t("dashboard.this_week")).tag(TimeRange.thisWeek)
                    Text(I18n.t("dashboard.days_30")).tag(TimeRange.days30)
                }.pickerStyle(.segmented).frame(width: 240)
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

                        // ── Trend frame (body) — daily trend chart ──
                        if timeRange != .today {
                            trendSection
                                .padding(20)
                                .background(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(Color.marsGreen.opacity(0.25), lineWidth: 2)
                                )
                                .padding(.horizontal, 60).padding(.bottom, 60)
                        } else if !remainingBalances.isEmpty {
                            remainingBalanceSection
                                .padding(20)
                                .background(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(Color.marsGreen.opacity(0.25), lineWidth: 2)
                                )
                                .padding(.horizontal, 60).padding(.bottom, 60)
                        }
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
            await load()
            ApiPoller.shared.pollAll()
            triggerCloudSync()
        }
        .onChange(of: timeRange) { _, _ in
            barProgress = 0
            Task { await load() }
            if claudeDetailExpanded { Task { await loadClaudeStats() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardRefresh)) { _ in
            // Manual refresh / forceRefresh — immediate, no throttle
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataDidChange)) { _ in
            // Background data change — throttle to avoid redundant work
            let now = Date()
            guard now.timeIntervalSince(lastDataChangeLoad) >= dataChangeThrottle else { return }
            lastDataChangeLoad = now
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appHealthDidChange)) { _ in
            let snap = AppHealthMonitor.shared.current
            healthSeverity = snap.severity
            healthMessages = snap.messages
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


    func computeToolCosts() -> [(name: String, cost: Double)] { toolCostBreakdown }

    func providerDisplayName(_ pid: String) -> String {
        IntegrationRegistry.all.first(where: { $0.id == pid })?.displayName ?? pid
    }

    // MARK: - Quota HUD

    func usageBarView(percent: Double) -> some View {
        let clamped = min(max(percent, 0), 100)
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

    /// Vertical stat cards between the two donut charts ("nose" of the robot face).
    @ViewBuilder var noseStatCards: some View {
        let added = codeChanges.reduce(0) { $0 + $1.added }
        let deleted = codeChanges.reduce(0) { $0 + $1.deleted }
        let netLines = added - deleted
        Group {
            smallCard(title: I18n.t("dashboard.net_lines"), value: "\(netLines)", color: netLines >= 0 ? .marsGreen : .deepRed)
            smallCard(title: I18n.t("dashboard.code_added"), value: "+\(added)", color: Color.marsGreen)
            smallCard(title: I18n.t("dashboard.code_deleted"), value: "-\(deleted)", color: .red)
            if timeRange == .today {
                smallCard(title: I18n.t("dashboard.request_count"), value: "\(todayCalls)", color: .primary)
                smallCard(title: I18n.t("dashboard.token_usage"), value: tokenShort(todayTokens), color: .primary)
            }
        }
    }

    // MARK: - Bottom cards row


    // MARK: - Spend overview

    var spendingOverview: some View {
        let apiSpend = balanceSpend.reduce(0.0) { $0 + $1.spend }
        let subDaily = StatsService.subscriptionDailyAmortization()
        let subTotal = subDaily * Double(timeRange.days)
        let totalCost: Double = {
            switch timeRange {
            case .today: return todayCombinedSpend
            case .thisWeek: return weekCombinedSpend
            case .days30: return monthCombinedSpend
            }
        }()

        let apiData = apiDonutData()
        let subVsApi = subVsApiDonutData(api: apiSpend, sub: subTotal)

        return VStack(spacing: 16) {
            // Big total
            VStack(spacing: 4) {
                // Cost number centered, badge as trailing overlay — doesn't affect centering
                Text("$\(String(format: "%.2f", totalCost))")
                    .font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.deepRed)
                    .scaleEffect(loadedTimeRange == timeRange ? (0.8 + 0.2 * barProgress) : 0.8)
                    .animation(.spring(response: 0.5, dampingFraction: 0.6), value: barProgress)
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 4) {
                            if timeRange == .today, yesterdaySpend > 0.001 {
                                comparisonBadge(current: totalCost, previous: yesterdaySpend)
                            }
                            if timeRange == .days30, previousPeriodSpend > 0.001 {
                                comparisonBadge(current: totalCost, previous: previousPeriodSpend)
                            }
                        }
                        .offset(x: 56)  // push badge to the right of the number
                    }
                HStack(spacing: 4) {
                    Text("\(timeRange.label) \(I18n.t("dashboard.api_spent"))")
                        .font(.caption).foregroundColor(.secondary)
                    // Per-tab context: today=projected, week/30d=daily avg + projected + remaining
                    if let p = prediction, p.monthProjected > 0.001 {
                        if timeRange == .today {
                            Text("· \(String(format: I18n.t("dashboard.today_expected"), String(format: "%.2f", p.dailyRate)))")
                        } else if timeRange == .thisWeek {
                            Text("· \(String(format: I18n.t("dashboard.range_context"), String(format: "%.2f", p.dailyRate * 7), 7 - timeRange.days))")
                        } else {
                            Text("· \(String(format: I18n.t("dashboard.range_context"), String(format: "%.2f", p.dailyRate * 30), p.daysRemaining))")
                        }
                    }
                }
                .font(.caption2).foregroundColor(.secondary)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 3)

            // Donuts flanking stat cards: left donut | nose stats | right donut
            HStack(alignment: .top, spacing: 12) {
                // Left: subscription vs API donut (placeholder when empty)
                if subVsApi.total > 0.001 {
                    subVsApiDonut(data: subVsApi)
                } else {
                    emptyDonut(title: I18n.t("dashboard.sub_api_ratio"))
                }

                // Center: stat cards as "nose" (vertical stack, limited width)
                VStack(spacing: 6) {
                    noseStatCards
                }
                .frame(width: 100)

                // Right: API provider donut (placeholder when empty)
                if !apiData.isEmpty {
                    apiProviderDonut(data: apiData, apiSpend: apiSpend)
                } else {
                    emptyDonut(title: I18n.t("dashboard.by_provider"))
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
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
                     "\(Int(data.percent))", data.limitStatus))
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
            usageData = map
        } catch {
            Logger.debug("Dashboard: loadUsageData failed: \(error)")
        }
    }

    func toolBarRow(name: String, cost: Double, total: Double, index: Int = 0) -> some View {
        let w = total > 0 ? cost / total : 0
        let dataReady = loadedTimeRange == timeRange
        let progress = dataReady ? barProgress : 0
        return VStack(spacing: 3) {
            HStack {
                Text(name).font(.caption).lineLimit(1)
                Spacer()
                Text("$\(String(format: "%.2f", cost))").font(.caption).monospacedDigit()
            }
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.marsGreen)
                    .frame(width: max(geo.size.width * w * progress, progress > 0.01 ? 4 : 0), height: 10)
            }
            .frame(height: 10)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(Double(index) * 0.04), value: progress)
    }

    struct DonutItem: Identifiable { let id = UUID(); let label: String; let cost: Double; let pct: Double; let color: Color }
    func apiDonutData() -> [DonutItem] {
        var map: [String: Double] = [:]
        for (pid, _, spend) in balanceSpend where spend > 0.001 {
            let name = IntegrationRegistry.all.first(where: { $0.id == pid })?.displayName ?? pid
            map[name] = (map[name] ?? 0) + spend
        }
        // Add error entries for providers whose balance fetch failed
        let tracked = IntegrationRegistry.balanceTrackedCostSources()
            .compactMap { cs -> String? in
                if case .apiKey(let pid) = cs.kind { return pid }; return nil
            }
        for pid in tracked where balanceErrors.contains(pid) && !map.keys.contains(pid) {
            let name = IntegrationRegistry.all.first(where: { $0.id == pid })?.displayName ?? pid
            map[name] = -1  // sentinel: error, not zero
        }
        let total = map.values.filter { $0 > 0 }.reduce(0, +)
        let colors: [Color] = [.deepRed, .marsGreen, .deepRed2, .marsGreen2, .deepRed, .marsGreen]
        return map.sorted(by: { $0.value > $1.value }).enumerated().map { (i, kv) in
            let isError = kv.value < 0
            return DonutItem(label: isError ? "\(kv.key) ⚠" : kv.key,
                             cost: isError ? 0 : kv.value,
                             pct: isError ? 0 : (total > 0 ? kv.value / total * 100 : 0),
                             color: isError ? .gray.opacity(0.5) : colors[i % colors.count])
        }
    }

    // MARK: - Output section

    var outputSection: some View {
        let totalCost: Double = {
            switch timeRange {
            case .today: return todayCombinedSpend
            case .thisWeek: return weekCombinedSpend
            case .days30: return monthCombinedSpend
            }
        }()
        let toolCosts = computeToolCosts()
        let dataReady = loadedTimeRange == timeRange

        return VStack(spacing: 12) {
            // ── Tool bars ("mouth") — hidden when no data ──
            if !toolCosts.isEmpty {
                let shown = toolsExpanded ? toolCosts : Array(toolCosts.prefix(4))
                VStack(alignment: .leading, spacing: 6) {
                    Text(I18n.t("dashboard.by_tool")).font(.caption).foregroundColor(.secondary)
                    ForEach(Array(shown.enumerated()), id: \.element.name) { idx, tc in
                        let displayName = tc.name == "Claude Code"
                            ? (claudeDetailExpanded ? "⌄ Claude Code" : "› Claude Code")
                            : tc.name
                        toolBarRow(name: displayName, cost: tc.cost, total: totalCost, index: idx)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if tc.name == "Claude Code" {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        claudeDetailExpanded.toggle()
                                    }
                                    if claudeDetailExpanded {
                                        Task { await loadClaudeStats() }
                                    }
                                }
                            }
                        if tc.name == "Claude Code" && claudeDetailExpanded {
                            claudeDetailCard
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    if toolCosts.count > 4 {
                        Button(toolsExpanded ? I18n.t("dashboard.show_less") : I18n.t("dashboard.show_all")) {
                            withAnimation { toolsExpanded.toggle() }
                        }
                        .font(.caption2)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
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

            // ── Repo list with cost + CPL ("chin/beard") ──
            // Use snapshot's pre-computed topRepos.cost directly — already
            // includes subscription scaling from dashboardSnapshot. Consistent
            // with what iOS reads from CloudKit.
            let shownRepos = repos.filter { $0.totalChanges > 0 }
            if !shownRepos.isEmpty {
                let maxCost = shownRepos.map(\.cost).max() ?? 1
                let maxCPL = shownRepos.compactMap { r in r.totalChanges > 0 ? r.cost * 1000 / Double(r.totalChanges) : nil }.max() ?? 1
                let shown = reposExpanded ? shownRepos : Array(shownRepos.prefix(5))
                VStack(alignment: .leading, spacing: 6) {
                    Text(I18n.t("dashboard.by_repo")).font(.caption).foregroundColor(.secondary)
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, r in
                        let combinedCPL = r.totalChanges > 0 ? r.cost * 1000 / Double(r.totalChanges) : 0
                        let costRatio = maxCost > 0 ? r.cost / maxCost : 0
                        let cplRatio = maxCPL > 0 ? combinedCPL / maxCPL : 0
                        let progress = dataReady ? barProgress : 0
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(r.repo).font(.caption).fontWeight(.medium).lineLimit(1)
                                Spacer()
                                Text("+\(r.added)/-\(r.deleted)")
                                    .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                            }
                            HStack(spacing: 6) {
                                Text("$\(String(format: "%.2f", r.cost))")
                                    .font(.caption2).monospacedDigit().frame(width: 64, alignment: .leading)
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color.marsGreen)
                                        .frame(width: max(geo.size.width * costRatio * progress, progress > 0.01 ? 4 : 0), height: 10)
                                }
                                .frame(height: 10)
                            }
                            HStack(spacing: 6) {
                                Text("CPL $\(String(format: "%.2f", combinedCPL))")
                                    .font(.caption2).monospacedDigit().foregroundColor(.secondary).frame(width: 64, alignment: .leading)
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.deepRed)
                                        .frame(width: max(geo.size.width * cplRatio * progress, progress > 0.01 ? 3 : 0), height: 8)
                                }
                                .frame(height: 8)
                            }
                        }
                        .padding(.vertical, 4)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(Double(idx) * 0.03), value: progress)
                        if r.id != shown.last?.id {
                            Divider()
                        }
                    }
                    if shownRepos.count > 5 {
                        Button(reposExpanded ? I18n.t("dashboard.show_less") : I18n.t("dashboard.show_all")) {
                            withAnimation { reposExpanded.toggle() }
                        }
                        .font(.caption2)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
    }

    // MARK: - Trend section

    /// Target grid-line count — both axes share the same number of sections.
    private let targetGrid = 4.0

    /// Left axis: cost (USD).
    private var trendSpendAxis: (max: Double, step: Double, values: [Double], sections: Int) {
        let padded = padStats(dailyStats, days: timeRange.days)
        let cal = Calendar.current
        let subDaily = StatsService.subscriptionDailyAmortization()
        let rawMax = padded.map { s -> Double in
            let d = cal.startOfDay(for: s.date)
            return (dailyBalanceSpend[d] ?? 0) + subDaily  // stacked total
        }.max() ?? 5
        let step = niceStep(rawMax / targetGrid)
        let max = ceil(rawMax / step) * step
        let sections = Int(max / step)
        var vals = [Double](); var v = 0.0
        while v <= max + step / 2 { vals.append(v); v += step }
        return (max, step, vals, sections)
    }

    /// Right axis: code lines. Same section count as left.
    private var trendCodeAxis: (max: Double, step: Double, values: [Double], scale: Double) {
        let padded = Self.padChanges(codeChanges, chartStart: chartStart, chartDays: chartDays)
        let rawMax = Double(padded.map { $0.added + $0.deleted }.max() ?? 1)
        let sections = Double(trendSpendAxis.sections)
        guard rawMax > 0, trendSpendAxis.max > 0, sections > 0 else { return (10, 2, [0, 2, 4, 6, 8, 10], 1) }
        var step = niceStep(rawMax / sections)
        while step * sections < rawMax { step = nextNiceStep(step) }
        let max = step * sections
        var vals = [Double](); var v = 0.0
        while v <= max + step / 2 { vals.append(v); v += step }
        let scale = trendSpendAxis.max / max
        return (max, step, vals, scale)
    }

    var remainingBalanceSection: some View {
        VStack(spacing: 12) {
            Text(I18n.t("dashboard.remaining_balance")).font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            // API balances
            ForEach(remainingBalances, id: \.providerId) { item in
                HStack {
                    Text(item.displayName)
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text(balanceString(item.balance, currency: item.currency))
                        .font(.caption).fontWeight(.semibold).monospacedDigit()
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
        let padStats = padStats(dailyStats, days: timeRange.days)
        let padCode = Self.padChanges(codeChanges, chartStart: chartStart, chartDays: chartDays)
        let noData = padStats.allSatisfy({ $0.cost == 0 }) && padCode.allSatisfy({ $0.added == 0 })
        let scale = trendCodeAxis.scale
        let leftMax = trendSpendAxis.max
        let leftValues = trendSpendAxis.values
        let rightVals = trendCodeAxis.values
        let rightMax = trendCodeAxis.max
        let dataReady = loadedTimeRange == timeRange
        let prog = Double(dataReady ? barProgress : 0)

        // Hide entirely when no data — don't show an empty chart shell
        if noData { return AnyView(EmptyView()) }

        return AnyView(VStack(spacing: 12) {
            Text(I18n.t("dashboard.daily_trend")).font(.headline)
            let subDaily = StatsService.subscriptionDailyAmortization()
                let now = Date()

                Chart {
                    // API spend bars
                    ForEach(padStats) { s in
                        let cal = Calendar.current; let d = cal.startOfDay(for: s.date)
                        let spend = (dailyBalanceSpend[d] ?? 0) * prog
                        BarMark(x: .value("Date", s.date, unit: .day), y: .value("Spend", spend))
                            .foregroundStyle(Color.marsGreen)
                            .position(by: .value("Series", I18n.t("dashboard.chart_cost")))
                    }
                    // Subscription bars (only up to today)
                    ForEach(padStats.filter { $0.date <= now }) { s in
                        BarMark(x: .value("Date", s.date, unit: .day), y: .value("Sub", subDaily * prog))
                            .foregroundStyle(Color.marsGreenLight)
                            .position(by: .value("Series", I18n.t("dashboard.chart_cost")))
                    }
                    // Added lines
                    ForEach(padCode) { c in
                        BarMark(x: .value("Date", c.date, unit: .day), y: .value("Added", Double(c.added) * scale * prog))
                            .foregroundStyle(Color.deepRed2)
                            .position(by: .value("Series", I18n.t("dashboard.chart_code")))
                    }
                    // Deleted lines
                    ForEach(padCode) { c in
                        BarMark(x: .value("Date", c.date, unit: .day), y: .value("Deleted", Double(c.deleted) * scale * prog))
                            .foregroundStyle(Color.deepRed.opacity(0.35))
                            .position(by: .value("Series", I18n.t("dashboard.chart_code")))
                    }
                }
                .animation(.spring(response: 0.6, dampingFraction: 0.7), value: barProgress)
                .chartXAxis {
                    AxisMarks(values: dateStride) { _ in
                        AxisValueLabel(format: dateLabelFormat, orientation: .horizontal)
                    }
                }
                .chartYScale(domain: 0...leftMax)
                .chartYAxis {
                    AxisMarks(position: .leading, values: leftValues) { value in
                        AxisGridLine()
                        if let v = value.as(Double.self) { AxisValueLabel("$\(String(format: "%.1f", v))") }
                    }
                    AxisMarks(position: .trailing,
                              values: rightVals.map { $0 * leftMax / rightMax }) { value in
                        let idx = value.index
                        if idx < rightVals.count {
                            AxisValueLabel(shortNum(Int(rightVals[idx])))
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Color.clear
                            .onContinuousHover { phase in
                                if case .active(let loc) = phase,
                                   let frame = proxy.plotFrame {
                                    let pf = geo[frame]
                                    let x = loc.x - pf.origin.x
                                    let y = loc.y - pf.origin.y
                                    guard x >= 0, x <= pf.width else { trendHoverDate = nil; return }
                                    trendHoverX = x
                                    trendHoverY = y
                                    trendPlotFrame = pf
                                    trendHoverDate = proxy.value(atX: x)
                                } else { trendHoverDate = nil }
                            }
                    }
                }
                .frame(height: 180)
                .overlay(alignment: .topLeading) {
                    if let hd = trendHoverDate,
                       let stat = padStats.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hd) }),
                       let code = padCode.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hd) }),
                       stat.cost > 0 || code.added > 0 || code.deleted > 0 {
                        let subCost = hd <= now ? subDaily : 0
                        // Try right of cursor; flip left only if the tooltip would overflow.
                        let tipW: CGFloat = 110
                        let tipH: CGFloat = 68
                        let gap: CGFloat = 8
                        let pw = trendPlotFrame.width
                        let ph = trendPlotFrame.height
                        let fitsRight = (trendHoverX + gap + tipW <= pw)
                        let rawX = fitsRight
                            ? trendHoverX + gap
                            : trendHoverX - tipW - gap
                        let fitsAbove = (trendHoverY - tipH - gap >= 0)
                        let rawY = fitsAbove
                            ? trendHoverY - tipH - gap
                            : trendHoverY + gap
                        let tipX = trendPlotFrame.origin.x + max(0, min(rawX, pw - tipW))
                        let tipY = trendPlotFrame.origin.y + max(0, min(rawY, ph - tipH))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hd, format: .dateTime.month(.abbreviated).day()).font(.caption).fontWeight(.semibold)
                            Text(String(format: I18n.t("dashboard.tooltip_api"), String(format: "%.2f", stat.cost))).font(.caption2).monospacedDigit()
                            Text(String(format: I18n.t("dashboard.tooltip_sub"), String(format: "%.2f", subCost))).font(.caption2).monospacedDigit()
                            Text(String(format: I18n.t("dashboard.tooltip_added"), code.added)).font(.caption2).monospacedDigit()
                            Text(String(format: I18n.t("dashboard.tooltip_deleted"), code.deleted)).font(.caption2).monospacedDigit()
                        }
                        .padding(6).background(.regularMaterial).cornerRadius(6)
                        .offset(x: max(0, tipX), y: max(0, tipY))
                    }
                }

                // Legend
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.marsGreen).frame(width: 10, height: 10)
                        Text(I18n.t("dashboard.api_spend_label")).font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.marsGreenLight).frame(width: 10, height: 10)
                        Text(I18n.t("dashboard.sub_label")).font(.caption).foregroundColor(.secondary)
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
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3))
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
        return cal.date(byAdding: .day, value: -(timeRange.days - 1), to: cal.startOfDay(for: Date()))!
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
    func tokenShort(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    func loadClaudeStats() async {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let since: Date
        switch timeRange {
        case .today:   since = todayStart
        case .thisWeek:
            since = Calendar.mondayOfWeek()
        case .days30:  since = cal.date(byAdding: .day, value: -29, to: todayStart)!
        }
        let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
        let stats = await StatsService.claudeCodeStats(sinceMs: sinceMs)
        await MainActor.run {
            claudeStats = stats
            claudeStatsTS = sinceMs
        }
    }

    @ViewBuilder
    var claudeDetailCard: some View {
        if let stats = claudeStats, stats.sessionCount > 0 {
            // Scale raw token-pricing costs to match dashboard tool bar total
            let rawTotal = stats.modelBreakdown.reduce(0.0) { $0 + $1.cost }
            let toolBarCost = computeToolCosts().first(where: { $0.name == "Claude Code" })?.cost ?? rawTotal
            let scale = rawTotal > 0 ? toolBarCost / rawTotal : 1.0
            VStack(alignment: .leading, spacing: 6) {
                Text("\(stats.sessionCount) sessions · avg \(String(format: "$%.2f", stats.avgCostPerSession * scale)) · top \(String(format: "$%.2f", stats.topSessionCost * scale))")
                    .font(.caption).foregroundColor(.secondary)

                if !stats.modelBreakdown.isEmpty {
                    let maxPct = stats.modelBreakdown.map(\.pct).max() ?? 1
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(stats.modelBreakdown, id: \.model) { mb in
                            let scaledCost = mb.cost * scale
                            HStack(spacing: 6) {
                                Text(mb.model)
                                    .font(.caption2).frame(width: 144, alignment: .leading)
                                GeometryReader { geo in
                                    let fullW = max(geo.size.width * CGFloat(mb.pct / maxPct), 4)
                                    let rawCacheW = fullW * CGFloat(mb.cacheRate)
                                    let minW: CGFloat = 3
                                    let cacheW = rawCacheW < minW ? 0
                                        : (rawCacheW > fullW - minW ? fullW - minW : rawCacheW)
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.deepRed.opacity(0.4))
                                            .frame(width: fullW, height: 8)
                                        if cacheW > 0 {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(Color.marsGreen.opacity(0.8))
                                                .frame(width: cacheW, height: 8)
                                        }
                                    }
                                }.frame(height: 8)
                                Text(String(format: "$%.2f", scaledCost))
                                    .font(.caption2).monospacedDigit().foregroundColor(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.leading, 28)
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
        let pct = (current - previous) / previous * 100
        if abs(pct) < 1 {
            Text("→")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color(nsColor: .quaternarySystemFill))
                .cornerRadius(4)
        } else if pct > 0 {
            let badge = "↑" + Int(round(pct)).formatted(.percent)
            Text(verbatim: badge)
                .font(.caption2).foregroundColor(.deepRed)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.deepRed.opacity(0.1))
                .cornerRadius(4)
        } else {
            let badge = "↓" + Int(round(-pct)).formatted(.percent)
            Text(verbatim: badge)
                .font(.caption2).foregroundColor(.marsGreen)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.marsGreen.opacity(0.1))
                .cornerRadius(4)
        }
    }

    // MARK: - Donut charts

    /// Data for subscription-vs-API donut chart.
    /// Gray placeholder donut shown when there's no data to fill it.
    /// Keeps the 3-column layout balanced instead of collapsing.
    func emptyDonut(title: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 60)
                    .frame(width: 120, height: 120)
                Text(I18n.t("dashboard.zero_cost"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 140)
    }

    func subVsApiDonutData(api: Double, sub: Double) -> (segments: [DonutItem], total: Double) {
        let total = api + sub
        var segments: [DonutItem] = []
        if api > 0.001 {
            segments.append(DonutItem(label: I18n.t("dashboard.api_paid"), cost: api,
                                      pct: total > 0 ? api / total * 100 : 0, color: .deepRed))
        }
        if sub > 0.001 {
            segments.append(DonutItem(label: I18n.t("dashboard.sub_label"), cost: sub,
                                      pct: total > 0 ? sub / total * 100 : 0, color: .marsGreen))
        }
        return (segments, total)
    }

    /// Subscription-vs-API donut chart.
    func subVsApiDonut(data: (segments: [DonutItem], total: Double)) -> some View {
        let dataReady = loadedTimeRange == timeRange
        return VStack(spacing: 6) {
            Text(I18n.t("dashboard.sub_api_ratio")).font(.caption).foregroundColor(.secondary)
            ZStack {
                Chart(data.segments) { item in
                    SectorMark(angle: .value("Cost", item.cost), innerRadius: .ratio(0.5), angularInset: 1)
                        .foregroundStyle(by: .value("Type", item.label))
                }
                .chartLegend(.hidden)
                .chartForegroundStyleScale(domain: data.segments.map(\.label),
                                           range: [Color.deepRed, .marsGreen, .deepRed2, .marsGreen2])
                .frame(width: 120, height: 120)
                Text("$\(String(format: "%.2f", data.total))")
                    .font(.system(size: Self.donutCenterFontSize(for: data.total), weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.deepRed)
            }
            .scaleEffect(dataReady ? (0.5 + 0.5 * barProgress) : 0.5)
            .opacity(dataReady ? barProgress : 0)
            VStack(spacing: 2) {
                ForEach(data.segments) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.label).font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text(verbatim: Int(item.pct).formatted(.percent)).font(.caption2).monospacedDigit().foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 140)
        .animation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.15), value: barProgress)
    }

    /// API provider donut chart.
    func apiProviderDonut(data: [DonutItem], apiSpend: Double) -> some View {
        let dataReady = loadedTimeRange == timeRange
        return VStack(spacing: 6) {
            Text(I18n.t("dashboard.by_provider")).font(.caption).foregroundColor(.secondary)
            ZStack {
                Chart(data) { item in
                    SectorMark(angle: .value("Cost", item.cost), innerRadius: .ratio(0.5), angularInset: 1)
                        .foregroundStyle(by: .value("Provider", item.label))
                }
                .chartLegend(.hidden)
                .chartForegroundStyleScale(domain: data.map(\.label), range: [Color.deepRed, .marsGreen, .deepRed2, .marsGreen2])
                .frame(width: 120, height: 120)
                Text("$\(String(format: "%.2f", apiSpend))")
                    .font(.system(size: Self.donutCenterFontSize(for: apiSpend), weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.deepRed)
            }
            .scaleEffect(dataReady ? (0.5 + 0.5 * barProgress) : 0.5)
            .opacity(dataReady ? barProgress : 0)
            VStack(spacing: 2) {
                ForEach(data) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.label).font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text(verbatim: Int(item.pct).formatted(.percent)).font(.caption2).monospacedDigit().foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 140)
        .animation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.2), value: barProgress)
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
        if let updated = lastUpdated {
            HStack {
                if isRefreshing {
                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                    Text(I18n.t("general.refreshing"))
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("\(I18n.t("dashboard.updated")) \(updated, format: .dateTime.minute().hour().day().month(.abbreviated))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16).padding(.horizontal, 20)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
            .onTapGesture {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await forceRefresh()
                    isRefreshing = false
                }
            }
        }
    }

    @MainActor
    private func animateBarIfNeeded() {
        guard barProgress < 0.5 else { return }
        barProgress = 0
        withAnimation(.spring(response: 0.65, dampingFraction: 0.7)) {
            barProgress = 1
        }
    }

    @MainActor
    private func forceRefresh() async {
        // Recompute and cache all three time ranges.
        // Then post a dashboardRefresh notification — the onReceive handler
        // calls load(), which reads the fresh cache. Single code path, no races.
                let sTodayStart = Calendar.current.startOfDay(for: Date())
        let weekDays = Calendar.current.dateComponents([.day], from: Calendar.mondayOfWeek(), to: sTodayStart).day! + 1
        let dayMap: [String: Int] = ["today": 1, "week": weekDays, "30d": 30]
        for (key, days) in dayMap {
            let snap = await StatsService.dashboardSnapshot(days: days)
            await DashboardCache.write(timeRange: key, json: snap.jsonString())
        }
        triggerCloudSync()
        // Invalidate any in-flight load so the cache we just wrote is used
        loadGeneration += 1
        NotificationCenter.default.post(name: .dashboardRefresh, object: nil)
    }

    /// Apply a cached snapshot to @State variables, skipping all DB queries.
    private func applySnapshot(_ snap: DashboardSnapshot) {
        todayCombinedSpend = snap.todayCost
        weekCombinedSpend = snap.weekCost
        monthCombinedSpend = snap.monthCost
        todayCalls = Int(snap.todayCalls)
        todayTokens = Int(snap.todayTokens)
        yesterdaySpend = snap.yesterdaySpend
        previousPeriodSpend = snap.previousPeriodSpend
        toolCostBreakdown = snap.toolBreakdown.map { (name: $0.name, cost: $0.cost) }
        balanceSpend = snap.providerBreakdown.map { (providerId: $0.providerId, name: $0.name, spend: $0.cost) }
        dailyBalanceSpend = snap.balanceDaily.reduce(into: [Date: Double]()) { map, p in
            map[Date(timeIntervalSince1970: p.ts)] = p.value
        }
        dailyStats = snap.dailyStats.map { p in
            DailyStat(date: Date(timeIntervalSince1970: p.ts), cost: p.value, calls: p.calls, tokens: p.tokens, netLines: p.netLines, costPerLine: 0)
        }
        codeChanges = snap.codeChanges.map { p in
            DailyCodeChange(date: Date(timeIntervalSince1970: p.ts), added: p.added, deleted: p.deleted)
        }
        repos = snap.topRepos.map { RepoBreakdown(repo: $0.name, cost: $0.cost, added: $0.added, deleted: $0.deleted, apiSources: [], subscriptionSources: []) }
        prediction = snap.prediction.map { Prediction(monthProjected: $0.monthProjected, dailyRate: $0.dailyRate, daysRemaining: $0.daysRemaining, monthSoFar: $0.monthSoFar) }
        lastUpdated = snap.updatedAt
        lastSnapshotTS = snap.updatedAt
        remainingBalances = snap.remainingBalances
        providerCosts = snap.providerBreakdown.map { ProviderDailyCost(date: Date(), providerId: $0.providerId, cost: $0.cost) }
        paddedChanges = Self.padChanges(codeChanges, chartStart: chartStart, chartDays: chartDays)
        isDemoMode = false
        loadedTimeRange = timeRange

        // Same entry animation as the full load path
        animateBarIfNeeded()
    }

    @MainActor
    func load() async {
        // Prevent concurrent loads — only one at a time.
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await loadUsageData()

        // Bump generation so only the latest load() applies its results.
        loadGeneration += 1
        let myGen = loadGeneration

        // ── Cache check — skip on initial load to avoid stale-data flash ──
        // Max age matches Phase 4 refresh intervals: today=5min, week=1h, 30d=12h
        let cacheMaxAge: TimeInterval = {
            switch timeRange { case .today: return 300; case .thisWeek: return 3600; default: return 43200 }
        }()
        if loadedTimeRange != nil,
           let cached = await DashboardCache.read(timeRange: timeRange.cacheKey, maxAge: cacheMaxAge) {
            guard myGen == loadGeneration else { return }
            // Skip if cache unchanged since last apply (debounce Phase-1 driven reloads)
            if let last = lastSnapshotTS, abs(cached.updatedAt.timeIntervalSince(last)) < 1 { return }
            applySnapshot(cached)
            Logger.debug("Dashboard: loaded from cache (\(timeRange.label))")
            return
        }

        // ── Synchronous prep ──
        let currentTimeRange = timeRange  // capture before async closures for sendability

        // ── Demo mode: auto-activates when no integrations configured ──
        let demoActive = DemoData.isActive
        if demoActive {
            let d = DemoData.data(for: currentTimeRange)
            guard myGen == loadGeneration else { return }
            await MainActor.run {
                dailyStats = d.dailyStats
                providerCosts = d.providerCosts
                codeChanges = d.codeChanges
                paddedChanges = Self.padChanges(d.codeChanges, chartStart: chartStart, chartDays: chartDays)
                repos = d.repos
                prediction = d.prediction
                balanceSpend = d.balanceSpend
                dailyBalanceSpend = d.dailyBalanceSpend
                todayCombinedSpend = currentTimeRange == .today ? d.combinedSpend : 0
                todayCalls = d.todayCalls
                todayTokens = d.todayTokens
                yesterdaySpend = d.yesterdaySpend
                previousPeriodSpend = d.previousPeriodSpend
                toolCostBreakdown = d.toolCostBreakdown
                isDemoMode = true
                loadedTimeRange = timeRange
                if barProgress < 0.5 { barProgress = 0; withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { barProgress = 1 } }
            }
            return
        }
        
        // ── Real data: use shared StatsService builder ──
        let snap = await StatsService.dashboardSnapshot(days: currentTimeRange.days)

        guard myGen == loadGeneration else { return }

        applySnapshot(snap)

        Task { await DashboardCache.write(timeRange: currentTimeRange.cacheKey, json: snap.jsonString()) }

        // ── Trigger entry animations (only when bars were reset by tab switch) ──
        animateBarIfNeeded()
    }

}
