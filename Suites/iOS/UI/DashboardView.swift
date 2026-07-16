import SwiftUI
import Charts

/// Simplified Dashboard for iOS/iPadOS — robot-face layout, single screen.
struct DashboardView: View {
    @EnvironmentObject var cloudData: CloudDataService
    @State private var timeRange = TimeRange.today
    @State private var barProgress: CGFloat = 0

    private var filteredStats: [DailyStat] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -(timeRange.days - 1),
            to: Calendar.current.startOfDay(for: Date()))!
        return cloudData.dailyStats.filter { $0.date >= cutoff }
    }

    private var totalCost: Double {
        filteredStats.reduce(0) { $0 + $1.cost }
    }

    private var totalCalls: Int {
        filteredStats.reduce(0) { $0 + $1.calls }
    }

    private var totalTokens: Int {
        filteredStats.reduce(0) { $0 + $1.tokens }
    }

    private var netLines: Int {
        filteredStats.reduce(0) { $0 + $1.netLines }
    }

    /// Top repos by cost (from code changes + provider attribution).
    private var topRepos: [(name: String, cost: Double)] {
        // Simplified: aggregate by provider as proxy for repo attribution.
        var totals: [String: Double] = [:]
        let cutoff = Calendar.current.date(byAdding: .day, value: -(timeRange.days - 1),
            to: Calendar.current.startOfDay(for: Date()))!
        for pc in cloudData.providerCosts where pc.date >= cutoff {
            totals[pc.providerId, default: 0] += pc.cost
        }
        return totals.map { (name: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
            .prefix(3).map { $0 }
    }

    var body: some View {
        VStack(spacing: 10) {
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
            Text("$\(String(format: "%.2f", totalCost))")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.red)
                .scaleEffect(0.8 + 0.2 * barProgress)
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: barProgress)

            // Robot face row: donut | stats | donut
            HStack(alignment: .top, spacing: 6) {
                // Left donut: API spend by provider
                VStack(spacing: 4) {
                    if topRepos.isEmpty {
                        Circle()
                            .stroke(.secondary.opacity(0.15), lineWidth: 10)
                            .frame(width: 80, height: 80)
                            .overlay { Text("$0").font(.caption2).foregroundColor(.secondary) }
                    } else {
                        Chart {
                            ForEach(topRepos, id: \.name) { repo in
                                SectorMark(angle: .value("Cost", repo.cost),
                                           innerRadius: .ratio(0.5))
                                    .foregroundStyle(by: .value("Repo", repo.name))
                            }
                        }
                        .chartLegend(.hidden)
                        .frame(width: 80, height: 80)
                    }
                    Text("Providers").font(.caption2).foregroundColor(.secondary)
                }

                // Center stats
                VStack(spacing: 4) {
                    StatRow(label: "Net Lines", value: "\(netLines)")
                    StatRow(label: "Calls", value: "\(totalCalls)")
                    StatRow(label: "Tokens", value: tokenShort(totalTokens))
                }
                .frame(width: 90)
                .scaleEffect(0.8 + 0.2 * barProgress)

                // Right donut: subscription vs API
                VStack(spacing: 4) {
                    Circle()
                        .stroke(.secondary.opacity(0.15), lineWidth: 10)
                        .frame(width: 80, height: 80)
                        .overlay { Text("Sub").font(.caption2).foregroundColor(.secondary) }
                    Text("Subs").font(.caption2).foregroundColor(.secondary)
                }
            }

            // Top repos/tools
            if !topRepos.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top Providers").font(.caption).foregroundColor(.secondary)
                    ForEach(topRepos, id: \.name) { repo in
                        HStack {
                            Text(repo.name).font(.caption)
                            Spacer()
                            Text("$\(String(format: "%.2f", repo.cost))")
                                .font(.caption).monospacedDigit()
                        }
                    }
                }
                .padding(.horizontal)
            }

            Spacer()
        }
        .padding(.top)
        .onAppear { barProgress = 1 }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { try? await cloudData.fetchAll(days: timeRange.days) }
        }
    }

    private func tokenShort(_ n: Int) -> String {
        if n >= 1000 { return "\(n / 1000)K" }
        return "\(n)"
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 0) {
            Text(value).font(.caption).fontWeight(.semibold)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }
}

enum TimeRange: Hashable {
    case today, week, days30

    var days: Int {
        switch self {
        case .today:  return 1
        case .week:   return 7
        case .days30: return 30
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(CloudDataService.shared)
}
