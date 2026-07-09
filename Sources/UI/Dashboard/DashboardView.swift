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
            let cal = Calendar.current
            var monCal = cal; monCal.firstWeekday = 2
            let monday = monCal.date(from: monCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
            return cal.dateComponents([.day], from: monday, to: cal.startOfDay(for: Date())).day! + 1
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

    init(initialTimeRange: TimeRange = .thisWeek) {
        self.initialTimeRange = initialTimeRange
        self._timeRange = State(initialValue: initialTimeRange)
    }
    @State private var codeHoverDate: Date? = nil
    @State private var costHoverX: CGFloat = 0
    @State private var codeHoverX: CGFloat = 0
    @State private var subDaily: [ChartDataPoint] = []
    @State private var apiDaily: [ChartDataPoint] = []
    @State private var editorMappings: [EditorDetector.Mapping] = []
    @State private var balanceSpend: [(providerId: String, name: String, spend: Double)] = []
    @State private var balanceDaily: [ChartDataPoint] = []
    @State private var loadError: String? = nil
    @State private var healthSeverity = AppHealthMonitor.Severity.nominal
    @State private var healthMessages: [String] = []
    @State private var showHealthDetails = false
    @State private var usageData: [String: (percent: Double, limitStatus: String)] = [:]  // costSourceId → (usage%, status)
    @State private var trendHoverDate: Date? = nil
    @State private var trendHoverX: CGFloat = 0
    @State private var trendHoverY: CGFloat = 0
    @State private var trendPlotFrame: CGRect = .zero  // plot area in chart-view coords
    @State private var toolCostBreakdown: [(name: String, cost: Double)] = []
    @State private var dailyBalanceSpend: [Date: Double] = [:]  // date → USD spend
    @State private var todayCombinedSpend: Double = 0
    @State private var todayCalls: Int = 0
    @State private var todayTokens: Int = 0
    @State private var yesterdaySpend: Double = 0
    @State private var previousPeriodSpend: Double = 0  // for 30-day comparison
    @State private var barProgress: CGFloat = 0  // 0→1 drives all entry animations
    @State private var loadedTimeRange: TimeRange? = nil  // set after data lands; gates bars against stale renders
    @State private var balanceErrors: Set<String> = []     // provider IDs whose API fetch failed

    var hasActiveCostSources: Bool {
        !IntegrationRegistry.activeCostSources(editorMappings: editorMappings).isEmpty
    }

    var hasCertainEditorMapping: Bool {
        editorMappings.contains { $0.confidence == .certain && $0.dailySubscriptionCost > 0 }
    }

    /// Rounded-rect "ear" for the robot-head frame.
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
                    if hasActiveCostSources || !providerCosts.isEmpty {
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
                        }
                    } else {
                        emptyStateCard
                    }
                }
            }
        }
        .frame(width: 700, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: I18n.getLang() == "zh" ? "zh_CN" : "en_US"))
        .task {
            ApiPoller.shared.pollAll()
            await load()
        }
        .onChange(of: timeRange) { _, _ in
            barProgress = 0  // collapse bars immediately, avoid stale-data render
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardRefresh)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataDidChange)) { _ in
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

    func estimatedDailySub(_ id: String) -> Double {
        let cfg = IntegrationRegistry.config(for: id)
        guard !cfg.subscriptionTier.isEmpty else { return 0 }
        let days = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
        if let tool = SubscriptionRegistry.tool(forName: toolName(for: id)),
           let tier = tool.tiers.first(where: { $0.label == cfg.subscriptionTier }) {
            return tier.fee / days
        }
        return 0
    }

    // MARK: - Cost Source summary

    /// Active CostSources with their computed spend for the current period.
    var costSourceBreakdown: [(source: CostSource, cost: Double, usagePercent: Double?)] {
        let sources = IntegrationRegistry.activeCostSources(editorMappings: editorMappings)
        let subTotal = StatsService.subscriptionDailyAmortization() * Double(timeRange.days)
        // sum of monthly fees of all subscription sources (for proportional split)
        let totalSubFee = sources.reduce(0.0) { total, cs in
            if case .subscription(_, _, let fee) = cs.kind { return total + fee }; return total
        }
        var result: [(source: CostSource, cost: Double, usagePercent: Double?)] = []
        for cs in sources {
            let cost: Double
            switch cs.kind {
            case .apiKey(let pid):
                cost = balanceSpend
                    .filter { $0.providerId == pid }
                    .reduce(0) { $0 + $1.spend }
            case .subscription(_, _, let fee):
                cost = totalSubFee > 0 ? subTotal * fee / totalSubFee : 0
            case .unknown:
                cost = 0
            }
            let usage = usageData[cs.id]
            result.append((cs, cost, usage?.percent))
        }
        return result.sorted { $0.cost > $1.cost }
    }

    var costSourceSummary: some View {
        let breakdown = costSourceBreakdown
        let totalCost = breakdown.reduce(0) { $0 + $1.cost }
        let added = codeChanges.reduce(0) { $0 + $1.added }
        let deleted = codeChanges.reduce(0) { $0 + $1.deleted }

        return VStack(spacing: 10) {
            // Total
            HStack {
                Text("\(timeRange.label)\(I18n.t("dashboard.api_spent"))")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("$\(String(format: "%.2f", totalCost))")
                    .font(.title3).fontWeight(.bold).monospacedDigit()
            }
            .padding(12)
            .background(Color(nsColor: .quaternarySystemFill).opacity(0.6))
            .cornerRadius(8)

            if !breakdown.isEmpty {
                VStack(spacing: 4) {
                    ForEach(breakdown, id: \.source.id) { item in
                        costSourceRow(item)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .quaternarySystemFill).opacity(0.3))
                .cornerRadius(8)
            }

            // Code changes at a glance
            HStack(spacing: 8) {
                smallCard(title: "\(timeRange.label)\(I18n.t("dashboard.code_added"))",
                          value: "+\(added)", color: Color.marsGreen)
                smallCard(title: "\(timeRange.label)\(I18n.t("dashboard.code_deleted"))",
                          value: "-\(deleted)", color: .deepRed)
            }

            // Tool summary (compact spending by dev tool)
            let toolCosts = computeToolCosts()
            if !toolCosts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(I18n.t("dashboard.by_tool")).font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(toolCosts.prefix(5), id: \.name) { tc in
                            VStack(spacing: 2) {
                                Text(tc.name).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                Text("$\(String(format: "%.2f", tc.cost))")
                                    .font(.caption).monospacedDigit()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(nsColor: .quaternarySystemFill))
                            .cornerRadius(6)
                        }
                    }
                }
            }
        }
    }

    func computeToolCosts() -> [(name: String, cost: Double)] { toolCostBreakdown }

    func providerDisplayName(_ pid: String) -> String {
        IntegrationRegistry.all.first(where: { $0.id == pid })?.displayName ?? pid
    }

    func costSourceRow(_ item: (source: CostSource, cost: Double, usagePercent: Double?)) -> some View {
        let cs = item.source
        let cost = item.cost
        let usage = item.usagePercent
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                confidenceBadge(cs.confidence)
                Text(cs.label).font(.caption).lineLimit(1)
                Spacer()
                Text(cost > 0.001 ? "$\(String(format: "%.2f", cost))" : "--")
                    .font(.caption).monospacedDigit()
                    .foregroundColor(confidenceColor(cs.confidence))

                if !cs.limitations.isEmpty {
                    Image(systemName: "info.circle")
                        .font(.caption2).foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .help(cs.limitations.joined(separator: "\n"))
                }
                if let usage, usage > 0 {
                    usageBarView(percent: usage)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
        }
    }

    func usageBarView(percent: Double) -> some View {
        let clamped = min(max(percent, 0), 100)
        let barColor: Color = switch clamped {
        case 0..<75:  .marsGreen
        case 75..<90: .marsGreen2
        default:      .deepRed
        }
        let label = clamped > 100 ? I18n.t("dashboard.over_limit") : "\(Int(clamped))%"
        return HStack(spacing: 2) {
            Text(label)
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
            Text(title).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    func apiDailyAvg() -> Double {
        let total = dailyStats.reduce(0.0) { $0 + $1.cost }
        let days = max(dailyStats.filter { $0.cost > 0.001 }.count, 1)
        return total / Double(days)
    }

    var subSources: [CostSource] {
        IntegrationRegistry.activeCostSources(editorMappings: editorMappings).filter {
            if case .subscription(_, _, _) = $0.kind { return true }; return false
        }
    }

    func totalSubMonthly() -> Double {
        subSources.reduce(0.0) { sum, cs in
            if case .subscription(_, _, let fee) = cs.kind { return sum + fee }
            return sum
        }
    }

    func totalSubDaily() -> Double {
        let days = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
        return subSources.reduce(0.0) { sum, cs in
            if case .subscription(_, _, let fee) = cs.kind { return sum + fee / days }
            return sum
        }
    }

    func toolName(for id: String) -> String {
        switch id {
        case "cursor": return "Cursor"
        case "copilot": return "GitHub Copilot"
        case "windsurf": return "Windsurf"
        default: return id
        }
    }

    // MARK: - Cost chart (API balance + subscription amortization, stacked)

    var costChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(I18n.t("dashboard.cost_chart")).font(.headline)

            if subSources.isEmpty {
                Text(I18n.t("menu.no_usage")).foregroundColor(.secondary).padding(.vertical, 30)
            } else {
                ZStack(alignment: .topLeading) {
                    Chart {
                        ForEach(subDaily + balanceDaily, id: \.id) { item in
                            BarMark(
                                x: .value("Date", item.date, unit: .day),
                                y: .value("Cost", item.cost)
                            )
                            .foregroundStyle(by: .value("Source", item.label))
                        }
                        if let hd = costHoverDate {
                            RuleMark(x: .value("Date", hd, unit: .day))
                                .foregroundStyle(.gray.opacity(0.3))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: dateStride) { _ in
                            AxisValueLabel(format: dateLabelFormat, orientation: .horizontal)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine()
                            AxisValueLabel()
                        }
                    }
                    .chartYAxisLabel(I18n.t("dashboard.cost_usd"))
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let loc):
                                        guard let frame = proxy.plotFrame else { return }
                                        let x = loc.x - geo[frame].origin.x
                                        guard x >= 0, x <= geo[frame].width else { return }
                                        if let date = proxy.value(atX: x) as Date?,
                                           !Calendar.current.isDate(date, inSameDayAs: costHoverDate ?? Date.distantPast) {
                                            costHoverX = x
                                            costHoverDate = date
                                        }
                                    case .ended:
                                        costHoverDate = nil
                                    }
                                }
                        }
                    }
                    .frame(height: 200)

                    if let hd = costHoverDate {
                        let cal = Calendar.current
                        let daySubs = subDaily.filter { cal.isDate($0.date, inSameDayAs: hd) }
                        let dayBal = balanceDaily.filter { cal.isDate($0.date, inSameDayAs: hd) }
                        let total = daySubs.reduce(0) { $0 + $1.cost } + dayBal.reduce(0) { $0 + $1.cost }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hd, format: .dateTime.month(.abbreviated).day()).font(.caption).fontWeight(.semibold)
                            Text("$\(String(format: "%.2f", total))").font(.caption2).monospacedDigit()
                            ForEach(dayBal) { item in
                                Text("  \(item.label): $\(String(format: "%.2f", item.cost))").font(.caption2).monospacedDigit()
                            }
                            ForEach(daySubs) { item in
                                Text("  \(item.label): $\(String(format: "%.2f", item.cost))").font(.caption2).monospacedDigit()
                            }
                        }
                        .padding(6).background(.regularMaterial).cornerRadius(6)
                        .offset(x: min(max(costHoverX - 40, 0), 560), y: 0)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .quaternarySystemFill).opacity(0.3))
        .cornerRadius(10)
    }

    // MARK: Cost chart data helpers

    struct ChartDataPoint: Identifiable {
        var id: String { "\(label)-\(Int(date.timeIntervalSince1970))" }
        let date: Date
        let label: String
        let cost: Double
    }

    func subDailyData() -> [ChartDataPoint] {
        guard !subSources.isEmpty else { return [] }
        let daysInMonth = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = chartStart

        var result = [ChartDataPoint]()
        for offset in 0..<chartDays {
            guard let date = cal.date(byAdding: .day, value: offset, to: start) else { continue }
            if date <= today {
                for cs in subSources {
                    if case .subscription(_, _, let fee) = cs.kind, fee > 0 {
                        result.append(ChartDataPoint(date: date, label: cs.label, cost: fee / daysInMonth))
                    }
                }
            } else {
                result.append(ChartDataPoint(date: date, label: subSources.first!.label, cost: 0))
            }
        }
        return result
    }

    func apiDailyData() -> [ChartDataPoint] {
        providerCosts.map { pc in
            let name = IntegrationRegistry.all.first(where: { $0.id == pc.providerId })?.displayName ?? pc.providerId
            return ChartDataPoint(date: pc.date, label: name, cost: pc.cost)
        }
    }

    func costTooltip(for date: Date) -> some View {
        let cal = Calendar.current
        let subs = subDaily.filter { cal.isDate($0.date, inSameDayAs: date) }
        let bal = balanceDaily.filter { cal.isDate($0.date, inSameDayAs: date) }
        let totalCost = subs.reduce(0) { $0 + $1.cost } + bal.reduce(0) { $0 + $1.cost }

        return VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.month(.abbreviated).day()).font(.caption).fontWeight(.semibold)
            Text("$\(String(format: "%.2f", totalCost))").font(.caption2).monospacedDigit()
            ForEach(bal) { item in
                Text("  \(item.label): $\(String(format: "%.2f", item.cost))").font(.caption2).monospacedDigit()
            }
            ForEach(subs) { item in
                Text("  \(item.label): $\(String(format: "%.2f", item.cost))").font(.caption2).monospacedDigit()
            }
        }
        .padding(6).background(.regularMaterial).cornerRadius(6)
    }

    // MARK: - Code change chart (added + deleted stacked positive bars)

    var codeChangeChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(I18n.t("dashboard.code_chart")).font(.headline)

            if codeChanges.allSatisfy({ $0.added == 0 && $0.deleted == 0 }) {
                Text(I18n.t("menu.no_usage")).foregroundColor(.secondary).padding(.vertical, 30)
            } else {
                ZStack(alignment: .topLeading) {
                    Chart {
                        ForEach(codeChangeSegments, id: \.id) { seg in
                            BarMark(
                                x: .value("Date", seg.date, unit: .day),
                                y: .value("Lines", seg.lines)
                            )
                            .foregroundStyle(by: .value("Type", seg.type))
                        }
                        if let hd = codeHoverDate {
                            RuleMark(x: .value("Date", hd, unit: .day))
                                .foregroundStyle(.gray.opacity(0.3))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: dateStride) { _ in
                            AxisValueLabel(format: dateLabelFormat, orientation: .horizontal)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine()
                            AxisValueLabel()
                        }
                    }
                    .chartYAxisLabel(I18n.t("menu.lines"))
                    .chartForegroundStyleScale([
                        I18n.t("dashboard.added"): Color.green.opacity(0.7),
                        I18n.t("dashboard.deleted"): Color.orange.opacity(0.7)
                    ])
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Color.clear
                                .onContinuousHover { phase in
                                    if case .active(let loc) = phase,
                                       let frame = proxy.plotFrame {
                                        let originX = geo[frame].origin.x
                                        let plotW = geo[frame].width
                                        let x = loc.x - originX
                                        guard x >= 0, x <= plotW else { codeHoverDate = nil; return }
                                        codeHoverX = x
                                        codeHoverDate = proxy.value(atX: x)
                                    } else { codeHoverDate = nil }
                                }
                        }
                    }
                    .frame(height: 200)

                    if let hd = codeHoverDate,
                       let pt = paddedChanges.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hd) }),
                       pt.added > 0 || pt.deleted > 0 {
                        codeTooltip(date: hd, added: pt.added, deleted: pt.deleted)
                            .offset(x: min(max(codeHoverX - 40, 0), 560), y: 0)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .quaternarySystemFill).opacity(0.3))
        .cornerRadius(10)
    }

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

    func padCodeChanges() -> [DailyCodeChange] {
        let cal = Calendar.current
        let start = chartStart
        var map = [Date: DailyCodeChange]()
        for c in codeChanges { map[cal.startOfDay(for: c.date)] = c }

        var result = [DailyCodeChange]()
        for offset in 0..<chartDays {
            guard let date = cal.date(byAdding: .day, value: offset, to: start) else { continue }
            if let c = map[date] {
                result.append(c)
            } else {
                result.append(DailyCodeChange(date: date, added: 0, deleted: 0))
            }
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

    var bottomCards: some View {
        HStack(alignment: .top, spacing: 16) {
            apiBreakdownCard
            if hasActiveCostSources {
                cplInfoCard
            } else {
                cplGuidanceCard
            }
        }
    }

    // MARK: - Spend overview

    var spendingOverview: some View {
        _ = costSourceBreakdown
        let apiSpend = balanceSpend.reduce(0.0) { $0 + $1.spend }
        let subDaily = StatsService.subscriptionDailyAmortization()
        let subTotal = subDaily * Double(timeRange.days)
        let totalCost = timeRange == .today ? todayCombinedSpend : apiSpend + subTotal

        let apiData = apiDonutData()
        let subVsApi = subVsApiDonutData(api: apiSpend, sub: subTotal)

        return VStack(spacing: 16) {
            // Big total
            VStack(spacing: 4) {
                Text("$\(String(format: "%.2f", totalCost))")
                    .font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.deepRed)
                    .scaleEffect(loadedTimeRange == timeRange ? (0.8 + 0.2 * barProgress) : 0.8)
                    .animation(.spring(response: 0.5, dampingFraction: 0.6), value: barProgress)
                HStack(spacing: 6) {
                    Text("\(timeRange.label)\(I18n.t("dashboard.api_spent"))")
                        .font(.caption).foregroundColor(.secondary)
                    // Day-over-day badge (today only)
                    if timeRange == .today, yesterdaySpend > 0.001 {
                        comparisonBadge(current: totalCost, previous: yesterdaySpend, upLabel: I18n.t("dashboard.vs_yesterday"), downLabel: I18n.t("dashboard.vs_yesterday"), flatLabel: I18n.t("dashboard.vs_yesterday_flat"))
                    }
                    // Period-over-period badge (30-day only)
                    if timeRange == .days30, previousPeriodSpend > 0.001 {
                        comparisonBadge(current: totalCost, previous: previousPeriodSpend, upLabel: I18n.t("dashboard.vs_period"), downLabel: I18n.t("dashboard.vs_period"), flatLabel: I18n.t("dashboard.vs_period_flat"))
                    }
                }
                // Monthly projection — all time ranges
                if let p = prediction, p.monthProjected > 0.001 {
                    Text(String(format: I18n.t("dashboard.month_projection"), String(format: "%.2f", p.monthSoFar), String(format: "%.2f", p.monthProjected), p.daysRemaining))
                        .font(.caption2).foregroundColor(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 3)

            // Donuts flanking stat cards: left donut | nose stats | right donut
            HStack(alignment: .top, spacing: 12) {
                // Left: subscription vs API donut
                if subVsApi.total > 0.001 {
                    subVsApiDonut(data: subVsApi)
                }

                // Center: stat cards as "nose" (vertical stack, limited width)
                VStack(spacing: 6) {
                    noseStatCards
                }
                .frame(width: 100)

                // Right: API provider donut
                if !apiData.isEmpty {
                    apiProviderDonut(data: apiData, apiSpend: apiSpend)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
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
        let apiSpend = balanceSpend.reduce(0.0) { $0 + $1.spend }
        let subDaily = StatsService.subscriptionDailyAmortization()
        let subTotal = subDaily * Double(timeRange.days)
        let totalCost = timeRange == .today ? todayCombinedSpend : apiSpend + subTotal
        let toolCosts = computeToolCosts()
        let dataReady = loadedTimeRange == timeRange

        return VStack(spacing: 12) {
            // ── Tool bars ("mouth") ──
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n.t("dashboard.by_tool")).font(.caption).foregroundColor(.secondary)
                if toolCosts.isEmpty {
                    Text("--").font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(Array(toolCosts.prefix(6).enumerated()), id: \.element.name) { idx, tc in
                        toolBarRow(name: tc.name, cost: tc.cost, total: totalCost, index: idx)
                    }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            // ── Mouth line — short horizontal connector ──
            HStack(spacing: 0) {
                Spacer()
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.marsGreen.opacity(0.2))
                    .frame(width: 60, height: 3)
                Spacer()
            }

            // ── Repo list with cost + CPL ("chin/beard") ──
            let cplRepos = repos.filter { $0.totalChanges > 0 }
            if !cplRepos.isEmpty {
                let logTotal = cplRepos.map(\.cost).reduce(0, +)
                let scale = logTotal > 0 ? apiSpend / logTotal : 1.0
                let reposWithSub = cplRepos.map { r -> (RepoBreakdown, Double) in
                    let repoAPI = r.cost * scale
                    let subPortion = logTotal > 0 ? subTotal * r.cost / logTotal : 0
                    return (r, repoAPI + subPortion)
                }
                let maxCost = reposWithSub.map(\.1).max() ?? 1
                let maxCPL = cplRepos.compactMap { r in r.totalChanges > 0 ? r.cost * 1000 / Double(r.totalChanges) : nil }.max() ?? 1
                VStack(alignment: .leading, spacing: 6) {
                    Text(I18n.t("dashboard.by_repo")).font(.caption).foregroundColor(.secondary)
                    ForEach(Array(reposWithSub.prefix(8).enumerated()), id: \.element.0.id) { idx, item in
                        let (r, totalCost) = item
                        let combinedCPL = r.totalChanges > 0 ? r.cost * 1000 / Double(r.totalChanges) : 0
                        let costRatio = maxCost > 0 ? totalCost / maxCost : 0
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
                                Text("$\(String(format: "%.2f", totalCost))")
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
                        if r.id != cplRepos.prefix(8).last?.id {
                            Divider()
                        }
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
        let padded = padCodeChanges()
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

    var trendSection: some View {
        let padStats = padStats(dailyStats, days: timeRange.days)
        let padCode = padCodeChanges()
        let noData = padStats.allSatisfy({ $0.cost == 0 }) && padCode.allSatisfy({ $0.added == 0 })
        let scale = trendCodeAxis.scale
        let leftMax = trendSpendAxis.max
        let leftValues = trendSpendAxis.values
        let rightVals = trendCodeAxis.values
        let rightMax = trendCodeAxis.max
        let dataReady = loadedTimeRange == timeRange
        let prog = Double(dataReady ? barProgress : 0)

        return VStack(spacing: 12) {
            Text(I18n.t("dashboard.daily_trend")).font(.headline)

            if noData {
                Text(I18n.t("menu.no_usage")).foregroundColor(.secondary).padding(.vertical, 20)
            } else {
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
                        Text(I18n.t("dashboard.api_spend_label")).font(.caption2).foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.marsGreenLight).frame(width: 10, height: 10)
                        Text(I18n.t("dashboard.sub_label")).font(.caption2).foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.deepRed2).frame(width: 10, height: 10)
                        Text(I18n.t("dashboard.added_lines")).font(.caption2).foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.deepRed).frame(width: 10, height: 10)
                        Text(I18n.t("dashboard.deleted_lines")).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
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
            Text("AI Pulse").font(.headline)
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
        .dateTime.month(.abbreviated).day().locale(Locale(identifier: I18n.getLang() == "zh" ? "zh_CN" : "en_US"))
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
            var monCal = cal; monCal.firstWeekday = 2
            return monCal.date(from: monCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
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

    func avgCPL() -> String {
        let tc = dailyStats.reduce(0) { $0 + $1.cost }
        let tl = dailyStats.reduce(0) { $0 + $1.netLines }
        guard tl > 0, tc > 0 else { return "--" }
        return "$\(String(format: "%.2f", tc * 1000 / Double(tl)))"
    }

    func totalLines() -> String {
        "\(dailyStats.reduce(0) { $0 + $1.netLines })"
    }

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

    /// Generalized comparison badge. Shows percentage change with arrow and configurable labels.
    @ViewBuilder
    func comparisonBadge(current: Double, previous: Double, upLabel: String, downLabel: String, flatLabel: String) -> some View {
        let pct = (current - previous) / previous * 100
        if abs(pct) < 1 {
            Text(flatLabel)
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color(nsColor: .quaternarySystemFill))
                .cornerRadius(4)
        } else if pct > 0 {
            Text("\(upLabel) ↑\(Int(round(pct)))%")
                .font(.caption2).foregroundColor(.deepRed)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.deepRed.opacity(0.1))
                .cornerRadius(4)
        } else {
            Text("\(downLabel) ↓\(Int(round(-pct)))%")
                .font(.caption2).foregroundColor(.marsGreen)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.marsGreen.opacity(0.1))
                .cornerRadius(4)
        }
    }

    // MARK: - Donut charts

    /// Data for subscription-vs-API donut chart.
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
                    .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
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
                        Text("\(Int(item.pct))%").font(.caption2).monospacedDigit().foregroundColor(.secondary)
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
                    .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
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
                        Text("\(Int(item.pct))%").font(.caption2).monospacedDigit().foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 140)
        .animation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.2), value: barProgress)
    }

    func load() async {
        // ── Synchronous prep ──
        let currentTimeRange = timeRange  // capture before async closures for sendability
        let newEditorMappings = EditorDetector.certainMappings()
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayStartMs = Int64(todayStart.timeIntervalSince1970 * 1000)
        let rangeStartMs = Int64(chartStart.timeIntervalSince1970 * 1000)

        // ── Phase 1a: fire all independent async queries in parallel ──
        async let rawDailyStats       = StatsService.dailyStats(days: currentTimeRange.days)
        async let rawProviderCosts    = StatsService.providerDailyCosts(days: currentTimeRange.days)
        async let rawCodeChanges      = StatsService.dailyCodeChanges(days: currentTimeRange.days)
        async let rawRepos            = StatsService.repoBreakdown(days: currentTimeRange.days, editorMappings: newEditorMappings)
        async let rawPrediction       = StatsService.prediction()
        async let rawSpend            = StatsService.balanceDailySpend(days: currentTimeRange.days, sinceMs: rangeStartMs)
        async let rawTodayCombined    = StatsService.combinedSpend(sinceMs: todayStartMs)

        // Conditional combined-spend queries (return 0 when not applicable).
        // Compare timeRange outside async closures to avoid Sendable warnings.
        let isToday = currentTimeRange == .today
        let isDays30 = currentTimeRange == .days30

        async let rawYesterdaySpend: Double = {
            guard isToday else { return 0 }
            if let y = cal.date(byAdding: .day, value: -1, to: todayStart) {
                return await StatsService.combinedSpend(sinceMs: Int64(y.timeIntervalSince1970 * 1000))
            }
            return 0
        }()

        async let rawPreviousPeriodSpend: Double = {
            guard isDays30 else { return 0 }
            if let curr = cal.date(byAdding: .day, value: -29, to: todayStart),
               let prev = cal.date(byAdding: .day, value: -59, to: todayStart) {
                let prev60 = await StatsService.combinedSpend(sinceMs: Int64(prev.timeIntervalSince1970 * 1000))
                let curr30 = await StatsService.combinedSpend(sinceMs: Int64(curr.timeIntervalSince1970 * 1000))
                return prev60 - curr30
            }
            return 0
        }()

        // ── Phase 1b: await all parallel results ──
        let newLoadError: String?
        let newDailyStats: [DailyStat]
        do {
            newDailyStats = padStats(try await rawDailyStats, days: timeRange.days)
            newLoadError = nil
        } catch { newLoadError = error.localizedDescription; newDailyStats = [] }

        let newProviderCosts        = (try? await rawProviderCosts) ?? []
        let newCodeChanges          = (try? await rawCodeChanges) ?? []
        let newRepos                = (try? await rawRepos) ?? []
        let newPrediction           = await rawPrediction
        let newTodayCombinedSpend   = await rawTodayCombined
        let newYesterdaySpend       = await rawYesterdaySpend
        let newPreviousPeriodSpend  = await rawPreviousPeriodSpend

        // Derived chart data (sync, depends on above)
        let newPaddedChanges = Self.padChanges(newCodeChanges, chartStart: chartStart, chartDays: chartDays)
        let newSubDaily = subDailyData()
        let newApiDaily = apiDailyData()

        // Balance spend aggregation (sync processing of rawSpend)
        let rawSpendResolved = (try? await rawSpend) ?? []
        var dbs = [Date: Double]()
        for s in rawSpendResolved { dbs[s.date, default: 0] += s.spend }
        let newDailyBalanceSpend = dbs

        var spendMap: [(String, Double)] = []
        for s in rawSpendResolved {
            if let idx = spendMap.firstIndex(where: { $0.0 == s.providerId }) {
                spendMap[idx].1 += s.spend
            } else {
                spendMap.append((s.providerId, s.spend))
            }
        }
        let enabledB = Set(IntegrationRegistry.balanceTrackedCostSources().compactMap { cs in
            if case .apiKey(let pid) = cs.kind { return pid }; return nil
        })
        let newBalanceSpend = spendMap.compactMap { (pid, spend) -> (String, String, Double)? in
            guard enabledB.contains(pid), spend > 0.001 else { return nil }
            let name = IntegrationRegistry.all.first(where: { $0.id == pid })?.displayName ?? pid
            return (pid, name, spend)
        }.sorted(by: { $0.2 > $1.2 })

        var dailyAgg: [String: (date: Date, label: String, cost: Double)] = [:]
        for s in rawSpendResolved {
            guard let name = IntegrationRegistry.all.first(where: { $0.id == s.providerId })?.displayName else { continue }
            let key = "\(Int(s.date.timeIntervalSince1970))-\(name)"
            if let existing = dailyAgg[key] {
                dailyAgg[key] = (s.date, name, existing.cost + s.spend)
            } else {
                dailyAgg[key] = (s.date, name, s.spend)
            }
        }
        let newBalanceDaily = dailyAgg.values.map { ChartDataPoint(date: $0.date, label: $0.label, cost: $0.cost) }

        // Today-specific metrics (sync, depends on newDailyStats)
        let newTodayCalls: Int, newTodayTokens: Int
        if timeRange == .today, let today = newDailyStats.first {
            newTodayCalls = today.calls; newTodayTokens = today.tokens
        } else { newTodayCalls = 0; newTodayTokens = 0 }

        // ── Phase 1c: tool cost & usage queries (depend on balance data) ──
        let toolStartMs = Int64(chartStart.timeIntervalSince1970 * 1000)
        async let rawToolData: [(String, Double)] = AppDatabase.shared.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT source AS s, COALESCE(SUM(cost_usd),0) AS c FROM usage_event WHERE ts >= ? GROUP BY s", arguments: [toolStartMs])
            return rows.compactMap { r in
                guard let s: String = r["s"], let c: Double = r["c"], c > 0 else { return nil }
                return (s, c)
            }
        }

        async let rawUsageData: [String: (Double, String)] = AppDatabase.shared.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, usage_percent, usage_limit_status FROM cost_source WHERE usage_percent IS NOT NULL")
            var map: [String: (Double, String)] = [:]
            for r in rows {
                if let id: String = r["id"], let pct: Double = r["usage_percent"] {
                    map[id] = (pct, r["usage_limit_status"] ?? "")
                }
            }
            return map
        }

        // ── Phase 1d: process tool data ──
        let newToolCostBreakdown: [(name: String, cost: Double)]
        do {
            let toolData = try await rawToolData
            let toolAPITotal = toolData.reduce(0.0) { $0 + $1.1 }
            let apiSpend = newBalanceSpend.reduce(0.0) { $0 + $1.2 }
            let subTotal = StatsService.subscriptionDailyAmortization() * Double(timeRange.days)
            let displayTotal = timeRange == .today ? newTodayCombinedSpend : (apiSpend + subTotal)
            let toolScale = toolAPITotal > 0 ? displayTotal / toolAPITotal : 1.0

            var tmap: [String: Double] = [:]
            for (s, c) in toolData { tmap[s] = c * toolScale }
            newToolCostBreakdown = tmap.compactMap { (key, cost) -> (String, Double)? in
                guard cost > 0.001 else { return nil }
                let label: String = switch key {
                case "claude-code": "Claude Code"
                case "aider": "aider"
                case "cursor": "Cursor"
                case "copilot": "Copilot"
                case "windsurf": "Windsurf"
                default: key
                }
                return (label, cost)
            }.sorted(by: { $0.1 > $1.1 }).map { (name: $0.0, cost: $0.1) }
        } catch { newToolCostBreakdown = [] }

        let newUsageData = (try? await rawUsageData) ?? [:]

        // ── Apply ALL state changes atomically ──
        loadError = newLoadError
        dailyStats = newDailyStats
        providerCosts = newProviderCosts
        codeChanges = newCodeChanges
        editorMappings = newEditorMappings
        repos = newRepos
        prediction = newPrediction
        paddedChanges = newPaddedChanges
        subDaily = newSubDaily
        apiDaily = newApiDaily
        dailyBalanceSpend = newDailyBalanceSpend
        balanceSpend = newBalanceSpend
        balanceDaily = newBalanceDaily
        todayCombinedSpend = newTodayCombinedSpend
        todayCalls = newTodayCalls
        todayTokens = newTodayTokens
        yesterdaySpend = newYesterdaySpend
        previousPeriodSpend = newPreviousPeriodSpend
        toolCostBreakdown = newToolCostBreakdown
        usageData = newUsageData
        loadedTimeRange = timeRange  // mark data as matching current tab
        balanceErrors = AppHealthMonitor.shared.failingProviders

        // ── Trigger entry animations (only when bars were reset by tab switch) ──
        if barProgress < 0.5 {
            barProgress = 0
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.65, dampingFraction: 0.7)) {
                    self.barProgress = 1
                }
            }
        }
    }

}
