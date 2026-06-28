import SwiftUI
import Charts

struct DashboardView: View {
    @State private var dailyStats: [DailyStat] = []
    @State private var providerCosts: [ProviderDailyCost] = []
    @State private var codeChanges: [DailyCodeChange] = []
    @State private var models: [ModelBreakdown] = []
    @State private var repos: [RepoBreakdown] = []
    @State private var prediction: Prediction?
    @State private var dayRange = 7
    @State private var costHoverDate: Date? = nil
    @State private var codeHoverDate: Date? = nil
    @State private var costHoverX: CGFloat = 0
    @State private var codeHoverX: CGFloat = 0

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
            Text("单行成本不可用").font(.headline)
            Text("启用 Claude Code 或 aider 以解锁 CPL 统计。这些工具会写入本地日志，可精确归因到仓库。")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Text("Claude Code：`~/.claude/projects/`").font(.caption2).foregroundColor(.secondary)
                Text("aider：仓库内 `.aider.llm.history`").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(24).frame(maxWidth: .infinity)
        .background(Color(nsColor: .quaternarySystemFill).opacity(0.3))
        .cornerRadius(10)
    }

    // MARK: - Subscription card (C-grade)

    var subscriptionCard: some View {
        let subs = IntegrationRegistry.enabledCGrade()
        guard !subs.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text("订阅月费").font(.headline)
                Text("⚠️ 不参与 CPL 计算。可能与 Token 花费重叠。")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(subs, id: \.id) { s in
                    let cfg = IntegrationRegistry.config(for: s.id)
                    HStack {
                        Text(s.displayName).font(.body)
                        Spacer()
                        Text(cfg.subscriptionTier).font(.callout).foregroundColor(.secondary)
                        Text("· 日均 $\(String(format: "%.2f", estimatedDailySub(s.id)))")
                            .font(.caption).foregroundColor(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(16)
            .background(Color(nsColor: .quaternarySystemFill).opacity(0.3))
            .cornerRadius(10)
        )
    }

    // MARK: - API Balance card (B-grade)

    var apiBalanceCard: some View {
        let bs = IntegrationRegistry.enabledBGrade()
        guard !bs.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text("API 余额").font(.headline)
                Text("⚠️ 不参与 CPL。余额变化可能包含 Token 花费中的数据。")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(bs, id: \.id) { b in
                    HStack {
                        Text(b.displayName).font(.body)
                        Spacer()
                        if let cached = ApiPoller.shared.cachedBalance(for: b.id),
                           let bal = cached.balances.first {
                            Text("\(bal.currency) \(String(format: "%.2f", bal.totalBalance))")
                                .font(.callout).monospacedDigit()
                        } else {
                            Text("--").foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .quaternarySystemFill).opacity(0.3))
            .cornerRadius(10)
        )
    }

    func estimatedDailySub(_ id: String) -> Double {
        let cfg = IntegrationRegistry.config(for: id)
        guard !cfg.subscriptionTier.isEmpty else { return 0 }
        let days = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
        if let tool = SubscriptionRegistry.tool(forName: id == "cursor" ? "Cursor" : id == "copilot" ? "GitHub Copilot" : id == "windsurf" ? "Windsurf" : ""),
           let tier = tool.tiers.first(where: { $0.label == cfg.subscriptionTier }) {
            return tier.fee / days
        }
        return 0
    }

    // MARK: - Summary cards

    var summaryCards: some View {
        HStack(spacing: 12) {
            card(title: I18n.t("dashboard.month_spent"),
                 value: prediction.map { "$\(String(format: "%.2f", $0.monthSoFar))" } ?? "--")
            card(title: I18n.t("dashboard.month_projected"),
                 value: prediction.map { "$\(String(format: "%.2f", $0.monthProjected))" } ?? "--")
            card(title: I18n.t("dashboard.week_added_del"),
                 value: weekAddedDel())
            card(title: I18n.t("dashboard.sub_daily"),
                 value: "$\(String(format: "%.2f", totalSubDaily()))")
        }
    }

    func card(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3).fontWeight(.bold).monospacedDigit()
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Color(nsColor: .quaternarySystemFill)).cornerRadius(8)
    }

    func weekAddedDel() -> String {
        let added = codeChanges.reduce(0) { $0 + $1.added }
        let deleted = codeChanges.reduce(0) { $0 + $1.deleted }
        return "+\(added)/-\(deleted)"
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
                        // Subscription amortization (bottom layer — constant per day)
                        ForEach(subDailyData(), id: \.id) { item in
                            BarMark(
                                x: .value("Date", item.date, unit: .day),
                                y: .value("Cost", item.cost)
                            )
                            .foregroundStyle(by: .value("Source", item.label))
                            .position(by: .value("Layer", "sub"))
                        }
                        // API balance consumption (top layer — variable per day)
                        ForEach(apiDailyData(), id: \.id) { item in
                            BarMark(
                                x: .value("Date", item.date, unit: .day),
                                y: .value("Cost", item.cost)
                            )
                            .foregroundStyle(by: .value("Source", item.label))
                            .position(by: .value("Layer", "api"))
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
                Text(I18n.t("dashboard.cost_footnote"))
                    .font(.caption2).foregroundColor(.secondary)
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
        let subs = subDailyData().filter { cal.isDate($0.date, inSameDayAs: date) }
        let apis = apiDailyData().filter { cal.isDate($0.date, inSameDayAs: date) }
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
                        ForEach(paddedCodeChanges(), id: \.id) { d in
                            BarMark(
                                x: .value("Date", d.date, unit: .day),
                                y: .value("Lines", d.added)
                            )
                            .foregroundStyle(Color.green.opacity(0.7))
                            .position(by: .value("Type", I18n.t("dashboard.added")))
                        }
                        ForEach(paddedCodeChanges(), id: \.id) { d in
                            BarMark(
                                x: .value("Date", d.date, unit: .day),
                                y: .value("Lines", d.deleted)
                            )
                            .foregroundStyle(Color.orange.opacity(0.7))
                            .position(by: .value("Type", I18n.t("dashboard.deleted")))
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
                       let pt = paddedCodeChanges().first(where: { Calendar.current.isDate($0.date, inSameDayAs: hd) }),
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

    func paddedCodeChanges() -> [DailyCodeChange] {
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
                        Text("$\(String(format: "%.2f", r.costPerLine))/\(I18n.t("menu.per_line"))")
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
            apiBalanceCard
            subscriptionCard
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
            Text("在 设置 → 集成 中启用工具后，这里将显示花费与代码变化图表。")
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
                        Text("Repository").font(.caption2).foregroundColor(.secondary)
                        Text(I18n.t("dashboard.cost_usd")).font(.caption2).foregroundColor(.secondary)
                        Text(I18n.t("menu.lines")).font(.caption2).foregroundColor(.secondary)
                        Text("CPL").font(.caption2).foregroundColor(.secondary)
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
    }
}
