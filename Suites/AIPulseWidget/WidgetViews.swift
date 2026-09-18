import SwiftUI
import WidgetKit
import AIPulseShared

private enum WidgetCopy {
    static func text(_ simplifiedChinese: String, _ english: String) -> String {
        let language = Locale.preferredLanguages.first ?? "en"
        if language.hasPrefix("zh-Hant") {
            return simplifiedChinese.applyingTransform(StringTransform("Hans-Hant"), reverse: false)
                ?? simplifiedChinese
        }
        return language.hasPrefix("zh") ? simplifiedChinese : english
    }
}

private struct WidgetActivityRing: View {
    let ratio: Double?
    let color: Color
    let trackColor: Color
    let width: CGFloat
    var allowsLaps = true

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let radius = (diameter - width) / 2
            let value = ratio.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let arc = WatchDashboardData.remainingArc(value ?? 0)
            ZStack {
                Circle()
                    .stroke(value == nil ? Color.gray.opacity(0.24) : trackColor,
                            lineWidth: width)
                if let value {
                    if value >= 1 {
                        Circle().stroke(color.opacity(allowsLaps ? 0.48 : 1), lineWidth: width)
                    }
                    if arc > 0 {
                        Circle()
                            .trim(from: 0, to: arc)
                            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    if value >= 1 {
                        let angle = (arc * 360 - 90) * Double.pi / 180
                        Circle()
                            .fill(color)
                            .frame(width: width, height: width)
                            .position(x: radius + radius * cos(angle),
                                      y: radius + radius * sin(angle))
                    }
                }
            }
            .frame(width: diameter - width, height: diameter - width)
            .position(x: diameter / 2, y: diameter / 2)
        }
        .accessibilityHidden(true)
    }
}

struct AIPulseWidgetEntryView: View {
    let entry: WidgetEntry

    private let tokenColor = Color.deepRed
    private let tokenTrackColor = Color.deepRed2.opacity(0.22)
    private let lineColor = Color.marsGreen
    private let lineTrackColor = Color.marsGreenLight.opacity(0.22)
    private let activityColor = Color(red: 212 / 255, green: 163 / 255, blue: 38 / 255)
    private let activityTrackColor = Color(red: 226 / 255, green: 204 / 255, blue: 126 / 255).opacity(0.20)

    private func text(_ simplifiedChinese: String, _ english: String) -> String {
        WidgetCopy.text(simplifiedChinese, english)
    }

    private var todayTokens: Double? {
        guard let snapshot = entry.todaySnapshot,
              !snapshot.readFailures.contains("toolUsage"),
              !snapshot.readFailures.contains("dashboardUsageStats") else { return nil }
        return Double(snapshot.todayTokens)
    }

    private var todayLines: Double? {
        guard let snapshot = entry.todaySnapshot,
              !snapshot.readFailures.contains("repositoryCode") else { return nil }
        return snapshot.topRepos.reduce(0) { $0 + Double($1.added) + Double($1.deleted) }
    }

    private var tokenRatio: Double? {
        WatchDashboardData.ratio(
            value: todayTokens,
            baseline: WatchDashboardData.baseline(entry.historySnapshot, tokens: true, now: entry.date)
        )
    }

    private var lineRatio: Double? {
        WatchDashboardData.ratio(
            value: todayLines,
            baseline: WatchDashboardData.baseline(entry.historySnapshot, tokens: false, now: entry.date)
        )
    }

    private var currentPulse: PulseSnapshot? {
        entry.pulseEnvelope?.currentPulse(asOf: entry.date)
    }

    private var summaryIsStale: Bool {
        entry.todaySnapshot != nil
            && !WatchDashboardData.isSummaryFresh(entry.todaySnapshot, now: entry.date)
    }

    private var status: String? {
        guard let snapshot = entry.todaySnapshot else { return text("暂无数据", "No data") }
        guard summaryIsStale else { return nil }
        return text("缓存 ", "Cached ")
            + snapshot.updatedAt.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        GeometryReader { geometry in
            let edge = min(geometry.size.width, geometry.size.height)
            let side = edge * 0.82
            let thickness = side * 13 / 184
            ZStack {
                Color.black
                ringCluster(side: side, thickness: thickness)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2 + 2)
                cornerFacts
                if let status {
                    Text(status)
                        .font(.system(size: 7))
                        .foregroundStyle(summaryIsStale ? activityColor : secondaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 6)
                }
            }
        }
        .containerBackground(Color.black, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func ringCluster(side: CGFloat, thickness: CGFloat) -> some View {
        ZStack {
            WidgetActivityRing(ratio: tokenRatio, color: tokenColor,
                               trackColor: tokenTrackColor, width: thickness)
                .opacity(summaryIsStale ? 0.55 : 1)
            WidgetActivityRing(ratio: lineRatio, color: lineColor,
                               trackColor: lineTrackColor, width: thickness)
                .padding(side * 16 / 184)
                .opacity(summaryIsStale ? 0.55 : 1)
            WidgetActivityRing(
                ratio: WatchDashboardData.intensity(currentPulse, now: entry.date),
                color: activityColor, trackColor: activityTrackColor,
                width: thickness, allowsLaps: false
            )
            .padding(side * 32 / 184)
            centerFact
        }
        .frame(width: side, height: side)
    }

    private var centerFact: some View {
        VStack(spacing: 3) {
            Text(text("当前强度", "Current activity"))
                .font(.system(size: 8))
                .foregroundStyle(secondaryTextColor)
            Text(pulseText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let date = entry.pulseEnvelope?.pulse?.asOf {
                Text(text("观测于 ", "Observed ")
                     + date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 7))
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
            } else {
                Text("—").font(.system(size: 7)).foregroundStyle(secondaryTextColor)
            }
        }
        .frame(width: 68)
    }

    private var pulseText: String {
        if let currentPulse { return I18n.pulseTier(currentPulse.tier) }
        return entry.pulseEnvelope?.pulse == nil
            ? text("暂无观测", "No observation")
            : text("观测已过期", "Expired")
    }

    private var cornerFacts: some View {
        VStack {
            HStack(alignment: .top) {
                corner(text("今日词元", "Today tokens"), count(todayTokens),
                       color: tokenColor, alignment: .leading, numberFirst: false)
                Spacer()
                corner(text("今日行数", "Today lines"), count(todayLines),
                       color: lineColor, alignment: .trailing, numberFirst: false)
            }
            Spacer()
            HStack(alignment: .bottom) {
                corner(text("词元 / 平常", "Tokens / usual"), multiple(tokenRatio),
                       color: tokenColor, alignment: .leading, numberFirst: true)
                Spacer()
                corner(text("行数 / 平常", "Lines / usual"), multiple(lineRatio),
                       color: lineColor, alignment: .trailing, numberFirst: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .opacity(summaryIsStale ? 0.55 : 1)
    }

    private func corner(_ label: String, _ value: String, color: Color,
                        alignment: HorizontalAlignment, numberFirst: Bool) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            if numberFirst {
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            Text(label)
                .font(.system(size: 7))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
            if !numberFirst {
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
    }

    private func count(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0,
              value < Double(Int64.max) else { return "N/A" }
        return ChartMath.compactCount(Int64(value))
    }

    private func multiple(_ value: Double?) -> String {
        guard let value else { return "N/A" }
        return String(format: "%.1f×", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private var secondaryTextColor: Color { Color.white.opacity(0.62) }

    private var accessibilitySummary: String {
        [
            "\(text("今日词元", "Today tokens")): \(count(todayTokens))",
            "\(text("词元相对平常", "Tokens versus usual")): \(multiple(tokenRatio))",
            "\(text("今日行数", "Today lines")): \(count(todayLines))",
            "\(text("行数相对平常", "Lines versus usual")): \(multiple(lineRatio))",
            "\(text("当前强度", "Current activity")): \(pulseText)",
            status
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}