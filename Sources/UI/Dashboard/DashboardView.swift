import SwiftUI
import Charts
import GRDB

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
    @State private var dailyStats: [DailyStat] = []
    @State private var providerCosts: [ProviderDailyCost] = []
    @State private var codeChanges: [DailyCodeChange] = []
    @State private var paddedChanges: [DailyCodeChange] = []
    @State private var repos: [RepoBreakdown] = []
    @State private var prediction: Prediction?
    @State private var timeRange = TimeRange.thisWeek
    @State private var costHoverDate: Date? = nil
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

    var hasActiveCostSources: Bool {
        !IntegrationRegistry.activeCostSources(editorMappings: editorMappings).isEmpty
    }

    var hasCertainEditorMapping: Bool {
        editorMappings.contains { $0.confidence == .certain && $0.dailySubscriptionCost > 0 }
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
                VStack(spacing: 16) {
                    costSourceSummary.padding(.horizontal, 20)

                    if hasActiveCostSources || !providerCosts.isEmpty {
                        if timeRange != .today {
                            costChart.padding(.horizontal, 20)
                            codeChangeChart.padding(.horizontal, 20)
                        }

                        // Bottom cards row
                        bottomCards.padding(.horizontal, 20)
                    } else {
                        emptyStateCard.padding(.horizontal, 20)
                    }
                }.padding(.bottom, 20)
            }
        }
        .frame(width: 680, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            ApiPoller.shared.pollAll()
            await load()
        }
        .onChange(of: timeRange) { _, _ in Task { await load() } }
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
        var result: [(source: CostSource, cost: Double, usagePercent: Double?)] = []
        for cs in sources {
            let cost: Double
            switch cs.kind {
            case .apiKey(let pid):
                // Sum balance spend for this provider
                cost = balanceSpend
                    .filter { $0.providerId == pid }
                    .reduce(0) { $0 + $1.spend }
            case .subscription(_, _, let fee):
                let days = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
                cost = fee / days * Double(timeRange.days)
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
                          value: "+\(added)", color: .green)
                smallCard(title: "\(timeRange.label)\(I18n.t("dashboard.code_deleted"))",
                          value: "-\(deleted)", color: .orange)
            }
        }
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
        case 0..<75:  .green
        case 75..<90: .yellow
        default:      .orange
        }
        let label = clamped > 100 ? "超量" : "\(Int(clamped))%"
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
        .help(clamped > 90 ? "用量接近上限，可能产生超额费用" : "当月用量百分比")
    }

    func confidenceBadge(_ c: CostConfidence) -> some View {
        let (label, color): (String, Color) = switch c {
        case .exact:       ("", .green)
        case .estimated:   ("~", .blue)
        case .amortized:   ("", .orange)
        case .uncertain:   ("?", .yellow)
        case .incomplete:  ("…", .red)
        }
        return Text(label)
            .font(.caption2).fontWeight(.bold).foregroundColor(color)
            .frame(width: 16)
    }

    func confidenceColor(_ c: CostConfidence) -> Color {
        switch c {
        case .exact:       return .primary
        case .estimated:   return .secondary
        case .amortized:   return .secondary
        case .uncertain:   return .secondary
        case .incomplete:  return .secondary
        }
    }

    func smallCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline).fontWeight(.semibold).monospacedDigit()
                .foregroundColor(color)
            Text(title).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
        .background(Color(nsColor: .quaternarySystemFill)).cornerRadius(8)
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

    // MARK: - Empty state (no integrations)

    var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "fuelpump").font(.system(size: 32)).foregroundColor(.secondary)
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
        .dateTime.month(.abbreviated).day()
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

    func load() async {
        loadError = nil
        do {
            let raw = try await StatsService.dailyStats(days: timeRange.days)
            dailyStats = padStats(raw, days: timeRange.days)
        } catch { loadError = error.localizedDescription; dailyStats = [] }

        providerCosts = (try? await StatsService.providerDailyCosts(days: timeRange.days)) ?? []
        codeChanges = (try? await StatsService.dailyCodeChanges(days: timeRange.days)) ?? []
        editorMappings = EditorDetector.certainMappings()
        repos = (try? await StatsService.repoBreakdown(days: timeRange.days, editorMappings: editorMappings)) ?? []
        prediction = await StatsService.prediction()
        paddedChanges = padCodeChanges()
        subDaily = subDailyData()
        apiDaily = apiDailyData()
        let rawSpend = (try? await StatsService.balanceDailySpend(days: timeRange.days)) ?? []
        // Aggregate spend by provider for summary cards
        var spendMap: [(String, Double)] = []
        for s in rawSpend {
            if let idx = spendMap.firstIndex(where: { $0.0 == s.providerId }) {
                spendMap[idx].1 += s.spend
            } else {
                spendMap.append((s.providerId, s.spend))
            }
        }
        let enabledB = Set(IntegrationRegistry.balanceTrackedCostSources().compactMap { cs in
            if case .apiKey(let pid) = cs.kind { return pid }; return nil
        })
        balanceSpend = spendMap.compactMap { (pid, spend) in
            guard enabledB.contains(pid), spend > 0.001 else { return nil }
            let name = IntegrationRegistry.all.first(where: { $0.id == pid })?.displayName ?? pid
            return (pid, name, spend)
        }.sorted(by: { $0.spend > $1.spend })
        // Aggregate balance spend by (date, provider) for chart bars
        var dailyAgg: [String: (date: Date, label: String, cost: Double)] = [:]
        for s in rawSpend {
            guard let name = IntegrationRegistry.all.first(where: { $0.id == s.providerId })?.displayName else { continue }
            let key = "\(Int(s.date.timeIntervalSince1970))-\(name)"
            if let existing = dailyAgg[key] {
                dailyAgg[key] = (s.date, name, existing.cost + s.spend)
            } else {
                dailyAgg[key] = (s.date, name, s.spend)
            }
        }
        balanceDaily = dailyAgg.values.map { ChartDataPoint(date: $0.date, label: $0.label, cost: $0.cost) }

        // Load usage data for subscription CostSources
        do {
            let rows = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT id, usage_percent, usage_limit_status FROM cost_source WHERE usage_percent IS NOT NULL")
            }
            var map: [String: (Double, String)] = [:]
            for r in rows {
                if let id: String = r["id"],
                   let pct: Double = r["usage_percent"] {
                    let status: String = r["usage_limit_status"] ?? ""
                    map[id] = (pct, status)
                }
            }
            usageData = map
        } catch {
            // Usage data is optional; ignore failures
        }
    }

}
