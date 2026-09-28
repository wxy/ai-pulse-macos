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
    @Environment(\.widgetFamily) private var family
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
        switch family {
        case .systemMedium: mediumBody
        case .systemLarge: largeBody
        default: smallBody
        }
    }

    // MARK: - Small (curved corner metrics, unchanged)

    private var smallBody: some View {
        GeometryReader { geometry in
            let edge = min(geometry.size.width, geometry.size.height)
            let side = edge * 0.82
            let thickness = side * 13 / 184
            ZStack {
                ringCluster(side: side, thickness: thickness)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2 + 2)
                cornerFacts(in: geometry.size, ringSide: side, ringWidth: thickness)
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

    // MARK: - Medium (rings + aligned text facts)

    private var mediumBody: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.height * 0.86, 132)
            let thickness = side * 13 / 184
            HStack(spacing: 16) {
                ringCluster(side: side, thickness: thickness)
                    .frame(width: side, height: side)
                factsColumn
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) { statusFooter.padding(.trailing, 12).padding(.bottom, 6) }
        }
        .containerBackground(widgetBackground, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Large (medium row + seven-day token rhythm)

    private var largeBody: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.height * 0.52, 138)
            let thickness = side * 13 / 184
            VStack(spacing: 10) {
                HStack(spacing: 16) {
                    ringCluster(side: side, thickness: thickness)
                        .frame(width: side, height: side)
                    factsColumn
                    Spacer(minLength: 0)
                }
                rhythmSection
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottomTrailing) { statusFooter.padding(.trailing, 12).padding(.bottom, 6) }
        }
        .containerBackground(widgetBackground, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Text facts shared by the medium and large layouts: the same numbers the
    /// curved small widget encodes around the rings, now in reading order.
    private var factsColumn: some View {
        VStack(alignment: .leading, spacing: 9) {
            factRow(color: tokenColor,
                    label: text("今日词元", "Today tokens"),
                    value: count(todayTokens),
                    context: multiple(tokenRatio) + " " + text("平常", "usual"))
            factRow(color: lineColor,
                    label: text("今日行数", "Today lines"),
                    value: count(todayLines),
                    context: multiple(lineRatio) + " " + text("平常", "usual"))
            Divider()
            HStack(spacing: 6) {
                Circle().fill(activityColor).frame(width: 6, height: 6)
                Text(pulseText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let date = entry.pulseEnvelope?.pulse?.asOf {
                Text(text("观测于 ", "Observed ") + date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundStyle(secondaryTextColor)
            }
            Spacer(minLength: 0)
        }
    }

    private func factRow(color: Color, label: String, value: String, context: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(secondaryTextColor)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(context)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(secondaryTextColor)
            }
        }
        .opacity(summaryIsStale ? 0.6 : 1)
    }

    private var statusFooter: some View {
        Group {
            if let status {
                Text(status)
                    .font(.system(size: 8))
                    .foregroundStyle(summaryIsStale ? activityColor : secondaryTextColor)
                    .lineLimit(1)
            }
        }
    }

    /// Last seven daily token points from the synced 30-day snapshot. Bar
    /// heights scale against the maximum inside this window only; days with
    /// no observed tokens keep a faded stub instead of vanishing.
    private var rhythmSection: some View {
        let days = recentDailyTokens
        let maxTokens = days.map(\.tokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            Text(text("近 7 天词元", "Last 7 days of tokens"))
                .font(.system(size: 10))
                .foregroundStyle(secondaryTextColor)
            HStack(alignment: .bottom, spacing: 9) {
                ForEach(days) { day in
                    let ratio = maxTokens > 0 && day.tokens > 0
                        ? min(Double(day.tokens) / Double(maxTokens), 1) : 0
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(ratio > 0 ? tokenColor.opacity(0.78) : secondaryTextColor.opacity(0.30))
                            .frame(height: CGFloat(4 + ratio * 44))
                            .frame(maxWidth: 26)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rhythmAccessibility(days))
    }

    private struct RhythmDay: Identifiable {
        let date: Date
        let tokens: Int64
        var id: Date { date }
    }

    /// Project sparse Unix-second trend points into seven local calendar days.
    /// A missing point inside the covered period means zero activity; an old
    /// cache that no longer covers this window remains unknown instead.
    private var recentDailyTokens: [RhythmDay] {
        guard let snapshot = entry.historySnapshot,
              !snapshot.readFailures.contains("dashboardUsageStats") else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: snapshot.period.timeZoneIdentifier) else { return [] }
        calendar.timeZone = timeZone

        let today = calendar.startOfDay(for: entry.date)
        guard let windowStart = calendar.date(byAdding: .day, value: -6, to: today),
              let windowEnd = calendar.date(byAdding: .day, value: 1, to: today),
              snapshot.period.start <= windowStart,
              snapshot.period.end >= windowEnd else { return [] }

        var totals: [Date: Int64] = [:]
        for point in snapshot.dailyStats where point.ts.isFinite {
            let date = Date(timeIntervalSince1970: point.ts)
            guard date >= windowStart, date < windowEnd, date <= entry.date else { continue }
            let day = calendar.startOfDay(for: date)
            let tokens = max(0, point.tokens)
            let (sum, overflow) = (totals[day] ?? 0).addingReportingOverflow(tokens)
            totals[day] = overflow ? Int64.max : sum
        }

        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: windowStart) else { return nil }
            return RhythmDay(date: date, tokens: totals[date] ?? 0)
        }
    }

    private func rhythmAccessibility(_ days: [RhythmDay]) -> String {
        guard !days.isEmpty else { return text("暂无 7 天节奏数据", "No 7-day rhythm data") }
        let maxTokens = days.map(\.tokens).max() ?? 0
        let calendar = rhythmCalendar
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEEE"
        let parts = days.map { day -> String in
            let weekday = formatter.string(from: day.date)
            let ratio = maxTokens > 0 && day.tokens > 0
                ? "\(Int((Double(day.tokens) / Double(maxTokens) * 100).rounded()))%" : "0%"
            return "\(weekday) \(ChartMath.compactCount(day.tokens)) (\(ratio))"
        }
        return text("近 7 天词元", "Last 7 days of tokens") + ": " + parts.joined(separator: ", ")
    }

    private var rhythmCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let identifier = entry.historySnapshot?.period.timeZoneIdentifier,
           let timeZone = TimeZone(identifier: identifier) {
            calendar.timeZone = timeZone
        }
        return calendar
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

    private func cornerFacts(in size: CGSize, ringSide: CGFloat, ringWidth: CGFloat) -> some View {
        let gapRadius = ringSide / 2 + ringWidth * 1.60
        let lineSpacing: CGFloat = 1
        let bottomOpticalOffset = ringWidth * 0.15
        return ZStack {
            curvedCorner(
                text("今日词元", "Today tokens"), count(todayTokens),
                color: tokenColor, centerAngle: .degrees(-135), direction: .clockwise,
                gapRadius: gapRadius, lineSpacing: lineSpacing
            )
            curvedCorner(
                text("今日行数", "Today lines"), count(todayLines),
                color: lineColor, centerAngle: .degrees(-45), direction: .clockwise,
                gapRadius: gapRadius, lineSpacing: lineSpacing
            )
            curvedCorner(
                text("词元 / 平常", "Tokens / usual"), multiple(tokenRatio),
                color: tokenColor, centerAngle: .degrees(135), direction: .counterClockwise,
                gapRadius: gapRadius + bottomOpticalOffset, lineSpacing: lineSpacing
            )
            curvedCorner(
                text("行数 / 平常", "Lines / usual"), multiple(lineRatio),
                color: lineColor, centerAngle: .degrees(45), direction: .counterClockwise,
                gapRadius: gapRadius + bottomOpticalOffset, lineSpacing: lineSpacing
            )
        }
        .frame(width: size.width, height: size.height)
        .offset(y: 2)
    }

    private func curvedCorner(
        _ label: String,
        _ value: String,
        color: Color,
        centerAngle: Angle,
        direction: ArcText.Direction,
        gapRadius: CGFloat,
        lineSpacing: CGFloat
    ) -> some View {
        ZStack {
            ArcText(
                label,
                radius: gapRadius + lineSpacing / 2,
                centerAngle: centerAngle,
                direction: direction,
                radialAlignment: .innerEdge,
                maximumSweep: .degrees(42),
                fontSize: 7,
                color: secondaryTextColor,
                characterSpacing: 0.1,
                minimumScaleFactor: 0.75
            )
            ArcText(
                value,
                radius: gapRadius - lineSpacing / 2,
                centerAngle: centerAngle,
                direction: direction,
                radialAlignment: .outerEdge,
                maximumSweep: .degrees(30),
                fontSize: 10,
                fontWeight: .semibold,
                fontDesign: .rounded,
                color: color,
                characterSpacing: 0.1,
                minimumScaleFactor: 0.8
            )
            .opacity(summaryIsStale ? 0.65 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
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
            family == .systemLarge ? rhythmAccessibility(recentDailyTokens) : nil,
            status
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}
