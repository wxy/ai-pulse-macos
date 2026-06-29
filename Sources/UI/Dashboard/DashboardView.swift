import SwiftUI
import Charts

struct DashboardView: View {
    @State private var dailyStats: [DailyStat] = []
    @State private var providerCosts: [ProviderDailyCost] = []
    @State private var codeChanges: [DailyCodeChange] = []
    @State private var paddedChanges: [DailyCodeChange] = []
    @State private var models: [ModelBreakdown] = []
    @State private var repos: [RepoBreakdown] = []
    @State private var prediction: Prediction?
    @State private var dayRange = 7
    @State private var costHoverDate: Date? = nil
    @State private var codeHoverDate: Date? = nil
    @State private var costHoverX: CGFloat = 0
    @State private var codeHoverX: CGFloat = 0
    @State private var subDaily: [ChartDataPoint] = []
    @State private var apiDaily: [ChartDataPoint] = []

    var hasAGrade: Bool {
        IntegrationRegistry.enabledAGrade().contains { $0.detect().found }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(I18n.t("dashboard.title")).font(.title2).fontWeight(.bold)
                Spacer()
                Picker("", selection: $dayRange) {
                    Text(I18n.t("dashboard.days_7")).tag(7)
                    Text(I18n.t("dashboard.days_30")).tag(30)
                }.pickerStyle(.segmented).frame(width: 140)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 16) {
                    summaryCards.padding(.horizontal, 20)

                    if hasAGrade || !providerCosts.isEmpty {
                        costChart.padding(.horizontal, 20)
                        codeChangeChart.padding(.horizontal, 20)

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
        .task { await load() }
        .onChange(of: dayRange) { _, _ in Task { await load() } }
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

    /// Per-provider API accumulated cost from daily stats (not balance API)
    var apiBreakdownCard: some View {
        let grouped = Dictionary(grouping: providerCosts, by: { $0.providerId })
            .mapValues { $0.reduce(0.0) { $0 + $1.cost } }
            .sorted(by: { $0.value > $1.value })
        guard !grouped.isEmpty else { return AnyView(EmptyView()) }
        let total = grouped.reduce(0.0) { $0 + $1.value }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text(I18n.t("dashboard.api_total_title")).font(.headline)
                HStack {
                    Text(I18n.t("dashboard.total")).font(.body)
                    Spacer()
                    Text("$\(String(format: "%.2f", total))").font(.callout).monospacedDigit().fontWeight(.semibold)
                }
                Divider()
                ForEach(grouped, id: \.key) { providerId, cost in
                    let name = IntegrationRegistry.all.first(where: { $0.id == providerId })?.displayName ?? providerId
                    HStack {
                        Text(name).font(.caption)
                        Spacer()
                        Text("$\(String(format: "%.2f", cost))").font(.caption).monospacedDigit()
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

    // MARK: - Summary cards (3×2 grid)

    var summaryCards: some View {
        let apiSpent = dailyStats.reduce(0.0) { $0 + $1.cost }
        let added = dailyStats.reduce(0) { $0 + max(0, $1.netLines) }
        let deleted = dailyStats.reduce(0) { $0 + max(0, -$1.netLines) }
        let periodLabel = dayRange <= 7
            ? I18n.t("menu.this_week")
            : I18n.t("dashboard.this_month")
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                card(title: "\(periodLabel)\(I18n.t("dashboard.api_spent"))",
                     value: "$\(String(format: "%.2f", apiSpent))")
                card(title: I18n.t("dashboard.sub_daily"),
                     value: "$\(String(format: "%.2f", totalSubDaily()))")
                card(title: "\(periodLabel)\(I18n.t("dashboard.code_added"))",
                     value: "+\(added)")
            }
            HStack(spacing: 8) {
                card(title: "\(periodLabel)\(I18n.t("dashboard.api_projected"))",
                     value: prediction.map { "$\(String(format: "%.2f", $0.monthProjected))" } ?? "--")
                card(title: I18n.t("dashboard.sub_monthly_label"),
                     value: "$\(String(format: "%.2f", totalSubMonthly()))")
                card(title: "\(periodLabel)\(I18n.t("dashboard.code_deleted"))",
                     value: "-\(deleted)")
            }
        }
    }

    func card(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.subheadline).fontWeight(.semibold).monospacedDigit()
            Text(title).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(Color(nsColor: .quaternarySystemFill)).cornerRadius(8)
    }

    func apiDailyAvg() -> Double {
        let total = dailyStats.reduce(0.0) { $0 + $1.cost }
        let days = max(dailyStats.filter { $0.cost > 0.001 }.count, 1)
        return total / Double(days)
    }

    func totalSubMonthly() -> Double {
        let subs = IntegrationRegistry.enabledCGrade()
        return subs.reduce(0.0) { sum, s in sum + estimatedDailySub(s.id) * 30 }
    }

    func totalSubDaily() -> Double {
        let subs = IntegrationRegistry.enabledCGrade()
        let days = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
        var total: Double = 0
        for s in subs {
            let cfg = IntegrationRegistry.config(for: s.id)
            guard !cfg.subscriptionTier.isEmpty else { continue }
            if let tool = SubscriptionRegistry.tool(forName: toolName(for: s.id)),
               let tier = tool.tiers.first(where: { $0.label == cfg.subscriptionTier }) {
                total += tier.fee / days
            }
        }
        return total
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

            if providerCosts.isEmpty && IntegrationRegistry.enabledCGrade().isEmpty {
                Text(I18n.t("menu.no_usage")).foregroundColor(.secondary).padding(.vertical, 30)
            } else {
                ZStack(alignment: .topLeading) {
                    Chart {
                        // Single ForEach with sub first (bottom) + api second (top) for auto-stacking
                        ForEach(subDaily + apiDaily, id: \.id) { item in
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
                            Color.clear
                                .onContinuousHover { phase in
                                    if case .active(let loc) = phase,
                                       let frame = proxy.plotFrame {
                                        let originX = geo[frame].origin.x
                                        let plotW = geo[frame].width
                                        let x = loc.x - originX
                                        guard x >= 0, x <= plotW else { costHoverDate = nil; return }
                                        costHoverX = x
                                        costHoverDate = proxy.value(atX: x)
                                    } else { costHoverDate = nil }
                                }
                        }
                    }
                    .frame(height: 200)

                    if let hd = costHoverDate {
                        costTooltip(for: hd)
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
        let subs = IntegrationRegistry.enabledCGrade()
        guard !subs.isEmpty else { return [] }
        let days = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        var result = [ChartDataPoint]()
        for offset in 0..<dayRange {
            guard let date = cal.date(byAdding: .day, value: -(dayRange - 1 - offset), to: today) else { continue }
            for s in subs {
                let cfg = IntegrationRegistry.config(for: s.id)
                guard !cfg.subscriptionTier.isEmpty else { continue }
                if let tool = SubscriptionRegistry.tool(forName: toolName(for: s.id)),
                   let tier = tool.tiers.first(where: { $0.label == cfg.subscriptionTier }) {
                    result.append(ChartDataPoint(date: date, label: s.displayName, cost: tier.fee / days))
                }
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
        let apis = apiDaily.filter { cal.isDate($0.date, inSameDayAs: date) }
        let totalCost = subs.reduce(0) { $0 + $1.cost } + apis.reduce(0) { $0 + $1.cost }

        return VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.month(.abbreviated).day()).font(.caption).fontWeight(.semibold)
            Text("$\(String(format: "%.2f", totalCost))").font(.caption2).monospacedDigit()
            ForEach(apis) { item in
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
        let today = cal.startOfDay(for: Date())
        var map = [Date: DailyCodeChange]()
        for c in codeChanges { map[cal.startOfDay(for: c.date)] = c }

        var result = [DailyCodeChange]()
        for offset in 0..<dayRange {
            guard let date = cal.date(byAdding: .day, value: -(dayRange - 1 - offset), to: today) else { continue }
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
        let cplRepos = repos.filter { $0.netLines > 0 && $0.cost > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            Text(I18n.t("dashboard.cpl_card")).font(.headline)
            if cplRepos.isEmpty {
                Text(I18n.t("dashboard.no_cpl_data"))
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(cplRepos.prefix(5)) { r in
                    HStack {
                        Text(r.repo).font(.caption).lineLimit(1)
                        Spacer()
                        Text("$\(String(format: "%.2f", r.costPerLine))\(I18n.t("menu.per_line"))")
                            .font(.caption).monospacedDigit()
                    }
                }
            }
            Text("ℹ️ \(I18n.t("dashboard.cpl_disclaimer"))")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .quaternarySystemFill).opacity(0.3))
        .cornerRadius(10)
    }

    // MARK: - Bottom cards row

    var bottomCards: some View {
        HStack(alignment: .top, spacing: 16) {
            apiBreakdownCard
            if hasAGrade {
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

    // MARK: - Model breakdown

    var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18n.t("menu.by_model")).font(.headline)
            if models.isEmpty {
                Text(I18n.t("menu.no_usage")).font(.caption).foregroundColor(.secondary)
            } else {
                Chart(models) { m in
                    BarMark(x: .value("Cost", m.cost), y: .value("Model", m.model))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                }
                .chartXAxisLabel(I18n.t("dashboard.cost_usd")).frame(height: 160)
                VStack(spacing: 4) {
                    ForEach(models.prefix(5)) { m in
                        HStack {
                            Text(m.model).font(.caption).lineLimit(1)
                            Spacer()
                            Text("$\(String(format: "%.2f", m.cost)) · \(m.calls) \(I18n.t("menu.calls"))")
                                .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity)
    }

    // MARK: - Repo breakdown

    var repoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18n.t("menu.by_repo")).font(.headline)
            if repos.isEmpty {
                Text(I18n.t("menu.no_usage")).font(.caption).foregroundColor(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        Text(I18n.t("dashboard.col_repo")).font(.caption2).foregroundColor(.secondary)
                        Text(I18n.t("dashboard.cost_usd")).font(.caption2).foregroundColor(.secondary)
                        Text(I18n.t("menu.lines")).font(.caption2).foregroundColor(.secondary)
                        Text(I18n.t("dashboard.col_cpl")).font(.caption2).foregroundColor(.secondary)
                    }
                    Divider()
                    ForEach(repos.prefix(8)) { r in
                        GridRow {
                            Text(r.repo).font(.caption).lineLimit(1)
                            Text("$\(String(format: "%.2f", r.cost))").font(.caption2).monospacedDigit()
                            Text("\(r.netLines)").font(.caption2).monospacedDigit()
                            let cpl = r.netLines > 0 ? r.costPerLine : 0
                            Text("$\(String(format: "%.2f", cpl))\(I18n.t("menu.per_line"))")
                                .font(.caption2).monospacedDigit()
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity)
    }

    // MARK: - Date formatting

    var dateStride: AxisMarkValues {
        if dayRange <= 7 {
            return .stride(by: .day)
        } else {
            return .stride(by: .day, count: 10)
        }
    }

    var dateLabelFormat: Date.FormatStyle {
        .dateTime.month(.abbreviated).day()
    }

    // MARK: - Data padding

    func padStats(_ raw: [DailyStat], days: Int) -> [DailyStat] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var map = [Date: DailyStat]()
        for s in raw { map[cal.startOfDay(for: s.date)] = s }

        var result = [DailyStat]()
        for offset in 0..<days {
            guard let date = cal.date(byAdding: .day, value: -(days - 1 - offset), to: today) else { continue }
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
        let raw = await StatsService.dailyStats(days: dayRange)
        dailyStats = padStats(raw, days: dayRange)
        providerCosts = await StatsService.providerDailyCosts(days: dayRange)
        codeChanges = await StatsService.dailyCodeChanges(days: dayRange)
        models = await StatsService.modelBreakdown()
        repos = await StatsService.repoBreakdown()
        prediction = await StatsService.prediction()
        paddedChanges = padCodeChanges()
        subDaily = subDailyData()
        apiDaily = apiDailyData()
    }
}
