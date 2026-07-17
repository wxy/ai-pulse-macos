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

    private var filteredStats: [TrendPoint] {
        guard !snap.dailyStats.isEmpty else { return [] }
        let days = timeRange.days
        let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!
        return snap.dailyStats.filter { Date(timeIntervalSince1970: $0.ts) >= cutoff }
    }

    private var filteredCode: [TrendPoint] {
        guard !snap.codeChanges.isEmpty else { return [] }
        let days = timeRange.days
        let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!
        return snap.codeChanges.filter { Date(timeIntervalSince1970: $0.ts) >= cutoff }
    }

    private var filteredBalance: [TrendPoint] {
        guard !snap.balanceDaily.isEmpty else { return [] }
        let days = timeRange.days
        let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!
        return snap.balanceDaily.filter { Date(timeIntervalSince1970: $0.ts) >= cutoff }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Tab picker
                Picker("", selection: $timeRange) {
                    Text("Today").tag(TimeRange.today)
                    Text("Week").tag(TimeRange.week)
                    Text("30d").tag(TimeRange.days30)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: timeRange) { _, _ in
                    barProgress = 0
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { barProgress = 1 }
                }

                // Big total
                VStack(spacing: 4) {
                    Text("$\(String(format: "%.2f", totalCost))")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.red)
                        .scaleEffect(0.8 + 0.2 * barProgress)
                        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: barProgress)

                    HStack(spacing: 6) {
                        Text("\(timeRange.label) Total")
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
                    // Left: Sub vs API donut
                    if apiSpend + subTotal > 0.001 {
                        subVsApiDonut
                    } else {
                        emptyDonut("Sub vs API")
                    }

                    // Center stats
                    VStack(spacing: 6) {
                        statCard("Net Lines", value: "\(filteredStats.reduce(0) { $0 + $1.netLines })")
                        statCard("Added", value: "+\(filteredCode.reduce(0) { $0 + $1.added })", color: .green)
                        statCard("Deleted", value: "-\(filteredCode.reduce(0) { $0 + $1.deleted })", color: .red)
                        if timeRange == .today {
                            statCard("Calls", value: "\(snap.todayCalls)")
                            statCard("Tokens", value: tokenShort(snap.todayTokens))
                        }
                    }
                    .frame(width: 90)

                    // Right: Provider donut
                    if !snap.providerBreakdown.isEmpty {
                        providerDonut
                    } else {
                        emptyDonut("Providers")
                    }
                }

                // Tool breakdown
                if !snap.toolBreakdown.isEmpty {
                    toolBars
                }

                // Repo list
                if !snap.topRepos.isEmpty {
                    repoList
                }

                // Trend chart (week/30d)
                if timeRange != .today && !filteredStats.isEmpty {
                    trendChart
                }

                // Last updated
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
        VStack(spacing: 4) {
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
            .chartLegend(.hidden)
            .frame(width: 90, height: 90)
            Text("Sub vs API").font(.caption2).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var providerDonut: some View {
        VStack(spacing: 4) {
            Chart {
                ForEach(snap.providerBreakdown, id: \.providerId) { p in
                    SectorMark(angle: .value("Cost", p.cost), innerRadius: .ratio(0.5))
                        .foregroundStyle(by: .value("Name", p.name))
                }
            }
            .chartLegend(.hidden)
            .frame(width: 90, height: 90)
            Text("Providers").font(.caption2).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func emptyDonut(_ label: String) -> some View {
        VStack(spacing: 4) {
            Circle().stroke(.secondary.opacity(0.15), lineWidth: 10)
                .frame(width: 90, height: 90)
                .overlay { Text("$0").font(.caption2).foregroundColor(.secondary) }
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: - Tool & Repo

    @ViewBuilder
    private var toolBars: some View {
        let maxCost = snap.toolBreakdown.map(\.cost).max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            Text("By Tool").font(.caption).foregroundColor(.secondary)
            ForEach(snap.toolBreakdown.prefix(5), id: \.name) { tool in
                HStack {
                    Text(tool.name).font(.caption).frame(width: 80, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.green.opacity(0.6))
                            .frame(width: max(geo.size.width * CGFloat(tool.cost / maxCost), 2))
                    }
                    .frame(height: 8)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("By Repo").font(.caption).foregroundColor(.secondary)
            ForEach(snap.topRepos.prefix(6), id: \.name) { repo in
                HStack {
                    Text(repo.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text("$\(String(format: "%.2f", repo.cost))").font(.caption2).monospacedDigit()
                }
                HStack(spacing: 4) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.green.opacity(0.5))
                            .frame(width: max(geo.size.width * CGFloat(repo.cost / maxCost), 2))
                    }
                    .frame(height: 4)
                    Text("CPL $\(String(format: "%.2f", repo.cpl))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Trend

    @ViewBuilder
    private var trendChart: some View {
        let balanceMap = Dictionary(uniqueKeysWithValues: filteredBalance.map { (Date(timeIntervalSince1970: $0.ts), $0.value) })
        VStack(spacing: 8) {
            Text("Daily Trend").font(.headline)
            Chart {
                ForEach(filteredStats, id: \.ts) { s in
                    let d = Date(timeIntervalSince1970: s.ts)
                    BarMark(x: .value("Date", d, unit: .day), y: .value("API", (balanceMap[d] ?? 0) * barProgress))
                        .foregroundStyle(Color.green)
                    BarMark(x: .value("Date", d, unit: .day), y: .value("Sub", (snap.subDaily) * barProgress))
                        .foregroundStyle(Color.green.opacity(0.4))
                }
                ForEach(filteredCode, id: \.ts) { c in
                    let d = Date(timeIntervalSince1970: c.ts)
                    BarMark(x: .value("Date", d, unit: .day), y: .value("Added", Double(c.added) * barProgress))
                        .foregroundStyle(Color.red.opacity(0.6))
                    BarMark(x: .value("Date", d, unit: .day), y: .value("Deleted", Double(c.deleted) * barProgress))
                        .foregroundStyle(Color.red.opacity(0.3))
                }
            }
            .frame(height: 200)
            .chartYAxis {
                AxisMarks(position: .leading)
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
    var days: Int { switch self { case .today: 1; case .week: 7; case .days30: 30 } }
    var label: String {
        switch self { case .today: "Today"; case .week: "This Week"; case .days30: "30 Days" }
    }
}

struct StatRow: View {
    let label: String; let value: String
    var body: some View {
        VStack(spacing: 0) {
            Text(value).font(.caption).fontWeight(.semibold)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }
}
