import SwiftUI
import Charts

// macOS color palette (mars green + deep red)
extension Color {
    static let marsGreen      = Color(red: 44/255, green: 91/255, blue: 72/255)
    static let marsGreenLight = Color(red: 140/255, green: 196/255, blue: 170/255)
    static let deepRed        = Color(red: 173/255, green: 46/255, blue: 35/255)
    static let deepRed2       = Color(red: 196/255, green: 74/255, blue: 63/255)
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
                    Text("Today").tag(TimeRange.today)
                    Text("Week").tag(TimeRange.week)
                    Text("30d").tag(TimeRange.days30)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: timeRange) { _, newRange in
                    barProgress = 0
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { barProgress = 1 }
                    let key = newRange == .today ? "today" : newRange == .week ? "week" : "30d"
                    Task { try? await cloudData.fetchSnapshot(for: key) }
                }

                VStack(spacing: 4) {
                    Text("$\(String(format: "%.2f", totalCost))")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.deepRed)
                        .scaleEffect(0.8 + 0.2 * barProgress)
                    HStack(spacing: 6) {
                        Text("\(timeRange.label) \(totalCost > 0 ? "Total" : "")")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if let p = snap.prediction, p.monthProjected > 0.001 {
                        Text(String(format: "Spent $%.2f this month · $%.2f projected · %d days left",
                                    p.monthSoFar, p.monthProjected, p.daysRemaining))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 12)

                HStack(alignment: .top, spacing: 8) {
                    subVsApiDonut
                    noseStatCards
                    providerDonut
                }

                if !snap.toolBreakdown.isEmpty {
                    toolBars
                }

                if !snap.topRepos.isEmpty {
                    repoList
                }

                if timeRange != .today {
                    trendChart
                }

                if let updated = cloudData.lastUpdated {
                    Text("Updated \(updated, style: .relative) ago")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding()
        }
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
                Text("$\(String(format: "%.2f", t))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            HStack(spacing: 8) {
                if apiSpend > 0.001 { HStack(spacing: 2) { Circle().fill(Color.deepRed).frame(width: 6, height: 6); Text("API \(Int(apiSpend / max(t, 0.01) * 100))%").font(.caption2) } }
                if subTotal > 0.001 { HStack(spacing: 2) { Circle().fill(Color.marsGreen).frame(width: 6, height: 6); Text("Sub \(Int(subTotal / max(t, 0.01) * 100))%").font(.caption2) } }
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
                Text("$\(String(format: "%.2f", apiSpend))")
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
            statCard("Net Lines", value: "\(f.reduce(0) { $0 + $1.netLines })")
            statCard("Added", value: "+\(f.reduce(0) { $0 + $1.added })", color: .marsGreen)
            statCard("Deleted", value: "-\(f.reduce(0) { $0 + $1.deleted })", color: .deepRed)
            if timeRange == .today {
                statCard("Calls", value: "\(snap.todayCalls)")
                statCard("Tokens", value: tokenShort(snap.todayTokens))
            }
        }.frame(width: 90)
    }

    // MARK: - Tool & Repo

    @ViewBuilder
    private var toolBars: some View {
        let maxCost = snap.toolBreakdown.map(\.cost).max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            Text("By Tool").font(.caption).foregroundColor(.secondary)
            ForEach(snap.toolBreakdown.prefix(5), id: \.name) { tool in
                HStack {
                    Text(tool.name).font(.caption).frame(width: 90, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3).fill(Color.marsGreen)
                            .frame(width: max(geo.size.width * CGFloat(tool.cost / maxCost), 2))
                    }.frame(height: 8)
                    Spacer()
                    Text("$\(String(format: "%.2f", tool.cost))").font(.caption2).monospacedDigit()
                }
            }
        }
        .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var repoList: some View {
        let items = snap.topRepos.filter { $0.added + $0.deleted > 0 }.prefix(6)
        let maxCost = items.map(\.cost).max() ?? 1
        let maxCPL = items.compactMap { $0.cpl > 0 ? $0.cpl : nil }.max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            Text("By Repo").font(.caption).foregroundColor(.secondary)
            ForEach(Array(items), id: \.name) { repo in
                HStack {
                    Text(repo.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text("+\(repo.added)/-\(repo.deleted)").font(.caption2).foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Text("$\(String(format: "%.2f", repo.cost))").font(.caption2).monospacedDigit().frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2).fill(Color.marsGreen)
                            .frame(width: max(geo.size.width * CGFloat(repo.cost / maxCost), 2))
                    }.frame(height: 4)
                }
                HStack(spacing: 4) {
                    Text("CPL $\(String(format: "%.2f", repo.cpl))").font(.caption2).foregroundColor(.secondary).frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2).fill(Color.deepRed.opacity(0.5))
                            .frame(width: max(geo.size.width * CGFloat(repo.cpl / maxCPL), 2))
                    }.frame(height: 4)
                }
            }
        }
        .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
            Text("Daily Trend").font(.headline)
            Chart {
                ForEach(paddedStats, id: \.ts) { s in
                    let d = Date(timeIntervalSince1970: s.ts)
                    let api = snap.balanceDaily.first(where: { cal.isDate(Date(timeIntervalSince1970: $0.ts), inSameDayAs: d) })?.value ?? 0
                    BarMark(x: .value("Date", d, unit: .day), y: .value("Value", api * barProgress))
                        .foregroundStyle(Color.marsGreen).position(by: .value("Series", "Cost"))
                }
                ForEach(paddedStats, id: \.ts) { s in
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
                HStack(spacing: 2) { RoundedRectangle(cornerRadius: 1).fill(Color.marsGreen).frame(width: 8, height: 8); Text("API").font(.caption2) }
                HStack(spacing: 2) { RoundedRectangle(cornerRadius: 1).fill(Color.marsGreenLight).frame(width: 8, height: 8); Text("Sub").font(.caption2) }
                HStack(spacing: 2) { RoundedRectangle(cornerRadius: 1).fill(Color.deepRed2).frame(width: 8, height: 8); Text("Added").font(.caption2) }
                HStack(spacing: 2) { RoundedRectangle(cornerRadius: 1).fill(Color.deepRed.opacity(0.35)).frame(width: 8, height: 8); Text("Deleted").font(.caption2) }
            }
        }
        .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func statCard(_ label: String, value: String, color: Color = .primary) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.caption).fontWeight(.semibold).foregroundStyle(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }
    private func shortNum(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)K" : "\(n)" }
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
    var label: String { switch self { case .today: "Today"; case .week: "This Week"; case .days30: "30 Days" } }
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