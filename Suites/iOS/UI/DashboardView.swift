import SwiftUI
import Charts

// macOS color palette (mars green + deep red)
extension Color {
    // Dark mode: use lighter variants for better contrast
    static let marsGreen      = Color(red: 44/255, green: 91/255, blue: 72/255)
    static let marsGreenBar   = Color(light: Color(red: 44/255, green: 91/255, blue: 72/255), dark: Color(red: 140/255, green: 196/255, blue: 170/255))
    static let marsGreenLight = Color(red: 140/255, green: 196/255, blue: 170/255)
    static let deepRed        = Color(red: 173/255, green: 46/255, blue: 35/255)
    static let deepRedBar     = Color(light: Color(red: 173/255, green: 46/255, blue: 35/255), dark: Color(red: 235/255, green: 100/255, blue: 90/255))
    static let deepRed2       = Color(red: 196/255, green: 74/255, blue: 63/255)

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
                .onChange(of: timeRange) { _, newRange in
                    barProgress = 0
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { barProgress = 1 }
                    let key = newRange == .today ? "today" : newRange == .week ? "week" : "30d"
                    Task { try? await cloudData.fetchSnapshot(for: key) }
                }

                // ── Robot head frame (face) — spending + output ──
                VStack(spacing: 12) {
                    // Big total
                    VStack(spacing: 2) {
                        Text(usd(totalCost))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.deepRed)
                            .scaleEffect(0.8 + 0.2 * barProgress)
                        Text("\(timeRange.label) \(totalCost > 0 ? I18n.t("dashboard.total") : "")")
                            .font(.caption).foregroundColor(.secondary)
                        if let p = snap.prediction, p.monthProjected > 0.001 {
                            Text(String(format: I18n.t("dashboard.spent_month"),
                                        p.monthSoFar, p.monthProjected, p.daysRemaining))
                                .font(.caption2).foregroundColor(.secondary)
                        }
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
                .padding(.top, 28).padding(.horizontal, 14).padding(.bottom, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.marsGreen.opacity(0.3), lineWidth: 2)
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
                )

                // ── Trend section (body) ──
                if timeRange != .today {
                    trendChart
                }

                if let updated = cloudData.lastUpdated {
                    Text("\(I18n.t("dashboard.updated")) \(updated, format: .dateTime.month(.abbreviated).day().hour().minute().locale(.current))")
                        .font(.caption2).foregroundColor(.secondary)
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
        .onAppear {
            barProgress = 1
            Task { try? await cloudData.fetchSnapshot() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { try? await cloudData.fetchSnapshot() }
        }
    }

    // MARK: - Donuts

    @ViewBuilder
    private var subVsApiDonut: some View {
        let t = apiSpend + subTotal
        VStack(spacing: 2) {
            ZStack {
                if t > 0.001 {
                    Chart {
                        if apiSpend > 0.001 {
                            SectorMark(angle: .value("API", apiSpend), innerRadius: .ratio(0.5))
                                .foregroundStyle(Color.deepRed)
                        }
                        if subTotal > 0.001 {
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
                if apiSpend > 0.001 { HStack(spacing: 2) { Circle().fill(Color.deepRed).frame(width: 6, height: 6); Text("\(I18n.t("stat.api")) \(Int(apiSpend / max(t, 0.01) * 100))%").font(.caption2) } }
                if subTotal > 0.001 { HStack(spacing: 2) { Circle().fill(Color.marsGreen).frame(width: 6, height: 6); Text("\(I18n.t("stat.sub")) \(Int(subTotal / max(t, 0.01) * 100))%").font(.caption2) } }
            }
        }
    }

    @ViewBuilder
    private var providerDonut: some View {
        VStack(spacing: 2) {
            ZStack {
                if !snap.providerBreakdown.isEmpty {
                    Chart {
                        ForEach(snap.providerBreakdown, id: \.providerId) { p in
                            SectorMark(angle: .value("Cost", p.cost), innerRadius: .ratio(0.5))
                                .foregroundStyle(by: .value("Name", p.name))
                        }
                    }
                    .chartLegend(.hidden).frame(width: 80, height: 80)
                    .chartForegroundStyleScale(domain: snap.providerBreakdown.map(\.name),
                        range: [Color.deepRed, .marsGreen, Color.deepRed2])
                } else {
                    Circle().stroke(.secondary.opacity(0.15), lineWidth: 10).frame(width: 80, height: 80)
                }
                Text(usd(apiSpend))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            ForEach(snap.providerBreakdown.prefix(3), id: \.providerId) { p in
                HStack(spacing: 2) {
                    Circle().fill(Color.deepRed).frame(width: 6, height: 6)
                    Text("\(p.name) \(Int(p.cost / max(apiSpend, 0.01) * 100))%")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
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
    private var toolBars: some View {
        let maxCost = snap.toolBreakdown.map(\.cost).max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            Text(I18n.t("dashboard.by_tool")).font(.caption).foregroundColor(.secondary)
            ForEach(snap.toolBreakdown.prefix(5), id: \.name) { tool in
                HStack {
                    Text(tool.name).font(.caption).frame(width: 90, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3).fill(Color.marsGreenBar)
                            .frame(width: max(geo.size.width * CGFloat(tool.cost / maxCost), 2))
                    }.frame(height: 8)
                    Spacer()
                    Text(usd(tool.cost)).font(.caption2).monospacedDigit()
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.15), lineWidth: 0.5))
    }

    @ViewBuilder
    private var repoList: some View {
        let items = snap.topRepos.filter { $0.added + $0.deleted > 0 }.prefix(6)
        let maxCost = items.map(\.cost).max() ?? 1
        let maxCPL = items.compactMap { $0.cpl > 0 ? $0.cpl : nil }.max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            Text(I18n.t("dashboard.by_repo")).font(.caption).foregroundColor(.secondary)
            ForEach(Array(items), id: \.name) { repo in
                HStack {
                    Text(repo.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text("+\(repo.added)/-\(repo.deleted)").font(.caption2).foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Text(usd(repo.cost)).font(.caption2).monospacedDigit().frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2).fill(Color.marsGreenBar)
                            .frame(width: max(geo.size.width * CGFloat(repo.cost / maxCost), 2))
                    }.frame(height: 4)
                }
                HStack(spacing: 4) {
                    Text("CPL $\(usd(repo.cpl))").font(.caption2).foregroundColor(.secondary).frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2).fill(Color.deepRedBar.opacity(0.5))
                            .frame(width: max(geo.size.width * CGFloat(repo.cpl / maxCPL), 2))
                    }.frame(height: 4)
                }
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

        let rawCostMax = paddedStats.map { s -> Double in
            let api = snap.balanceDaily.first(where: { cal.isDate(Date(timeIntervalSince1970: $0.ts), inSameDayAs: Date(timeIntervalSince1970: s.ts)) })?.value ?? 0
            return api + snap.subDaily
        }.max() ?? 5
        let cStep = niceStep(rawCostMax / 4)
        let cMax = ceil(rawCostMax / cStep) * cStep

        let rawCodeMax = Double(paddedCode.map { $0.added + $0.deleted }.max() ?? 1)
        let sec = cMax / cStep
        var cdStep = niceStep(rawCodeMax / sec)
        while cdStep * sec < rawCodeMax { cdStep = nextNiceStep(cdStep) }
        let cdMax = cdStep * sec
        let sc = cMax / cdMax
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
                return mc.date(from: mc.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
            }
            return cal.date(byAdding: .day, value: -(chartDays - 1), to: cal.startOfDay(for: Date()))!
        }()
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
                    BarMark(x: .value("Date", d, unit: .day), y: .value("Value", api * barProgress))
                        .foregroundStyle(Color.marsGreen).position(by: .value("Series", "Cost"))
                }
                ForEach(paddedStats.filter { $0.ts <= Date().timeIntervalSince1970 }, id: \.ts) { s in
                    let d = Date(timeIntervalSince1970: s.ts)
                    BarMark(x: .value("Date", d, unit: .day), y: .value("Value", snap.subDaily * barProgress))
                        .foregroundStyle(Color.marsGreenLight).position(by: .value("Series", "Cost"))
                }
                ForEach(paddedCode, id: \.ts) { c in
                    let d = Date(timeIntervalSince1970: c.ts)
                    BarMark(x: .value("Date", d, unit: .day), y: .value("Value", Double(c.added) * scale * barProgress))
                        .foregroundStyle(Color.deepRed2).position(by: .value("Series", "Code"))
                }
                ForEach(paddedCode, id: \.ts) { c in
                    let d = Date(timeIntervalSince1970: c.ts)
                    BarMark(x: .value("Date", d, unit: .day), y: .value("Value", Double(c.deleted) * scale * barProgress))
                        .foregroundStyle(Color.deepRed.opacity(0.35)).position(by: .value("Series", "Code"))
                }
            }
            .chartYScale(domain: 0...costMax)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic) { v in
                    AxisGridLine().foregroundStyle(.gray.opacity(0.2))
                    if let d = v.as(Double.self) { AxisValueLabel("$\(String(format: "%.0f", d))") }
                }
                AxisMarks(position: .trailing, values: .automatic) { v in
                    AxisGridLine().foregroundStyle(.gray.opacity(0.1))
                    if let d = v.as(Double.self) { AxisValueLabel(shortNum(Int(d / scale))) }
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
    private func shortNum(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)K" : "\(n)" }
    private func usd(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: v)) ?? "$0.00"
    }

    private func tokenShort(_ n: Int) -> String {
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
            let mon = mc.date(from: mc.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
            return cal.dateComponents([.day], from: mon, to: cal.startOfDay(for: Date())).day! + 1
        case .days30: return 30
        }
    }
    var label: String { switch self { case .today: I18n.t("time.today"); case .week: I18n.t("time.week"); case .days30: I18n.t("time.30d") } }
    var chartDays: Int { switch self { case .week: 7; default: days } }
}

private func niceStep(_ x: Double) -> Double {
    let e = pow(10, floor(log10(max(x, 0.001))))
    let m = x / e
    if m <= 1.5 { return e }
    if m <= 3 { return 2 * e }
    if m <= 7 { return 5 * e }
    return 10 * e
}
private func nextNiceStep(_ s: Double) -> Double {
    if s <= 1.5 { return 2 }
    if s <= 2.5 { return 5 }
    return s * 2
}