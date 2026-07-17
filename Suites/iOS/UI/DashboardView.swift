import SwiftUI
import Charts

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
                        .foregroundStyle(.red)
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

                // Donuts + stats
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
        let total = apiSpend + subTotal
        VStack(spacing: 2) {
            ZStack {
                if total > 0.001 {
                    Chart {
                        if apiSpend > 0.001 {
                            SectorMark(angle: .value("API", apiSpend), innerRadius: .ratio(0.5))
                                .foregroundStyle(Color.red)
                        }
                        if subTotal > 0.001 {
                            SectorMark(angle: .value("Sub", subTotal), innerRadius: .ratio(0.5))
                                .foregroundStyle(Color.green)
                        }
                    }
                    .frame(width: 80, height: 80)
                } else {
                    Circle().stroke(.secondary.opacity(0.15), lineWidth: 10)
                        .frame(width: 80, height: 80)
                }
                Text("$\(String(format: "%.2f", total))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            // Legend with percentages
            let t = apiSpend + subTotal
            HStack(spacing: 8) {
                if apiSpend > 0.001 { HStack(spacing: 2) { Circle().fill(.red).frame(width: 6, height: 6); Text("API \(Int(apiSpend / max(t, 0.01) * 100))%").font(.caption2) } }
                if subTotal > 0.001 { HStack(spacing: 2) { Circle().fill(.green).frame(width: 6, height: 6); Text("Sub \(Int(subTotal / max(t, 0.01) * 100))%").font(.caption2) } }
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
                    .chartLegend(.hidden)
                    .frame(width: 80, height: 80)
                } else {
                    Circle().stroke(.secondary.opacity(0.15), lineWidth: 10)
                        .frame(width: 80, height: 80)
                }
                Text("$\(String(format: "%.2f", apiSpend))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            // Legend
            ForEach(snap.providerBreakdown.prefix(3), id: \.providerId) { p in
                HStack(spacing: 2) {
                    Circle().fill(.blue).frame(width: 6, height: 6)
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
            statCard("Added", value: "+\(f.reduce(0) { $0 + $1.added })", color: .green)
            statCard("Deleted", value: "-\(f.reduce(0) { $0 + $1.deleted })", color: .red)
            if timeRange == .today {
                statCard("Calls", value: "\(snap.todayCalls)")
                statCard("Tokens", value: tokenShort(snap.todayTokens))
            }
        }
        .frame(width: 90)
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
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.green.opacity(0.6))
                            .frame(width: max(geo.size.width * CGFloat(tool.cost / maxCost), 2))
                    }.frame(height: 8)
                    Spacer()
                    Text("$\(String(format: "%.2f", tool.cost))").font(.caption2).monospacedDigit()
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var repoList: some View {
        let maxCost = snap.topRepos.map(\.cost).max() ?? 1
        let maxCPL = snap.topRepos.compactMap { $0.cpl > 0 ? $0.cpl : nil }.max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            Text("By Repo").font(.caption).foregroundColor(.secondary)
            ForEach(snap.topRepos.filter { $0.added + $0.deleted > 0 }.prefix(6), id: \.name) { repo in
                // Line 1: name + added/deleted
                HStack {
                    Text(repo.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text("+\(repo.added)/-\(repo.deleted)")
                        .font(.caption2).foregroundColor(.secondary)
                }
                // Line 2: cost bar
                HStack(spacing: 4) {
                    Text("$\(String(format: "%.2f", repo.cost))")
                        .font(.caption2).monospacedDigit().frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.green.opacity(0.5))
                            .frame(width: max(geo.size.width * CGFloat(repo.cost / maxCost), 2))
                    }.frame(height: 4)
                }
                // Line 3: CPL bar
                HStack(spacing: 4) {
                    Text("CPL $\(String(format: "%.2f", repo.cpl))")
                        .font(.caption2).foregroundColor(.secondary).frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue.opacity(0.4))
                            .frame(width: max(geo.size.width * CGFloat(repo.cpl / maxCPL), 2))
                    }.frame(height: 4)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Trend

    @ViewBuilder
    private var trendChart: some View {
        let filteredStats = snap.dailyStats
        let filteredCode = snap.codeChanges
        let filteredBalance = snap.balanceDaily
        let balanceMap = Dictionary(uniqueKeysWithValues: filteredBalance.map { (Date(timeIntervalSince1970: $0.ts), $0.value) })

        VStack(spacing: 8) {
            Text("Daily Trend").font(.headline)
            let maxCost = max(filteredBalance.map(\.value).max() ?? 1, snap.subDaily)
            let maxLines = max(filteredCode.map { Double(max($0.added, $0.deleted)) }.max() ?? 1, 1)
            let codeScale = maxCost > 0 ? maxLines / maxCost : 1.0

            if filteredStats.isEmpty && filteredCode.isEmpty {
                Text("No data").font(.caption).foregroundColor(.secondary)
            } else {
                Chart {
                    ForEach(filteredStats, id: \.ts) { s in
                        let d = Date(timeIntervalSince1970: s.ts)
                        BarMark(x: .value("Date", d, unit: .day), y: .value("Spend", (balanceMap[d] ?? 0) * barProgress))
                            .foregroundStyle(Color.green)
                    }
                    ForEach(filteredStats, id: \.ts) { s in
                        let d = Date(timeIntervalSince1970: s.ts)
                        BarMark(x: .value("Date", d, unit: .day), y: .value("Spend", snap.subDaily * barProgress))
                            .foregroundStyle(Color.green.opacity(0.4))
                    }
                    ForEach(filteredCode, id: \.ts) { c in
                        let d = Date(timeIntervalSince1970: c.ts)
                        BarMark(x: .value("Date", d, unit: .day), y: .value("Lines", Double(c.added) * codeScale * barProgress))
                            .foregroundStyle(Color.red.opacity(0.6))
                    }
                    ForEach(filteredCode, id: \.ts) { c in
                        let d = Date(timeIntervalSince1970: c.ts)
                        BarMark(x: .value("Date", d, unit: .day), y: .value("Lines", Double(c.deleted) * codeScale * barProgress))
                            .foregroundStyle(Color.red.opacity(0.3))
                    }
                }
                .chartYScale(domain: 0...maxCost)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic) { v in
                        AxisGridLine().foregroundStyle(.gray.opacity(0.2))
                        if let d = v.as(Double.self) { AxisValueLabel("$\(String(format: "%.0f", d))") }
                    }
                    AxisMarks(position: .trailing, values: .automatic) { v in
                        AxisGridLine().foregroundStyle(.gray.opacity(0.1))
                        if let d = v.as(Double.self) {
                            AxisValueLabel("\(Int(d / codeScale))")
                        }
                    }
                }
                .frame(height: 200)
                HStack(spacing: 12) {
                    HStack(spacing: 2) { RoundedRectangle(cornerRadius: 1).fill(.green).frame(width: 8, height: 8); Text("API $").font(.caption2) }
                    HStack(spacing: 2) { RoundedRectangle(cornerRadius: 1).fill(.green.opacity(0.4)).frame(width: 8, height: 8); Text("Sub").font(.caption2) }
                    HStack(spacing: 2) { RoundedRectangle(cornerRadius: 1).fill(.red.opacity(0.6)).frame(width: 8, height: 8); Text("Added").font(.caption2) }
                    HStack(spacing: 2) { RoundedRectangle(cornerRadius: 1).fill(.red.opacity(0.3)).frame(width: 8, height: 8); Text("Deleted").font(.caption2) }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func statCard(_ label: String, value: String, color: Color = .primary) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.caption).fontWeight(.semibold).foregroundStyle(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }

    private func tokenShort(_ n: Int) -> String {
        if n >= 1_000_000 { return "\(n / 1_000_000)M" }
        if n >= 1000 { return "\(n / 1000)K" }
        return "\(n)"
    }
}

enum TimeRange: Hashable {
    case today, week, days30
    var days: Int {
        switch self {
        case .today: return 1
        case .week:
            let cal = Calendar.current
            var monCal = cal; monCal.firstWeekday = 2
            let monday = monCal.date(from: monCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
            return cal.dateComponents([.day], from: monday, to: cal.startOfDay(for: Date())).day! + 1
        case .days30: return 30
        }
    }
    var label: String { switch self { case .today: "Today"; case .week: "This Week"; case .days30: "30 Days" } }
}
