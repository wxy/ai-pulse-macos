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

struct DashboardView: View {
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

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
    @State private var lastSnapshotTS: Date? = nil
    @State private var lastDataChangeLoad: Date = .distantPast
    private let dataChangeThrottle: TimeInterval = 15  // min interval for data-change-driven reloads
    @State private var lastChartJournalKey: String = ""

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
    @State private var toolCostBreakdown: [(name: String, cost: Double, tokens: Int64?, calls: Int?)] = []
    @State private var dailyBalanceSpend: [Date: Double] = [:]  // date → USD spend
    @State private var providerSourceKinds: [String: String] = [:]  // providerId → balance/usage/estimated
    @State private var modelBreakdownItems: [ModelCostItem] = []
    @State private var rateSeriesItems: [RateSeriesItem] = []
    @State private var subscriptionCycle: (start: Date?, periodDays: Int?) = (nil, nil)
    @State private var repoTokens: [String: Int64] = [:]  // repo name → token usage
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
    @State private var selectedToolForOverlay: String? = nil
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
                            if timeRange != .today {
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
            await load()
            ApiPoller.shared.pollAll()
            triggerCloudSync()
        }
        .onChange(of: timeRange) { _, newValue in
            DiagnosticJournal.log("range_change", [
                "to": .string(newValue.cacheKey),
            ])
            barProgress = 0
            Task { await load() }
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
        let subDaily = ChartMath.finite(StatsService.subscriptionDailyAmortization(), fallback: 0)
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
                    emptyDonut(title: I18n.t("dashboard.actual_spend"))
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
                    emptyDonut(title: I18n.t("dashboard.by_tool"))
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
            usageData = map
        } catch {
            Logger.debug("Dashboard: loadUsageData failed: \(error)")
        }
    }

    struct DonutItem: Identifiable { let id = UUID(); let label: String; let cost: Double; let pct: Double; let color: Color }

    /// SectorMark cannot safely render an all-zero angle set (for example, a
    /// provider that is configured but currently reporting an error). Keep such
    /// entries out of chart geometry and show a placeholder at the call site.
    static func renderableDonutSegments(_ segments: [DonutItem]) -> [DonutItem] {
        segments.filter { $0.cost.isFinite && $0.cost > 0.001 }
    }

    private func toolIdToDisplay(_ id: String) -> String? {
        IntegrationRegistry.all.contains { $0.id == id } ? IntegrationRegistry.toolDisplayName(for: id) : nil
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
	                                .dashboardTableCell(isHeader: true, alignment: .leading)
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
        let shownRepos = repos.filter { $0.totalChanges > 0 }
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

    /// Left axis: cost (USD).
    private var trendSpendAxis: (max: Double, step: Double, values: [Double], sections: Int) {
        let padded = padStats(dailyStats, days: timeRange.days)
        let cal = Calendar.current
        let subDaily = StatsService.subscriptionDailyAmortization()
        let rawMax = padded.map { s -> Double in
            let d = cal.startOfDay(for: s.date)
            return (dailyBalanceSpend[d] ?? 0) + subDaily  // stacked total
        }.max() ?? 5
        let safeRawMax = ChartMath.axisMax(rawMax, fallback: 5)
        let step = ChartMath.niceStep(safeRawMax / targetGrid)
        let max = ChartMath.axisMax(ceil(safeRawMax / step) * step, fallback: step)
        let sections = Swift.max(1, Int((max / step).rounded(.toNearestOrEven)))
        var vals = [Double](); var v = 0.0
        while v <= max + step / 2 {
            vals.append(ChartMath.finite(v, fallback: max))
            v += step
        }
        return (max, step, vals, sections)
    }

    /// Right axis: code lines. Same section count as left.
    private var trendCodeAxis: (max: Double, step: Double, values: [Double], scale: Double) {
        let padded = Self.padChanges(codeChanges, chartStart: chartStart, chartDays: chartDays)
        let rawMax = Double(padded.map { $0.added + $0.deleted }.max() ?? 1)
        let sections = Double(trendSpendAxis.sections)
        guard rawMax > 0, trendSpendAxis.max > 0, sections > 0 else { return (10, 2, [0, 2, 4, 6, 8, 10], 1) }
        var step = ChartMath.niceStep(rawMax / sections)
        while step * sections < rawMax { step = ChartMath.nextNiceStep(step) }
        let max = step * sections
        var vals = [Double](); var v = 0.0
        while v <= max + step / 2 {
            vals.append(ChartMath.finite(v, fallback: max))
            v += step
        }
        let scale = ChartMath.scale(trendSpendAxis.max, denominator: max, fallback: 1)
        return (max, step, vals, scale)
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
        let padStats = padStats(dailyStats, days: timeRange.days)
        let padCode = Self.padChanges(codeChanges, chartStart: chartStart, chartDays: chartDays)
        let noData = padStats.allSatisfy({ $0.cost == 0 }) && padCode.allSatisfy({ $0.added == 0 })
        let scale = ChartMath.finite(trendCodeAxis.scale, fallback: 1)
        let leftMax = ChartMath.axisMax(trendSpendAxis.max, fallback: 10)
        let leftValues = trendSpendAxis.values
        let rightMax = ChartMath.axisMax(trendCodeAxis.max, fallback: 10)
        let tokenMax = ChartMath.axisMax(Double(padStats.map(\.tokens).max() ?? 0), fallback: 1)
        let tokenStep = ChartMath.niceStep(tokenMax / 4)
        var tokenVals: [Double] = []
        var tv = 0.0
        while tv <= tokenMax + tokenStep / 2 {
            tokenVals.append(tv)
            tv += tokenStep
        }
        let tokenScale = ChartMath.finite(leftMax / tokenMax, fallback: 1)
        let dataReady = loadedTimeRange == timeRange
        let prog = ChartMath.progress(Double(dataReady ? barProgress : 0))
        let chartJournalKey = [
            timeRange.cacheKey,
            String(padStats.count),
            String(padCode.count),
            String(Int((lastUpdated?.timeIntervalSince1970 ?? 0) * 1000)),
            String(leftMax),
        ].joined(separator: "|")

        // Hide entirely when no data — don't show an empty chart shell
        if noData { return AnyView(EmptyView()) }

        return AnyView(VStack(spacing: 12) {
            Text(I18n.t("dashboard.daily_trend")).font(.headline)

            Chart {
                // API spend bars — balance deltas only (facts)
                ForEach(padStats) { s in
                    let cal = Calendar.current; let d = cal.startOfDay(for: s.date)
                    let spend = ChartMath.barValue(
                        base: dailyBalanceSpend[d] ?? 0,
                        progress: prog
                    )
                    BarMark(x: .value("Date", s.date, unit: .day), y: .value("Spend", spend))
                        .foregroundStyle(Color.marsGreen)
                        .position(by: .value("Series", I18n.t("dashboard.chart_cost")))
                }
                // Added lines
                ForEach(padCode) { c in
                    BarMark(
                        x: .value("Date", c.date, unit: .day),
                        y: .value("Added", ChartMath.barValue(base: Double(c.added), progress: prog, scale: scale))
                    )
                        .foregroundStyle(Color.deepRed2)
                        .position(by: .value("Series", I18n.t("dashboard.chart_code")))
                }
                // Deleted lines
                ForEach(padCode) { c in
                    BarMark(
                        x: .value("Date", c.date, unit: .day),
                        y: .value("Deleted", ChartMath.barValue(base: Double(c.deleted), progress: prog, scale: scale))
                    )
                        .foregroundStyle(Color.deepRed.opacity(0.35))
                        .position(by: .value("Series", I18n.t("dashboard.chart_code")))
                }
                // Token usage — log fact curve on the right axis
                ForEach(padStats) { s in
                    LineMark(
                        x: .value("Date", s.date, unit: .day),
                        y: .value("Tokens", ChartMath.barValue(base: Double(s.tokens), progress: prog, scale: tokenScale))
                    )
                        .foregroundStyle(Color.marsGreenLight)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                        .position(by: .value("Series", I18n.t("dashboard.chart_tokens")))
                }
            }
                .id(timeRange)
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
                .task(id: chartJournalKey) {
                    guard dataReady, lastChartJournalKey != chartJournalKey else { return }
                    lastChartJournalKey = chartJournalKey
                    DiagnosticJournal.log("chart_render", [
                        "range": .string(timeRange.cacheKey),
                        "daily_count": .int(padStats.count),
                        "code_count": .int(padCode.count),
                        "spend_axis_max": .double(leftMax),
                        "code_axis_max": .double(rightMax),
                        "progress": .double(prog),
                        "all_finite": .bool(
                            leftMax.isFinite && rightMax.isFinite
                                && scale.isFinite && prog.isFinite
                        ),
                    ])
                }
                .overlay(alignment: .topLeading) {
                    if let hd = trendHoverDate,
                       let stat = padStats.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hd) }),
                       let code = padCode.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hd) }),
                       stat.cost > 0 || code.added > 0 || code.deleted > 0 {
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
                            Text(String(format: I18n.t("dashboard.tooltip_tokens"), tokenShort(Int(clamping: stat.tokens)))).font(.caption2).monospacedDigit()
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
        )
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
    func tokenShort(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
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
    /// Gray placeholder donut shown when there's no data to fill it.
    /// Keeps the 3-column layout balanced instead of collapsing.
    func emptyDonut(title: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            ZStack {
                // Ring geometry matches the real donuts (SectorMark innerRadius .ratio(0.5)
                // in a 120×120 chart): inner radius 30, outer radius 60, thickness 30.
                // A larger lineWidth would bleed the stroke past the outer radius.
                Circle()
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 30)
                    .frame(width: 90, height: 90)
                Text(I18n.t("dashboard.zero_cost"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 120, height: 120)
        }
        .frame(maxWidth: 140)
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
        let weekDays = max((Calendar.current.dateComponents([.day], from: Calendar.mondayOfWeek(), to: sTodayStart).day ?? 0) + 1, 1)
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

    /// Apply a snapshot to @State variables, skipping all DB queries.
    /// `range` is the time range this snapshot was computed for — loadedTimeRange
    /// must match the data, not the (possibly already-switched) current tab.
    private func applySnapshot(_ rawSnap: DashboardSnapshot, for range: TimeRange) {
        let snap = rawSnap.sanitized()
        todayCombinedSpend = snap.todayCost
        weekCombinedSpend = snap.weekCost
        monthCombinedSpend = snap.monthCost
        todayCalls = Int(snap.todayCalls)
        todayTokens = Int(snap.todayTokens)
        yesterdaySpend = snap.yesterdaySpend
        previousPeriodSpend = snap.previousPeriodSpend
        toolCostBreakdown = snap.toolBreakdown.map {
            (name: $0.name, cost: $0.cost, tokens: $0.tokens, calls: $0.calls)
        }
        balanceSpend = snap.providerBreakdown.map { (providerId: $0.providerId, name: $0.name, spend: $0.cost) }
        var mergedProviderKinds: [String: String] = [:]
        for provider in snap.providerBreakdown where mergedProviderKinds[provider.providerId] == nil {
            mergedProviderKinds[provider.providerId] = provider.sourceKind ?? "balance"
        }
        providerSourceKinds = mergedProviderKinds
        dailyBalanceSpend = snap.balanceDaily.reduce(into: [Date: Double]()) { map, p in
            map[Date(timeIntervalSince1970: p.ts)] = p.value
        }
        dailyStats = snap.dailyStats.map { p in
            DailyStat(date: Date(timeIntervalSince1970: p.ts), cost: p.value, calls: Int(p.calls), tokens: Int(p.tokens), netLines: p.netLines, costPerLine: 0)
        }
        codeChanges = snap.codeChanges.map { p in
            DailyCodeChange(date: Date(timeIntervalSince1970: p.ts), added: p.added, deleted: p.deleted)
        }
        repos = snap.topRepos.map { RepoBreakdown(repo: $0.name, cost: $0.cost, added: $0.added, deleted: $0.deleted, apiSources: [], subscriptionSources: []) }
        var mergedRepoTokens: [String: Int64] = [:]
        for repo in snap.topRepos {
            mergedRepoTokens[repo.name, default: 0] += repo.tokens ?? 0
        }
        repoTokens = mergedRepoTokens
        prediction = snap.prediction.map { Prediction(monthProjected: $0.monthProjected, dailyRate: $0.dailyRate, daysRemaining: $0.daysRemaining, monthSoFar: $0.monthSoFar) }
        lastUpdated = snap.updatedAt
        lastSnapshotTS = snap.updatedAt
        remainingBalances = snap.remainingBalances
        providerCosts = snap.providerBreakdown.map { ProviderDailyCost(date: Date(), providerId: $0.providerId, cost: $0.cost) }
        modelBreakdownItems = snap.modelBreakdown
        rateSeriesItems = snap.rateSeries
        subscriptionCycle = (snap.subscriptionStart, snap.subscriptionPeriodDays)
        paddedChanges = Self.padChanges(codeChanges, chartStart: chartStart, chartDays: chartDays)
        isDemoMode = false
        loadedTimeRange = range

        let scalarValues = [
            rawSnap.todayCost, rawSnap.weekCost, rawSnap.monthCost,
            rawSnap.yesterdaySpend, rawSnap.previousPeriodSpend,
        ]
        let trendValues = (rawSnap.dailyStats + rawSnap.balanceDaily).map(\.value)
        let allFinite = scalarValues.allSatisfy(\.isFinite)
            && trendValues.allSatisfy(\.isFinite)
            && rawSnap.balanceDaily.allSatisfy { $0.ts.isFinite }
            && rawSnap.dailyStats.allSatisfy { $0.ts.isFinite }
        DiagnosticJournal.log("apply_snapshot", [
            "loaded_range": .string(range.cacheKey),
            "daily_count": .int(rawSnap.dailyStats.count),
            "balance_day_count": .int(rawSnap.balanceDaily.count),
            "code_count": .int(rawSnap.codeChanges.count),
            "provider_count": .int(rawSnap.providerBreakdown.count),
            "all_finite": .bool(allFinite),
        ])

        // Same entry animation as the full load path
        animateBarIfNeeded()
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
        if loadedTimeRange != nil,
           let cached = await DashboardCache.read(timeRange: requestedRange.cacheKey, maxAge: cacheMaxAge) {
            guard myGen == loadGeneration else { return }
            // Debounce data-change reloads only when staying on the same range;
            // a tab switch must always apply the new range's snapshot.
            if loadedTimeRange == requestedRange,
               let last = lastSnapshotTS, abs(cached.updatedAt.timeIntervalSince(last)) < 1 { return }
            applySnapshot(cached, for: requestedRange)
            Logger.debug("Dashboard: loaded from cache (\(requestedRange.label))")
            return
        }

        // ── Synchronous prep ──
        let currentTimeRange = requestedRange  // capture before async closures for sendability

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
                toolCostBreakdown = d.toolCostBreakdown.map {
                    (name: $0.name, cost: $0.cost, tokens: nil, calls: nil)
                }
                isDemoMode = true
                loadedTimeRange = currentTimeRange
                if barProgress < 0.5 { barProgress = 0; withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { barProgress = 1 } }
            }
            return
        }
        
        // ── Real data: use shared StatsService builder ──
        let snap = await StatsService.dashboardSnapshot(days: currentTimeRange.days)

        guard myGen == loadGeneration else { return }

        applySnapshot(snap, for: currentTimeRange)

        Task { await DashboardCache.write(timeRange: currentTimeRange.cacheKey, json: snap.jsonString()) }

        // ── Trigger entry animations (only when bars were reset by tab switch) ──
        animateBarIfNeeded()
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
