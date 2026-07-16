import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject var cloudData: CloudDataService
    @State private var timeRange = TimeRange.today
    @State private var barProgress: CGFloat = 0

    private var totalCost: Double {
        switch timeRange {
        case .today:  return cloudData.todayCost
        case .week:   return cloudData.weekCost
        case .days30: return cloudData.monthCost
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
            .onChange(of: timeRange) { _, _ in
                barProgress = 0
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { barProgress = 1 }
            }

            Text("$\(String(format: "%.2f", totalCost))")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.red)
                .scaleEffect(0.8 + 0.2 * barProgress)

            HStack(alignment: .top, spacing: 6) {
                providerDonut
                noseStatCards
                subDonut
            }

            if !cloudData.providerBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top Providers").font(.caption).foregroundColor(.secondary)
                    ForEach(cloudData.providerBreakdown.prefix(3), id: \.providerId) { p in
                        HStack {
                            Text(p.name).font(.caption)
                            Spacer()
                            Text("$\(String(format: "%.2f", p.cost))").font(.caption).monospacedDigit()
                        }
                    }
                }
                .padding(.horizontal)
            }

            Spacer()
        }
        .padding(.top)
        .onAppear {
            barProgress = 1
            Task { try? await cloudData.fetchAll() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { try? await cloudData.fetchAll() }
        }
    }

    @ViewBuilder
    private var providerDonut: some View {
        VStack(spacing: 4) {
            if cloudData.providerBreakdown.isEmpty {
                Circle().stroke(.secondary.opacity(0.15), lineWidth: 10)
                    .frame(width: 80, height: 80)
                    .overlay { Text("$0").font(.caption2).foregroundColor(.secondary) }
            } else {
                Chart {
                    ForEach(cloudData.providerBreakdown, id: \.providerId) { p in
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
                .overlay { Text("Sub").font(.caption2).foregroundColor(.secondary) }
            Text("Subs").font(.caption2).foregroundColor(.secondary)
        }
    }

    private var noseStatCards: some View {
        VStack(spacing: 4) {
            StatRow(label: "Providers", value: "\(cloudData.providerBreakdown.count)")
            StatRow(label: "Today", value: "$\(String(format: "%.2f", cloudData.todayCost))")
            StatRow(label: "Week", value: "$\(String(format: "%.2f", cloudData.weekCost))")
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
