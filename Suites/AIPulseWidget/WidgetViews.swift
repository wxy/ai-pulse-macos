import SwiftUI
import WidgetKit
import AIPulseShared

private enum WidgetCopy {
    static func text(_ simplifiedChinese: String, _ english: String) -> String {
        let language = Locale.preferredLanguages.first ?? "en"
        let localized = Bundle.main.localizedString(forKey: english, value: english, table: nil)
        if localized != english || language.hasPrefix("en") { return localized }
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.showsWidgetContainerBackground) private var showsContainerBackground
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: WidgetEntry

    private let tokenColor = Color.deepRed
    private let lineColor = Color.marsGreen
    private let activityColor = Color(red: 212 / 255, green: 163 / 255, blue: 38 / 255)

    private var isFullColor: Bool { renderingMode == .fullColor }
    private var tokenTrackColor: Color {
        isFullColor
            ? Color.deepRed2.opacity(colorScheme == .dark ? 0.28 : 0.24)
            : Color.primary.opacity(0.16)
    }
    private var lineTrackColor: Color {
        isFullColor
            ? Color.marsGreenLight.opacity(colorScheme == .dark ? 0.30 : 0.26)
            : Color.primary.opacity(0.16)
    }
    private var activityTrackColor: Color {
        isFullColor
            ? Color(red: 226 / 255, green: 204 / 255, blue: 126 / 255)
                .opacity(colorScheme == .dark ? 0.26 : 0.24)
            : Color.primary.opacity(0.16)
    }
    private var widgetBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.045, green: 0.065, blue: 0.055)
            : Color(red: 0.91, green: 0.93, blue: 0.90)
    }

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

    private var latestPulse: PulseSnapshot? {
        entry.pulseEnvelope?.pulse
    }

    private var pulseIsExpired: Bool {
        latestPulse != nil && currentPulse == nil
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
                ringCluster(side: side, thickness: thickness)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2 + 2)
                cornerFacts(in: geometry.size, ringWidth: thickness)
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
        .containerBackground(widgetBackground, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func ringCluster(side: CGFloat, thickness: CGFloat) -> some View {
        ZStack {
            WidgetActivityRing(ratio: tokenRatio, color: tokenColor,
                               trackColor: tokenTrackColor, width: thickness)
                .opacity(summaryIsStale ? 0.55 : 1)
                .widgetAccentable()
            WidgetActivityRing(ratio: lineRatio, color: lineColor,
                               trackColor: lineTrackColor, width: thickness)
                .padding(side * 16 / 184)
                .opacity(summaryIsStale ? 0.55 : 1)
                .widgetAccentable()
            WidgetActivityRing(
                ratio: WatchDashboardData.observedIntensity(latestPulse),
                color: activityColor, trackColor: activityTrackColor,
                width: thickness, allowsLaps: false
            )
            .padding(side * 32 / 184)
            .opacity(pulseIsExpired ? 0.55 : 1)
            .widgetAccentable()
            centerFact
        }
        .frame(width: side, height: side)
    }

    private var centerFact: some View {
        VStack(spacing: 3) {
            Text(text("活动强度", "Activity"))
                .font(.system(size: 8))
                .foregroundStyle(secondaryTextColor)
            Text(pulseText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(primaryTextColor)
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
        guard let latestPulse else { return text("暂无观测", "No observation") }
        return I18n.pulseTier(latestPulse.tier)
    }

    private func cornerFacts(in size: CGSize, ringWidth: CGFloat) -> some View {
        let edge = min(size.width, size.height)
        let diagonalOffset = ringWidth / CGFloat(2).squareRoot()
        let baseInset = max(edge * 0.17, edge * 0.21 - diagonalOffset)
        let inset = max(edge * 0.15, baseInset - ringWidth * 0.20)
        let bottomInset = max(edge * 0.15, inset - ringWidth * 0.15)

        return ZStack {
            corner(text("今日词元", "Today tokens"), count(todayTokens),
                   color: tokenColor, labelFirst: true)
                .rotationEffect(.degrees(-45))
                .position(x: inset, y: inset)
            corner(text("今日行数", "Today lines"), count(todayLines),
                   color: lineColor, labelFirst: true)
                .rotationEffect(.degrees(45))
                .position(x: size.width - inset, y: inset)
            corner(text("词元 / 平常", "Tokens / usual"), multiple(tokenRatio),
                   color: tokenColor, labelFirst: false)
                .rotationEffect(.degrees(45))
                .position(x: bottomInset, y: size.height - bottomInset)
            corner(text("行数 / 平常", "Lines / usual"), multiple(lineRatio),
                   color: lineColor, labelFirst: false)
                .rotationEffect(.degrees(-45))
                .position(x: size.width - bottomInset, y: size.height - bottomInset)
        }
        .frame(width: size.width, height: size.height)
    }

    private func corner(_ label: String, _ value: String, color: Color,
                        labelFirst: Bool) -> some View {
        VStack(spacing: 0) {
            if !labelFirst { cornerValue(value, color: color) }
            Text(label)
                .font(.system(size: 7))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if labelFirst { cornerValue(value, color: color) }
        }
        .frame(width: 58)
    }

    private func cornerValue(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .opacity(summaryIsStale ? 0.65 : 1)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
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

    private var primaryTextColor: Color {
        guard isFullColor, showsContainerBackground else { return .primary }
        return colorScheme == .dark
            ? .white
            : Color(red: 0.07, green: 0.11, blue: 0.09)
    }

    private var secondaryTextColor: Color {
        guard isFullColor, showsContainerBackground else { return .secondary }
        return colorScheme == .dark
            ? Color.white.opacity(0.82)
            : Color(red: 0.19, green: 0.25, blue: 0.21)
    }

    private var accessibilitySummary: String {
        [
            "\(text("今日词元", "Today tokens")): \(count(todayTokens))",
            "\(text("词元相对平常", "Tokens versus usual")): \(multiple(tokenRatio))",
            "\(text("今日行数", "Today lines")): \(count(todayLines))",
            "\(text("行数相对平常", "Lines versus usual")): \(multiple(lineRatio))",
            "\(text("活动强度", "Activity")): \(pulseText)",
            latestPulse.map {
                text("观测于 ", "Observed ")
                    + $0.asOf.formatted(date: .omitted, time: .shortened)
            },
            status
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}
