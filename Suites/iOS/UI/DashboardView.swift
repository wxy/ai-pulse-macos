import SwiftUI
import Charts
import AIPulseShared

// Additional iOS-only color palette variants. Base colors now come from
// AIPulseShared.
extension Color {
    // Dark mode: use lighter variants for better contrast
    static let marsGreenBar   = Color(light: .marsGreen, dark: .marsGreenLight)
    static let deepRedBar     = Color(light: .deepRed, dark: Color(red: 235/255, green: 100/255, blue: 90/255))

    init(light: Color, dark: Color) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}

/// Frosted card border matching macOS .ultraThinMaterial + separator.
struct FrostedCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
    }
}

struct DashboardView: View {
    @EnvironmentObject var cloudData: CloudDataService
    @State private var timeRange = TimeRange.today
    @State private var barProgress: CGFloat = 0
    @State private var toolsExpanded = false
    @State private var reposExpanded = false
    @State private var fetchTask: Task<Void, Never>?
    @State private var selectedTool: ToolDetailItem? = nil

    private var snap: DashboardSnapshot { cloudData.snapshot ?? DashboardSnapshot() }

    private var totalCost: Double {
        switch timeRange {
        case .today:  return snap.todayCost
        case .week:   return snap.weekCost
        case .days30: return snap.monthCost
        }
    }

    private var apiSpend: Double {
        snap.providerBreakdown.reduce(0) { $0 + $1.cost }
    }

    private var subTotal: Double {
        snap.subDaily * Double(timeRange.days)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("", selection: $timeRange) {
                    Text(I18n.t("time.today")).tag(TimeRange.today)
                    Text(I18n.t("time.week")).tag(TimeRange.week)
                    Text(I18n.t("time.30d")).tag(TimeRange.days30)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 4).padding(.bottom, 12)
                .sensoryFeedback(.selection, trigger: timeRange)
                .onChange(of: timeRange) { _, newRange in
                    barProgress = 0
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { barProgress = 1 }
                    fetchTask?.cancel()
                    let key = newRange.cacheKey
                    fetchTask = Task { try? await cloudData.fetchSnapshot(for: key) }
                }

                // ── Robot head frame (face) — spending + output ──
                VStack(spacing: 12) {
                    // Big total
                    VStack(spacing: 2) {
                        Text(usd(totalCost))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.deepRed)
                            .scaleEffect(0.8 + 0.2 * barProgress)
                            .overlay(alignment: .trailing) {
                                HStack(spacing: 4) {
                                    if timeRange == .today, snap.yesterdaySpend > 0.001 {
                                        comparisonBadge(current: totalCost, previous: snap.yesterdaySpend)
                                    }
                                    if timeRange == .days30, snap.previousPeriodSpend > 0.001 {
                                        comparisonBadge(current: totalCost, previous: snap.previousPeriodSpend)
                                    }
                                }
                                .offset(x: 44)
                            }
                        HStack(spacing: 4) {
                            Text("\(timeRange.label)\(I18n.t("dashboard.total"))")
                                .font(.caption).foregroundColor(.secondary)
                            // Per-tab context: today=projected, week/30d=daily avg + projected + remaining
                            if let p = snap.prediction, p.monthProjected > 0.001 {
                                if timeRange == .today {
                                    Text("· \(String(format: I18n.t("dashboard.today_expected"), String(format: "%.2f", p.dailyRate)))")
                                } else if timeRange == .week {
                                    Text("· \(String(format: I18n.t("dashboard.range_context"), String(format: "%.2f", p.dailyRate * 7), 7 - timeRange.days))")
                                } else {
                                    Text("· \(String(format: I18n.t("dashboard.range_context"), String(format: "%.2f", p.dailyRate * 30), p.daysRemaining))")
                                }
                            }
                        }
                        .font(.caption2).foregroundColor(.secondary)
                    }

                    // Donuts + stats — centered
                    HStack(alignment: .top, spacing: 6) {
                        Spacer(minLength: 0)
                        subVsApiDonut
                        noseStatCards
                        providerDonut
                        Spacer(minLength: 0)
                    }

                    // Tool + repo ("mouth")
                    outputSection
                }
                .padding(.top, 28).padding(.horizontal, 12).padding(.bottom, 14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.marsGreen.opacity(0.3), lineWidth: 2)
                )
                .overlay(alignment: .top) {
                    // Antenna
                    ZStack(alignment: .top) {
                        Path { p in
                            p.addArc(center: CGPoint(x: 16, y: 2), radius: 16,
                                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                        }
                        .stroke(Color.marsGreen.opacity(0.3), lineWidth: 2)
                        .frame(width: 32, height: 18)
                        Circle().fill(Color.marsGreen.opacity(0.4)).frame(width: 5, height: 5).offset(y: -6)
                    }
                    .offset(y: -3)
                }
                .overlay(alignment: .leading) {
                    // Left ears
                    HStack(spacing: 4) {
                        earBar(width: 10, height: 26)
                        earBar(width: 6, height: 16)
                    }
                    .offset(x: -10, y: -60)
                }
                .overlay(alignment: .trailing) {
                    // Right ears
                    HStack(spacing: 4) {
                        earBar(width: 6, height: 16)
                        earBar(width: 10, height: 26)
                    }
                    .offset(x: 10, y: -60)
                }

                // ── Trend section (body) ──
                if timeRange != .today {
                    trendChart
                } else if !snap.remainingBalances.isEmpty || !snap.quotaStatus.isEmpty {
                    remainingBalanceRow
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.marsGreen.opacity(0.3), lineWidth: 2)
                        )
                }

                HStack(spacing: 6) {
                    Text("AI Pulse v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")/CloudKit \(CKSchema.payloadVersion)")
                        .font(.caption2).foregroundColor(.secondary)
                    if let updated = cloudData.lastUpdated {
                        Text("\(I18n.t("dashboard.updated")) \(updated, format: .dateTime.month(.abbreviated).day().hour().minute().locale(.current))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
        .environment(\.locale, Locale(identifier: {
            switch I18n.lang {
            case "zh-Hans":    return "zh_CN"
            case "zh-Hant-TW": return "zh_TW"
            case "zh-Hant-HK": return "zh_HK"
            case "ja":         return "ja_JP"
            case "ko":         return "ko_KR"
            case "de":         return "de_DE"
            case "fr":         return "fr_FR"
            case "es":         return "es_ES"
            case "pt-BR":      return "pt_BR"
            default:           return "en_US"
            }
        }()))
        .refreshable {
            await cloudData.refresh()
        }
        .onAppear {
            barProgress = 1
            let key = timeRange.cacheKey
            fetchTask = Task { try? await cloudData.fetchSnapshot(for: key) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            fetchTask?.cancel()
            let key = timeRange.cacheKey
            fetchTask = Task { try? await cloudData.fetchSnapshot(for: key) }
        }
        .sheet(item: $selectedTool) { detail in
            ToolDetailSheetView(detail: detail)
        }
    }

    // MARK: - Donuts

    @ViewBuilder
    private var subVsApiDonut: some View {
        let t = ChartMath.finite(apiSpend + subTotal, fallback: 0)
        VStack(spacing: 2) {
            ZStack {
                if t > 0.001 {
                    Chart {
                        if ChartMath.finite(apiSpend, fallback: 0) > 0.001 {
                            SectorMark(angle: .value("API", apiSpend), innerRadius: .ratio(0.5))
                                .foregroundStyle(Color.deepRed)
                        }
                        if ChartMath.finite(subTotal, fallback: 0) > 0.001 {
                            SectorMark(angle: .value("Sub", subTotal), innerRadius: .ratio(0.5))
                                .foregroundStyle(Color.marsGreen)
                        }
                    }
                    .frame(width: 80, height: 80)
                } else {
                    Circle().stroke(.secondary.opacity(0.15), lineWidth: 10).frame(width: 80, height: 80)
                }
                Text(usd(t))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            VStack(spacing: 2) {
                let apiPct = ChartMath.safeInt(ChartMath.ratio(apiSpend, denominator: t, fallback: 0) * 100)
                let subPct = ChartMath.safeInt(ChartMath.ratio(subTotal, denominator: t, fallback: 0) * 100)
                if apiSpend > 0.001 { HStack(spacing: 2) { Circle().fill(Color.deepRed).frame(width: 6, height: 6); (Text(I18n.t("stat.api")) + Text(verbatim: " " + apiPct.formatted(.percent))).font(.caption2) } }
                if subTotal > 0.001 { HStack(spacing: 2) { Circle().fill(Color.marsGreen).frame(width: 6, height: 6); (Text(I18n.t("stat.sub")) + Text(verbatim: " " + subPct.formatted(.percent))).font(.caption2) } }
            }
        }
        .frame(width: 90)
    }

    @ViewBuilder
    private var providerDonut: some View {
        // SectorMark cannot safely render a zero/NaN angle set; keep only
        // finite positive segments in chart geometry.
        let segments = snap.providerBreakdown.filter { $0.cost.isFinite && $0.cost > 0.001 }
        VStack(spacing: 2) {
            ZStack {
                if !segments.isEmpty {
                    Chart {
                        ForEach(segments, id: \.providerId) { p in
                            SectorMark(angle: .value("Cost", p.cost), innerRadius: .ratio(0.5))
                                .foregroundStyle(by: .value("Name", p.name))
                        }
                    }
                    .chartLegend(.hidden).frame(width: 80, height: 80)
                    .chartForegroundStyleScale(domain: segments.map(\.name),
                        range: [Color.deepRed, .marsGreen, Color.deepRed2])
                } else {
                    Circle().stroke(.secondary.opacity(0.15), lineWidth: 10).frame(width: 80, height: 80)
                }
                Text(usd(apiSpend))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            ForEach(segments.prefix(3), id: \.providerId) { p in
                HStack(spacing: 2) {
                    Circle().fill(Color.deepRed).frame(width: 6, height: 6)
                    let pctStr = ChartMath.safeInt(ChartMath.ratio(p.cost, denominator: apiSpend, fallback: 0) * 100).formatted(.percent)
                    Text(verbatim: "\(p.name) \(pctStr)")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .frame(width: 90)
    }

    private var noseStatCards: some View {
        let f = snap.codeChanges
        return VStack(spacing: 6) {
            statCard(I18n.t("dashboard.net_lines"), value: "\(f.reduce(0) { $0 + $1.netLines })")
            statCard(I18n.t("dashboard.added"), value: "+\(f.reduce(0) { $0 + $1.added })", color: .marsGreen)
            statCard(I18n.t("dashboard.deleted"), value: "-\(f.reduce(0) { $0 + $1.deleted })", color: .deepRed)
            if timeRange == .today {
                statCard(I18n.t("dashboard.calls"), value: "\(snap.todayCalls)")
                statCard(I18n.t("dashboard.tokens"), value: tokenShort(snap.todayTokens))
            }
        }.frame(width: 90)
    }

    // MARK: - Tool & Repo (output section)

    @ViewBuilder
    private var outputSection: some View {
        if !snap.toolBreakdown.isEmpty {
            toolBars
        }
        if !snap.topRepos.isEmpty {
            repoList
        }
    }

    @ViewBuilder
    private var remainingBalanceRow: some View {
        let items = snap.remainingBalances.filter { $0.balance > 0.001 }
        let quotas = snap.quotaStatus.filter { $0.utilization > 0 }
        if items.isEmpty && quotas.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 10) {
                Text(I18n.t("dashboard.remaining_balance")).font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                ForEach(items, id: \.providerId) { item in
                    HStack {
                        Text(item.displayName)
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text(balanceShort(item.balance, currency: item.currency))
                            .font(.caption).fontWeight(.semibold).monospacedDigit()
                    }
                }
                // Subscription quotas (Claude / Copilot utilization + reset countdown)
                ForEach(quotas, id: \.toolId) { q in
                    HStack {
                        Text(toolDisplayName(q.toolId))
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text((q.utilization / 100).formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption).monospacedDigit().foregroundColor(quotaColor(q.utilization))
                        if q.resetAt > 0 {
                            Text(quotaCountdownText(q.resetAt))
                                .font(.caption2).monospacedDigit().foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func balanceShort(_ v: Double, currency: String) -> String {
        let symbol: String = {
            switch currency { case "CNY": return "¥"; case "EUR": return "€"; default: return "$" }
        }()
        if v >= 1000 { return "\(symbol)\(String(format: "%.0f", v))" }
        return "\(symbol)\(String(format: "%.2f", v))"
    }

    private func toolDisplayName(_ toolId: String) -> String {
        switch toolId {
        case "claude-code": return "Claude Code"
        case "copilot":     return "GitHub Copilot"
        default:            return toolId
        }
    }

    private func matchingToolDetail(for displayName: String) -> ToolDetailItem? {
        let source: String
        switch displayName {
        case "ChatGPT":        source = "codex"
        case "Claude Code":    source = "claude-code"
        case "GitHub Copilot": source = "copilot"
        default:               return nil
        }
        // Fall back to an empty entry so the sheet opens with a "no session
        // data" state instead of a dead tap (e.g. old macOS snapshots that
        // predate toolDetails, or tools without session data).
        return snap.toolDetails.first { $0.source == source }
            ?? ToolDetailItem(source: source, conclusion: ToolConclusionItem(), sessions: [])
    }

    private func quotaColor(_ percent: Double) -> Color {
        switch percent {
        case 0..<75:  return .marsGreen
        case 75..<90: return .marsGreenLight
        default:      return .deepRed
        }
    }

    private func quotaCountdownText(_ resetAt: Double) -> String {
        let remaining = resetAt - Date().timeIntervalSince1970
        guard remaining > 0 else { return I18n.t("dashboard.quota_stale") }
        let fmt = DateComponentsFormatter()
        fmt.allowedUnits = [.day, .hour, .minute]
        fmt.unitsStyle = .abbreviated
        fmt.maximumUnitCount = 2
        return fmt.string(from: remaining) ?? ""
    }

    @ViewBuilder
    private var toolBars: some View {
        let all = snap.toolBreakdown
        let shown = toolsExpanded ? all : Array(all.prefix(3))
        let maxCost = all.compactMap { $0.cost.isFinite && $0.cost >= 0 ? $0.cost : nil }.max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            Text(I18n.t("dashboard.by_tool")).font(.caption).foregroundColor(.secondary)
            ForEach(shown, id: \.name) { tool in
                Button {
                    selectedTool = matchingToolDetail(for: tool.name)
                } label: {
                    HStack {
                        Text(tool.name).font(.caption).frame(width: 90, alignment: .leading)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3).fill(Color.marsGreenBar)
                                .frame(width: max(geo.size.width * CGFloat(ChartMath.ratio(tool.cost, denominator: maxCost, fallback: 0)), 2))
                        }.frame(height: 8)
                        Spacer()
                        Text(usd(tool.cost)).font(.caption2).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
            }
            if all.count > 3 {
                Button(toolsExpanded ? I18n.t("dashboard.show_less") : I18n.t("dashboard.show_all")) {
                    withAnimation { toolsExpanded.toggle() }
                }
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
    }

    @ViewBuilder
    private var repoList: some View {
        let all = snap.topRepos.filter { $0.added > 0 || $0.deleted > 0 }
        let shown = reposExpanded ? all : Array(all.prefix(3))
        let maxCost = all.compactMap { $0.cost.isFinite && $0.cost >= 0 ? $0.cost : nil }.max() ?? 1
        let maxCPL = all.compactMap { $0.cpl.isFinite && $0.cpl > 0 ? $0.cpl : nil }.max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            Text(I18n.t("dashboard.by_repo")).font(.caption).foregroundColor(.secondary)
            ForEach(shown, id: \.name) { repo in
                HStack {
                    Text(repo.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text("+\(repo.added)/-\(repo.deleted)").font(.caption2).foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Text(usd(repo.cost)).font(.caption2).monospacedDigit().frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2).fill(Color.marsGreenBar)
                            .frame(width: max(geo.size.width * CGFloat(ChartMath.ratio(repo.cost, denominator: maxCost, fallback: 0)), 2))
                    }.frame(height: 4)
                }
                HStack(spacing: 4) {
                    Text("CPL \(usd(repo.cpl))").font(.caption2).foregroundColor(.secondary).frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2).fill(Color.deepRedBar.opacity(0.5))
                            .frame(width: max(geo.size.width * CGFloat(ChartMath.ratio(repo.cpl, denominator: maxCPL, fallback: 0)), 2))
                    }.frame(height: 4)
                }
            }
            if all.count > 3 {
                Button(reposExpanded ? I18n.t("dashboard.show_less") : I18n.t("dashboard.show_all")) {
                    withAnimation { reposExpanded.toggle() }
                }
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
    }

    private func earBar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.marsGreen.opacity(0.2))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.marsGreen.opacity(0.35), lineWidth: 1))
            .frame(width: width, height: height)
    }

    /// Axis calculation — moved outside ViewBuilder to avoid control-flow restriction.
    private func trendAxis(cal: Calendar, chartStart: Date, chartDays: Int) -> (costMax: Double, codeMax: Double, scale: Double, costStep: Double) {
        let padResult = TrendPadding.pad(snap: snap, days: chartDays, cal: cal, chartStart: chartStart)
        if padResult.noData { return (0, 0, 1, 1) }
        let paddedStats = padResult.stats
        let paddedCode = padResult.code

        let rawCostMax = ChartMath.axisMax(paddedStats.map { s -> Double in
            let api = snap.balanceDaily.first(where: { cal.isDate(Date(timeIntervalSince1970: $0.ts), inSameDayAs: Date(timeIntervalSince1970: s.ts)) })?.value ?? 0
            return ChartMath.finite(api + snap.subDaily, fallback: 0)
        }.max() ?? 5, fallback: 5)
        let cStep = ChartMath.niceStep(rawCostMax / 4)
        let cMax = ChartMath.axisMax(ceil(rawCostMax / cStep) * cStep, fallback: cStep)

        let rawCodeMax = paddedCode.compactMap { c -> Double? in
            let total = Int64(c.added) + Int64(c.deleted)
            return total > 0 ? Double(total) : nil
        }.max() ?? 1
        let sec = cMax / cStep
        var cdStep = ChartMath.niceStep(rawCodeMax / sec)
        while cdStep * sec < rawCodeMax { cdStep = ChartMath.nextNiceStep(cdStep) }
        let cdMax = cdStep * sec
        let sc = cdMax > 0 ? cMax / cdMax : 1
        return (cMax, cdMax, sc, cStep)
    }

    // MARK: - Trend (duplicate of macOS logic)

    @ViewBuilder
    private var trendChart: some View {
        let chartDays = timeRange.chartDays
        let cal = Calendar.current
        let chartStart: Date = {
            if case .week = timeRange {
                var mc = cal; mc.firstWeekday = 2
                return mc.date(from: mc.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))
                    ?? mc.startOfDay(for: Date())
            }
            return cal.date(byAdding: .day, value: -(chartDays - 1), to: cal.startOfDay(for: Date()))
                ?? cal.startOfDay(for: Date())
        }()
        let chartXEnd = cal.date(byAdding: .day, value: chartDays, to: cal.startOfDay(for: chartStart))
            ?? cal.startOfDay(for: chartStart).addingTimeInterval(Double(chartDays) * 86_400)
        let axis = trendAxis(cal: cal, chartStart: chartStart, chartDays: chartDays)
        if axis.costMax == 0 { EmptyView() }
        
        let padResult = TrendPadding.pad(snap: snap, days: chartDays, cal: cal, chartStart: chartStart)
        let paddedStats = padResult.stats
        let paddedCode = padResult.code
        let costMax = axis.costMax
        let scale = axis.scale

        VStack(spacing: 8) {
            Text(I18n.t("dashboard.daily_trend")).font(.headline)
            Chart {
                ForEach(paddedStats, id: \.ts) { s in
                    let d = Date(timeIntervalSince1970: s.ts)
                    let api = snap.balanceDaily.first(where: { cal.isDate(Date(timeIntervalSince1970: $0.ts), inSameDayAs: d) })?.value ?? 0
                    BarMark(x: .value("Date", d, unit: .day), y: .value("Value", ChartMath.barValue(base: api, progress: Double(barProgress))))
                        .foregroundStyle(Color.marsGreen).position(by: .value("Series", "Cost"))
                }
                ForEach(paddedStats.filter { $0.ts <= Date().timeIntervalSince1970 }, id: \.ts) { s in
                    let d = Date(timeIntervalSince1970: s.ts)
                    BarMark(x: .value("Date", d, unit: .day), y: .value("Value", ChartMath.barValue(base: snap.subDaily, progress: Double(barProgress))))
                        .foregroundStyle(Color.marsGreenLight).position(by: .value("Series", "Cost"))
                }
                ForEach(paddedCode, id: \.ts) { c in
                    let d = Date(timeIntervalSince1970: c.ts)
                    BarMark(x: .value("Date", d, unit: .day), y: .value("Value", ChartMath.barValue(base: Double(c.added), progress: Double(barProgress), scale: scale)))
                        .foregroundStyle(Color.deepRed2).position(by: .value("Series", "Code"))
                }
                ForEach(paddedCode, id: \.ts) { c in
                    let d = Date(timeIntervalSince1970: c.ts)
                    BarMark(x: .value("Date", d, unit: .day), y: .value("Value", ChartMath.barValue(base: Double(c.deleted), progress: Double(barProgress), scale: scale)))
                        .foregroundStyle(Color.deepRed.opacity(0.35)).position(by: .value("Series", "Code"))
                }
            }
            .chartXScale(domain: chartStart...chartXEnd)
            .chartYScale(domain: 0...costMax)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic) { v in
                    AxisGridLine().foregroundStyle(.gray.opacity(0.2))
                    if let d = v.as(Double.self) { AxisValueLabel("$\(String(format: "%.0f", d))") }
                }
                AxisMarks(position: .trailing, values: .automatic) { v in
                    AxisGridLine().foregroundStyle(.gray.opacity(0.1))
                    if let d = v.as(Double.self) { AxisValueLabel(shortNum(ChartMath.safeInt(d / scale))) }
                }
            }
            .frame(height: 200)
            HStack(spacing: 12) {
                HStack(spacing: 2) { RoundedRectangle(cornerRadius: 1).fill(Color.marsGreen).frame(width: 8, height: 8); Text(I18n.t("stat.api")).font(.caption2) }
                HStack(spacing: 2) { RoundedRectangle(cornerRadius: 1).fill(Color.marsGreenLight).frame(width: 8, height: 8); Text(I18n.t("stat.sub")).font(.caption2) }
                HStack(spacing: 2) { RoundedRectangle(cornerRadius: 1).fill(Color.deepRed2).frame(width: 8, height: 8); Text(I18n.t("chart.added")).font(.caption2) }
                HStack(spacing: 2) { RoundedRectangle(cornerRadius: 1).fill(Color.deepRed.opacity(0.35)).frame(width: 8, height: 8); Text(I18n.t("chart.deleted")).font(.caption2) }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.marsGreen.opacity(0.25), lineWidth: 2))
    }

    // MARK: - Helpers

    private func statCard(_ label: String, value: String, color: Color = .primary) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.caption).fontWeight(.semibold).foregroundStyle(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func comparisonBadge(current: Double, previous: Double) -> some View {
        let pct = ChartMath.percentageDelta(current: current, previous: previous, fallback: 0)
        if abs(pct) < 1 {
            Text("→")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        } else if pct > 0 {
            let badge = "↑" + ChartMath.safeInt(round(pct)).formatted(.percent)
            Text(verbatim: badge)
                .font(.caption2).foregroundColor(.deepRed)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.deepRed.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        } else {
            let badge = "↓" + ChartMath.safeInt(round(-pct)).formatted(.percent)
            Text(verbatim: badge)
                .font(.caption2).foregroundColor(.marsGreen)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.marsGreen.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        }
    }
    private func shortNum(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)K" : "\(n)" }
    private static let usdFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US"); return f
    }()
    private func usd(_ v: Double) -> String {
        Self.usdFormatter.string(from: NSNumber(value: v)) ?? "$0.00"
    }

    private func tokenShort(_ n: Int64) -> String {
        if n >= 1_000_000 { return "\(n / 1_000_000)M" }
        if n >= 1000 { return "\(n / 1000)K" }
        return "\(n)"
    }
}

struct TrendPadding {
    let stats: [TrendPoint]; let code: [TrendPoint]; let noData: Bool
    static func pad(snap: DashboardSnapshot, days: Int, cal: Calendar, chartStart: Date) -> TrendPadding {
        var s = [TrendPoint](), c = [TrendPoint]()
        for i in 0..<days {
            guard let d = cal.date(byAdding: .day, value: i, to: chartStart) else { continue }
            let ts = d.timeIntervalSince1970
            let zero = TrendPoint(ts: ts, value: 0, calls: 0, tokens: 0, netLines: 0)
            s.append(snap.dailyStats.first(where: { cal.isDate(Date(timeIntervalSince1970: $0.ts), inSameDayAs: d) }) ?? zero)
            c.append(snap.codeChanges.first(where: { cal.isDate(Date(timeIntervalSince1970: $0.ts), inSameDayAs: d) }) ?? zero)
        }
        let nd = s.allSatisfy({ $0.value == 0 }) && c.allSatisfy({ $0.added == 0 })
        return TrendPadding(stats: s, code: c, noData: nd)
    }
}

enum TimeRange: Hashable {
    case today, week, days30
    var days: Int {
        switch self {
        case .today: return 1
        case .week:
            let cal = Calendar.current; var mc = cal; mc.firstWeekday = 2
            let mon = mc.date(from: mc.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))
                ?? mc.startOfDay(for: Date())
            let days = cal.dateComponents([.day], from: mon, to: cal.startOfDay(for: Date())).day ?? 0
            return max(days + 1, 1)
        case .days30: return 30
        }
    }
    var label: String { switch self { case .today: I18n.t("time.today"); case .week: I18n.t("time.week"); case .days30: I18n.t("time.30d") } }
    var chartDays: Int { switch self { case .week: 7; default: days } }
    var cacheKey: String { switch self { case .today: "today"; case .week: "week"; case .days30: "30d" } }
}
