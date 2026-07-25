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

    // MARK: - systemSmall (Home Screen 2×2)

    var systemSmallView: some View {
        let todayPct = min(entry.todayCost / entry.dailyRate, 1.0)
        let todayLaps = Int(entry.todayCost / entry.dailyRate)
        let weekPct = min(entry.weekCost / entry.weeklyAvg, 1.0)
        let monthPct = min(entry.monthSoFar / entry.monthProjected, 1.0)

        return ZStack {
            ActivityRing(progress: monthPct, thickness: 5, color: .marsGreenLight)
                .frame(width: 120, height: 120)
            ActivityRing(progress: weekPct.truncatingRemainder(dividingBy: 1),
                         thickness: 5, color: .marsGreen)
                .frame(width: 108, height: 108)
            ActivityRing(progress: todayPct.truncatingRemainder(dividingBy: 1),
                         thickness: 5, color: .deepRed)
                .frame(width: 96, height: 96)
            VStack(spacing: 1) {
                Text(formatUSD(entry.todayCost))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5).lineLimit(1)
                if todayLaps > 0 {
                    Text("\(todayLaps)× daily avg")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - systemMedium (Home Screen 4×2)

    var systemMediumView: some View {
        let todayPct = min(entry.todayCost / entry.dailyRate, 1.0)
        let weekPct = min(entry.weekCost / entry.weeklyAvg, 1.0)
        let monthPct = min(entry.monthSoFar / entry.monthProjected, 1.0)

        return HStack(spacing: 16) {
            ZStack {
                ActivityRing(progress: monthPct, thickness: 5, color: .marsGreenLight)
                    .frame(width: 100, height: 100)
                ActivityRing(progress: weekPct.truncatingRemainder(dividingBy: 1),
                             thickness: 5, color: .marsGreen)
                    .frame(width: 88, height: 88)
                ActivityRing(progress: todayPct.truncatingRemainder(dividingBy: 1),
                             thickness: 5, color: .deepRed)
                    .frame(width: 76, height: 76)
                Text(formatUSD(entry.todayCost))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }

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

    // MARK: - accessoryCircular (Lock Screen circle)

    var accessoryCircularView: some View {
        let todayPct = min(entry.todayCost / entry.dailyRate, 1.0)
        let weekPct = min(entry.weekCost / entry.weeklyAvg, 1.0)
        let monthPct = min(entry.monthSoFar / entry.monthProjected, 1.0)

        return ZStack {
            ActivityRing(progress: monthPct, thickness: 3, color: .marsGreenLight)
                .frame(width: 56, height: 56)
            ActivityRing(progress: weekPct.truncatingRemainder(dividingBy: 1),
                         thickness: 3, color: .marsGreen)
                .frame(width: 48, height: 48)
            ActivityRing(progress: todayPct.truncatingRemainder(dividingBy: 1),
                         thickness: 3, color: .deepRed)
                .frame(width: 40, height: 40)
        }
    }

    // MARK: - accessoryRectangular (Lock Screen bar)

    var accessoryRectangularView: some View {
        let todayPct = min(entry.todayCost / entry.dailyRate, 1.0)
        let weekPct = min(entry.weekCost / entry.weeklyAvg, 1.0)
        let monthPct = min(entry.monthSoFar / entry.monthProjected, 1.0)

        return HStack(spacing: 8) {
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

    // MARK: - Helpers

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
