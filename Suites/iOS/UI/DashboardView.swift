import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject var cloudData: CloudDataService
    @State private var timeRange = TimeRange.today

    private var snap: DashboardSnapshot { cloudData.snapshot ?? DashboardSnapshot() }

    private var totalCost: Double {
        switch timeRange {
        case .today:  return snap.todayCost
        case .week:   return snap.weekCost
        case .days30: return snap.monthCost
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $timeRange) {
                Text("Today").tag(TimeRange.today)
                Text("Week").tag(TimeRange.week)
                Text("30d").tag(TimeRange.days30)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Text("$\(String(format: "%.2f", totalCost))")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.red)

            HStack(alignment: .top, spacing: 6) {
                providerDonut
                noseStatCards
                subDonut
            }

            if !snap.providerBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top Providers").font(.caption).foregroundColor(.secondary)
                    ForEach(snap.providerBreakdown.prefix(3), id: \.providerId) { p in
                        HStack {
                            Text(p.name).font(.caption)
                            Spacer()
                            Text("$\(String(format: "%.2f", p.cost))").font(.caption).monospacedDigit()
                        }
                    }
                }
                .padding(.horizontal)
            }

            // Last sync time
            if let updated = cloudData.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption2).foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.top)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { try? await cloudData.fetchSnapshot() }
        }
    }

    @ViewBuilder
    private var providerDonut: some View {
        VStack(spacing: 4) {
            if snap.providerBreakdown.isEmpty {
                Circle().stroke(.secondary.opacity(0.15), lineWidth: 10)
                    .frame(width: 80, height: 80)
                    .overlay { Text("$0").font(.caption2).foregroundColor(.secondary) }
            } else {
                Chart {
                    ForEach(snap.providerBreakdown, id: \.providerId) { p in
                        SectorMark(angle: .value("Cost", p.cost), innerRadius: .ratio(0.5))
                            .foregroundStyle(by: .value("Name", p.name))
                    }
                }
                .chartLegend(.hidden)
                .frame(width: 80, height: 80)
            }
            Text("Providers").font(.caption2).foregroundColor(.secondary)
        }
    }

    private var subDonut: some View {
        VStack(spacing: 4) {
            Circle().stroke(.secondary.opacity(0.15), lineWidth: 10)
                .frame(width: 80, height: 80)
                .overlay { Text("$\(String(format: "%.2f", snap.subDaily))").font(.caption2).foregroundColor(.secondary) }
            Text("Subs/day").font(.caption2).foregroundColor(.secondary)
        }
    }

    private var noseStatCards: some View {
        VStack(spacing: 4) {
            StatRow(label: "Net Lines", value: "\(snap.dailyStats.reduce(0) { $0 + $1.calls })")
            StatRow(label: "Providers", value: "\(snap.providerBreakdown.count)")
            StatRow(label: "Tools", value: "\(snap.toolBreakdown.count)")
        }
        .frame(width: 90)
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

enum TimeRange: Hashable {
    case today, week, days30
    var days: Int { switch self { case .today: 1; case .week: 7; case .days30: 30 } }
}
