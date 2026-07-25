import SwiftUI
import WidgetKit

struct AIPulseWidgetEntryView: View {
    var entry: WidgetEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            systemSmallView
        case .systemMedium:
            systemMediumView
        case .accessoryCircular:
            accessoryCircularView
        case .accessoryRectangular:
            accessoryRectangularView
        default:
            systemSmallView
        }
    }

    // MARK: - Helpers (same compute pattern as watchOS SpendView)

    private var dailyRate: Double { max(entry.dailyRate, 0.01) }
    private var weeklyAvg: Double { dailyRate * 7 }
    private var todayPct: Double { entry.todayCost / dailyRate }
    private var todayLaps: Int { Int(todayPct) }
    private var weekPct: Double { entry.weekCost / weeklyAvg }
    private var monthPct: Double {
        guard entry.monthProjected > 0.001 else { return 0 }
        return min(entry.monthSoFar / entry.monthProjected, 1.0)
    }
    private var yesterdayDelta: Double {
        entry.yesterdaySpend > 0.001 ? (entry.todayCost - entry.yesterdaySpend) / entry.yesterdaySpend : 0
    }

    // MARK: - systemSmall

    var systemSmallView: some View {
        // anchor = outerRing + 8 (same formula as watchOS: 160+8=168)
        let outer: CGFloat = 116
        let off: CGFloat = 7

        return ZStack {
            Rectangle().fill(.clear).frame(width: outer + 8, height: outer + 8)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Today").font(.system(size: 8)).foregroundColor(.secondary)
                        Text("\(todayLaps)×").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundColor(.deepRed)
                    }.offset(x: -off, y: -off)
                }
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Week").font(.system(size: 8)).foregroundColor(.secondary)
                        Text(formatUSD(entry.weekCost)).font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundColor(.marsGreen)
                    }.offset(x: off, y: -off)
                }
                .overlay(alignment: .bottomLeading) {
                    if entry.yesterdaySpend > 0.001 {
                        Text(yesterdayDelta > 0 ? "↑\(Int(yesterdayDelta * 100))%" : "↓\(Int(-yesterdayDelta * 100))%")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundColor(yesterdayDelta > 0 ? .deepRed : .marsGreen)
                            .offset(x: -off, y: off)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("30 Days").font(.system(size: 8)).foregroundColor(.secondary)
                        Text(formatUSD(entry.monthCost)).font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundColor(.marsGreenLight)
                    }.offset(x: off, y: off)
                }

            ActivityRing(progress: monthPct, thickness: 4, color: .marsGreenLight)
                .frame(width: outer, height: outer)
            ActivityRing(progress: weekPct.truncatingRemainder(dividingBy: 1),
                         thickness: 4, color: .marsGreen)
                .frame(width: outer - 12, height: outer - 12)
            ActivityRing(progress: todayPct.truncatingRemainder(dividingBy: 1),
                         thickness: 4, color: .deepRed)
                .frame(width: outer - 24, height: outer - 24)

            VStack(spacing: 1) {
                Text(formatUSD(entry.todayCost))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5).lineLimit(1)
                Text(entry.updatedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - systemMedium

    var systemMediumView: some View {
        // anchor = outerRing + 8, offset = 8 (exact watchOS formula: 160+8=168, offset±8)
        let outer: CGFloat = 152
        let off: CGFloat = 8

        return HStack(spacing: 24) {
            ZStack {
                Rectangle().fill(.clear).frame(width: outer + 8, height: outer + 8)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Today").font(.system(size: 10)).foregroundColor(.secondary)
                            Text("\(todayLaps)×").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.deepRed)
                        }.offset(x: -off, y: -off)
                    }
                    .overlay(alignment: .topTrailing) {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("Week").font(.system(size: 10)).foregroundColor(.secondary)
                            Text(formatUSD(entry.weekCost)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.marsGreen)
                        }.offset(x: off, y: -off)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if entry.yesterdaySpend > 0.001 {
                            Text(yesterdayDelta > 0 ? "↑\(Int(yesterdayDelta * 100))%" : "↓\(Int(-yesterdayDelta * 100))%")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(yesterdayDelta > 0 ? .deepRed : .marsGreen)
                                .offset(x: -off, y: off)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("30 Days").font(.system(size: 10)).foregroundColor(.secondary)
                            Text(formatUSD(entry.monthCost)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.marsGreenLight)
                        }.offset(x: off, y: off)
                    }

                ActivityRing(progress: monthPct, thickness: 5, color: .marsGreenLight)
                    .frame(width: outer, height: outer)
                ActivityRing(progress: weekPct.truncatingRemainder(dividingBy: 1),
                             thickness: 5, color: .marsGreen)
                    .frame(width: outer - 16, height: outer - 16)
                ActivityRing(progress: todayPct.truncatingRemainder(dividingBy: 1),
                             thickness: 5, color: .deepRed)
                    .frame(width: outer - 32, height: outer - 32)

                VStack(spacing: 1) {
                    Text(formatUSD(entry.todayCost))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5).lineLimit(1)
                    Text(entry.updatedAt, format: .dateTime.hour().minute())
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            // Text breakdown on the right
            VStack(alignment: .leading, spacing: 8) {
                Text("AI Pulse")
                    .font(.caption).foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(Color.deepRed).frame(width: 6, height: 6)
                        Text("Today:").font(.caption2)
                        Text(formatUSD(entry.todayCost))
                            .font(.caption2).fontWeight(.semibold)
                    }
                    HStack {
                        Circle().fill(Color.marsGreen).frame(width: 6, height: 6)
                        Text("Week:").font(.caption2)
                        Text(formatUSD(entry.weekCost))
                            .font(.caption2).fontWeight(.semibold)
                    }
                    HStack {
                        Circle().fill(Color.marsGreenLight).frame(width: 6, height: 6)
                        Text("30d:").font(.caption2)
                        Text(formatUSD(entry.monthCost))
                            .font(.caption2).fontWeight(.semibold)
                    }
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - accessoryCircular (Lock Screen)

    var accessoryCircularView: some View {
        ZStack {
            ActivityRing(progress: monthPct, thickness: 3, color: .marsGreenLight)
                .frame(width: 52, height: 52)
            ActivityRing(progress: weekPct.truncatingRemainder(dividingBy: 1),
                         thickness: 3, color: .marsGreen)
                .frame(width: 44, height: 44)
            ActivityRing(progress: todayPct.truncatingRemainder(dividingBy: 1),
                         thickness: 3, color: .deepRed)
                .frame(width: 36, height: 36)
        }
    }

    // MARK: - accessoryRectangular (Lock Screen)

    var accessoryRectangularView: some View {
        HStack(spacing: 8) {
            ZStack {
                ActivityRing(progress: monthPct, thickness: 3, color: .marsGreenLight)
                    .frame(width: 40, height: 40)
                ActivityRing(progress: weekPct.truncatingRemainder(dividingBy: 1),
                             thickness: 3, color: .marsGreen)
                    .frame(width: 34, height: 34)
                ActivityRing(progress: todayPct.truncatingRemainder(dividingBy: 1),
                             thickness: 3, color: .deepRed)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(formatUSD(entry.todayCost))
                    .font(.headline).bold()
                Text("AI Pulse")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Formatting

    private static let usdFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    private func formatUSD(_ v: Double) -> String {
        if v >= 100 { Self.usdFormatter.maximumFractionDigits = 0 }
        else { Self.usdFormatter.maximumFractionDigits = 2 }
        return Self.usdFormatter.string(from: NSNumber(value: v)) ?? "$0"
    }
}
