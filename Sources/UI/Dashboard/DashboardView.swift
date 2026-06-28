import SwiftUI
import Charts

struct DashboardView: View {
    @State private var dailyStats: [DailyStat] = []
    @State private var models: [ModelBreakdown] = []
    @State private var repos: [RepoBreakdown] = []
    @State private var prediction: Prediction?
    @State private var dayRange = 7
    @State private var hoverDate: Date? = nil
    @State private var cplHoverDate: Date? = nil
    @State private var cplHoverX: CGFloat = 0
    @State private var hoverX: CGFloat = 0

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
                    combinedChart.padding(.horizontal, 20)
                    cplChart.padding(.horizontal, 20)
                    HStack(alignment: .top, spacing: 16) { modelSection; repoSection }
                        .padding(.horizontal, 20)
                }.padding(.bottom, 20)
            }
        }
        .frame(width: 680, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await load() }
        .onChange(of: dayRange) { _, _ in Task { await load() } }
    }

    // MARK: - Summary cards

    var summaryCards: some View {
        HStack(spacing: 12) {
            card(title: I18n.t("dashboard.month_spent"),
                 value: prediction.map { "$\(String(format: "%.2f", $0.monthSoFar))" } ?? "--")
            card(title: I18n.t("dashboard.month_projected"),
                 value: prediction.map { "$\(String(format: "%.2f", $0.monthProjected))" } ?? "--")
            card(title: I18n.t("dashboard.avg_cpl"), value: avgCPL())
            card(title: I18n.t("dashboard.total_lines"), value: "\(totalLines())")
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

    // MARK: - Combined chart

    // Target grid-line count — both axes will have exactly this many sections.
    private let targetGrid = 4.0

    /// Left axis: cost (USD).  Establishes the actual grid-line count.
    private var leftAxis: (max: Double, step: Double, values: [Double], sections: Int) {
        let rawMax = dailyStats.map(\.cost).max() ?? 5
        let step = niceStep(rawMax / targetGrid)
        let max = ceil(rawMax / step) * step
        let sections = Int(max / step)
        var vals = [Double](); var v = 0.0
        while v <= max + step / 2 { vals.append(v); v += step }
        return (max, step, vals, sections)
    }

    /// Right axis: net lines.  Uses the same section count as the left axis.
    /// `scale` maps line values → left-axis visual height.
    private var rightAxis: (max: Double, step: Double, values: [Double], scale: Double) {
        let rawMax = Double(dailyStats.map(\.netLines).max() ?? 1)
        let sections = Double(leftAxis.sections)
        guard rawMax > 0, leftAxis.max > 0, sections > 0 else { return (10, 2, [0, 2, 4, 6, 8, 10], 1) }
        var step = niceStep(rawMax / sections)
        while step * sections < rawMax { step = nextNiceStep(step) }
        let max = step * sections
        var vals = [Double](); var v = 0.0
        while v <= max + step / 2 { vals.append(v); v += step }
        let scale = leftAxis.max / max
        return (max, step, vals, scale)
    }

    /// Previous helpers (keep existing usage sites working)
    private var lineScaleFactor: Double { rightAxis.scale }
    var lineAxisMax: Double { leftAxis.max }
    var lineAxisValues: [Double] { leftAxis.values }
    var rightAxisValues: [Double] { rightAxis.values }

    var combinedChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(I18n.t("dashboard.cost_lines")).font(.headline)

            if dailyStats.isEmpty {
                Text(I18n.t("menu.no_usage")).foregroundColor(.secondary).padding(.vertical, 30)
            } else {
                ZStack(alignment: .topLeading) {
                    Chart {
                        ForEach(dailyStats) { d in
                            BarMark(x: .value("Date", d.date, unit: .day), y: .value("Cost", d.cost))
                                .foregroundStyle(Color.accentColor.opacity(0.7))
                                .position(by: .value("Series", "Cost"))
                        }
                        ForEach(dailyStats) { d in
                            BarMark(x: .value("Date", d.date, unit: .day), y: .value("Lines", Double(d.netLines) * lineScaleFactor))
                                .foregroundStyle(Color.green.opacity(0.7))
                                .position(by: .value("Series", "Lines"))
                        }
                        if let hd = hoverDate {
                            RuleMark(x: .value("Date", hd, unit: .day))
                                .foregroundStyle(.gray.opacity(0.3))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: dateStride) { _ in
                            AxisValueLabel(format: dateLabelFormat, orientation: .horizontal)
                        }
                    }
                    // Left (cost) axis owns the domain with nice rounded values.
                    // Right (lines) axis mirrors at the same positions with de-normalized labels.
                    .chartYScale(domain: 0...lineAxisMax)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: lineAxisValues) { value in
                            AxisGridLine()
                            if let v = value.as(Double.self) { AxisValueLabel(String(format: "%.1f", v)) }
                        }
                        // Right axis: map nice right-axis values to cost-scale positions
                        AxisMarks(position: .trailing,
                                  values: rightAxis.values.map { $0 * leftAxis.max / rightAxis.max }) { value in
                            let idx = value.index
                            if idx < rightAxis.values.count {
                                AxisValueLabel("\(Int(rightAxis.values[idx]))")
                            }
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Color.clear
                                .onContinuousHover { phase in
                                    if case .active(let loc) = phase,
                                       let frame = proxy.plotFrame {
                                        let originX = geo[frame].origin.x
                                        let plotW = geo[frame].width
                                        let x = loc.x - originX
                                        // Clamp to plot area bounds — ignore hover on axes/labels
                                        guard x >= 0, x <= plotW else { hoverDate = nil; return }
                                        hoverX = x
                                        hoverDate = proxy.value(atX: x)
                                    } else { hoverDate = nil }
                                }
                        }
                    }
                    .frame(height: 200)

                    // Tooltip: only for dates with actual (non-padded) data
                    if let hd = hoverDate,
                       let stat = dailyStats.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hd) }),
                       stat.cost > 0 || stat.netLines != 0 {
                        tooltipView(date: hd, cost: stat.cost, lines: stat.netLines)
                            .offset(x: min(max(hoverX - 40, 0), 560), y: 0)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .quaternarySystemFill).opacity(0.3))
        .cornerRadius(10)
    }

    // MARK: - CPL chart

    var cplChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(I18n.t("dashboard.cpl_trend")).font(.headline)
            let cplData = dailyStats.filter { $0.cost > 0 && $0.netLines > 0 }
            if cplData.isEmpty {
                Text(I18n.t("menu.no_usage")).foregroundColor(.secondary).padding(.vertical, 20)
            } else {
                ZStack(alignment: .topLeading) {
                    Chart(cplData) { d in
                        LineMark(x: .value("Date", d.date, unit: .day), y: .value("CPL", d.costPerLine))
                            .foregroundStyle(Color.orange).lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("Date", d.date, unit: .day), y: .value("CPL", d.costPerLine))
                            .foregroundStyle(Color.orange)
                        if let hd = cplHoverDate {
                            RuleMark(x: .value("Date", hd, unit: .day))
                                .foregroundStyle(.gray.opacity(0.3))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: dateStride) { _ in
                            AxisValueLabel(format: dateLabelFormat, orientation: .horizontal)
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
                                        guard x >= 0, x <= plotW else { cplHoverDate = nil; return }
                                        cplHoverX = x
                                        cplHoverDate = proxy.value(atX: x)
                                    } else { cplHoverDate = nil }
                                }
                        }
                    }
                    .frame(height: 140)

                    if let hd = cplHoverDate,
                       let pt = cplData.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hd) }) {
                        cplTooltipView(date: hd, cpl: pt.costPerLine)
                            .offset(x: min(max(cplHoverX - 40, 0), 560), y: 0)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .quaternarySystemFill).opacity(0.3)).cornerRadius(10)
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
                        Text("Cost").font(.caption2).foregroundColor(.secondary)
                        Text("Lines").font(.caption2).foregroundColor(.secondary)
                        Text("CPL").font(.caption2).foregroundColor(.secondary)
                    }
                    Divider()
                    ForEach(repos.prefix(8)) { r in
                        GridRow {
                            Text(r.repo).font(.caption).lineLimit(1)
                            Text("$\(String(format: "%.2f", r.cost))").font(.caption2).monospacedDigit()
                            Text("\(r.netLines)").font(.caption2).monospacedDigit()
                            let cpl = r.netLines > 0 ? r.costPerLine : 0
                            Text("$\(String(format: "%.4f", cpl))\(I18n.t("menu.per_line"))")
                                .font(.caption2).monospacedDigit()
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity)
    }

    /// Round a value up to a "nice" number (100, 200, 500, 1000, etc.)
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

    /// Bump a nice step to the next nice size (1→2→5→10→20→50→100...)
    func nextNiceStep(_ step: Double) -> Double {
        let niceSteps: [Double] = [1, 2, 5, 10]
        let magnitude = pow(10, floor(log10(max(step, 1))))
        let mantissa = step / magnitude
        if let idx = niceSteps.firstIndex(where: { $0 > mantissa + 0.001 }) {
            return niceSteps[idx] * magnitude
        }
        return 10 * magnitude
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

    func tooltipView(date: Date, cost: Double, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.month(.abbreviated).day()).font(.caption).fontWeight(.semibold)
            Text("$\(String(format: "%.2f", cost))").font(.caption2).monospacedDigit()
            Text("\(lines) \(I18n.t("menu.lines"))").font(.caption2).monospacedDigit()
        }
        .padding(6).background(.regularMaterial).cornerRadius(6)
    }

    func cplTooltipView(date: Date, cpl: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.month(.abbreviated).day()).font(.caption).fontWeight(.semibold)
            Text("$\(String(format: "%.4f", cpl))\(I18n.t("menu.per_line"))").font(.caption2).monospacedDigit()
        }
        .padding(6).background(.regularMaterial).cornerRadius(6)
    }

    // MARK: - Data padding

    /// Fill missing days with zero entries so the chart always has the expected
    /// number of positions — 7 or 30.
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
        return "$\(String(format: "%.4f", tc / Double(tl)))"
    }

    func totalLines() -> String {
        "\(dailyStats.reduce(0) { $0 + $1.netLines })"
    }

    func load() async {
        let raw = await StatsService.dailyStats(days: dayRange)
        dailyStats = padStats(raw, days: dayRange)
        models = await StatsService.modelBreakdown()
        repos = await StatsService.repoBreakdown()
        prediction = await StatsService.prediction()
    }
}
