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

    private var weekIsStale: Bool {
        guard let snapshot = validCurrentWeekSnapshot else { return false }
        return !WatchDashboardData.isSummaryFresh(snapshot, now: entry.date)
    }

    private var historyIsStale: Bool {
        guard let snapshot = validCurrentHistorySnapshot else { return false }
        return !WatchDashboardData.isSummaryFresh(snapshot, now: entry.date)
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

    // MARK: - Medium (today rings + weekly facts)

    private var mediumBody: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                todayAndWeekHeader(side: min(geometry.size.height * 0.72, 112))
                    .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) { statusFooter.padding(.trailing, 12).padding(.bottom, 6) }
        }
        .containerBackground(widgetBackground, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Large (today + weekly facts + 30-day rhythm)

    private var largeBody: some View {
        VStack(spacing: 10) {
            todayAndWeekHeader(side: 112)
                .frame(height: 152)
            rhythmSection
                .frame(maxHeight: .infinity, alignment: .center)
                .opacity(historyIsStale ? 0.6 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) { statusFooter.padding(.trailing, 12).padding(.bottom, 6) }
        .containerBackground(widgetBackground, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// The medium and large widgets share the same Today rings and four corner facts.
    private func todayAndWeekHeader(side: CGFloat) -> some View {
        let thickness = side * 13 / 184
        let panelSide = side + 40
        return HStack(spacing: 8) {
            ZStack {
                ringCluster(side: side, thickness: thickness)
                    .position(x: panelSide / 2, y: panelSide / 2)
                cornerFacts(in: CGSize(width: panelSide, height: panelSide),
                            ringSide: side, ringWidth: thickness)
            }
            .frame(width: panelSide, height: panelSide)
            weekFactsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .opacity(weekIsStale ? 0.6 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var weekFactsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            weekFactRow(color: tokenColor,
                        label: text("本周词元", "This week tokens"),
                        value: count(weekTokens), ratio: weekTokenRatio)
            weekFactRow(color: lineColor,
                        label: text("本周行数", "This week lines"),
                        value: count(weekLines), ratio: weekLineRatio)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func weekFactRow(color: Color, label: String, value: String, ratio: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(secondaryTextColor)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(multiple(ratio) + " " + text("上周", "last week"))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private var weekTokens: Double? {
        guard let snapshot = validCurrentWeekSnapshot,
              !snapshot.readFailures.contains("dashboardUsageStats") else { return nil }
        return Double(snapshot.todayTokens)
    }

    private var weekLines: Double? {
        guard let snapshot = validCurrentWeekSnapshot,
              !snapshot.readFailures.contains("repositoryCode") else { return nil }
        return snapshot.topRepos.reduce(0) { $0 + Double($1.added) + Double($1.deleted) }
    }

    private var weekTokenRatio: Double? {
        WatchDashboardData.ratio(value: weekTokens, baseline: previousWeekTotal(tokens: true))
    }

    private var weekLineRatio: Double? {
        WatchDashboardData.ratio(value: weekLines, baseline: previousWeekTotal(tokens: false))
    }

    private struct WeekWindow {
        let snapshot: DashboardSnapshot
        let calendar: Calendar
        let start: Date
        let nextStart: Date
        let previousStart: Date
    }

    private var currentWeekWindow: WeekWindow? {
        guard let snapshot = entry.weekSnapshot,
              PhoneDashboardData.accepts(snapshot, range: "week"),
              let timeZone = TimeZone(identifier: snapshot.period.timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: entry.date)
        let weekday = calendar.component(.weekday, from: today)
        let daysSinceMonday = (weekday + 5) % 7
        guard let start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today),
              let nextStart = calendar.date(byAdding: .day, value: 7, to: start),
              let previousStart = calendar.date(byAdding: .day, value: -7, to: start),
              snapshot.period.start == start,
              snapshot.period.end > entry.date,
              snapshot.period.end <= nextStart,
              entry.date < nextStart,
              snapshot.updatedAt <= entry.date.addingTimeInterval(60) else { return nil }
        return WeekWindow(snapshot: snapshot, calendar: calendar, start: start,
                          nextStart: nextStart, previousStart: previousStart)
    }

    private var validCurrentWeekSnapshot: DashboardSnapshot? {
        currentWeekWindow?.snapshot
    }

    /// Previous-week totals require a successful 30-day snapshot covering the
    /// whole Monday-to-Monday interval in the same Mac timezone.
    private func previousWeekTotal(tokens: Bool) -> Double? {
        guard let week = currentWeekWindow,
              let history = entry.historySnapshot,
              PhoneDashboardData.accepts(history, range: "30d"),
              history.period.timeZoneIdentifier == week.snapshot.period.timeZoneIdentifier,
              history.period.start <= week.previousStart,
              history.period.end >= week.start,
              history.period.end > entry.date,
              !history.readFailures.contains(tokens ? "dashboardUsageStats" : "dashboardCodeChanges") else {
            return nil
        }
        let points = tokens ? history.dailyStats : history.codeChanges
        var total = 0.0
        for point in points where point.ts.isFinite {
            let date = Date(timeIntervalSince1970: point.ts)
            guard date >= week.previousStart, date < week.start else { continue }
            let value = tokens
                ? Double(max(0, point.tokens))
                : max(0, Double(point.added) + Double(point.deleted))
            guard value.isFinite else { return nil }
            total += value
            guard total.isFinite else { return nil }
        }
        return total
    }

    private var statusFooter: some View {
        Group {
            if let footerStatus = status ?? weekCacheStatus ?? historyCacheStatus {
                Text(footerStatus)
                    .font(.system(size: 8))
                    .foregroundStyle(summaryIsStale || weekIsStale || historyIsStale
                                     ? activityColor : secondaryTextColor)
                    .lineLimit(1)
            }
        }
    }

    private var weekCacheStatus: String? {
        guard weekIsStale, let snapshot = validCurrentWeekSnapshot else { return nil }
        return text("本周缓存 ", "Week cached ")
            + snapshot.updatedAt.formatted(date: .omitted, time: .shortened)
    }

    private var historyCacheStatus: String? {
        guard family == .systemLarge, historyIsStale,
              let snapshot = validCurrentHistorySnapshot else { return nil }
        return text("30 天缓存 ", "30 days cached ")
            + snapshot.updatedAt.formatted(date: .omitted, time: .shortened)
    }

    private var rhythmSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text("近 30 天节奏", "Last 30 days rhythm"))
                .font(.system(size: 10))
                .foregroundStyle(secondaryTextColor)
            rhythmRow(tokens: true).frame(height: 34)
            rhythmRow(tokens: false).frame(height: 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rhythmRow(tokens: Bool) -> some View {
        let values = monthlyRhythm(tokens: tokens)
        let peak = max(1, values?.filter { $0.isFinite && $0 >= 0 }.max() ?? 0)
        let color = tokens ? Color.marsGreen : Color.deepRed2
        return HStack(spacing: 4) {
            Text(text(tokens ? "词元" : "行数", tokens ? "Tokens" : "Lines")
                 + (values == nil ? " N/A" : ""))
                .font(.system(size: 8))
                .foregroundStyle(values == nil ? secondaryTextColor : color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 42, alignment: .leading)
            GeometryReader { geometry in
                HStack(alignment: tokens ? .top : .bottom, spacing: 3) {
                    ForEach(0..<30, id: \.self) { index in
                        let value = values.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? -1
                        Capsule()
                            .fill(value < 0
                                  ? Color.secondary.opacity(0.15)
                                  : color.opacity(value == 0 ? 0.15 : 0.9))
                            .frame(height: value < 0 ? 3 : max(3, geometry.size.height * value / peak))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: geometry.size.height, alignment: tokens ? .top : .bottom)
            }
        }
        .accessibilityHidden(true)
    }

    private func monthlyRhythm(tokens: Bool) -> [Double]? {
        guard let snapshot = validCurrentHistorySnapshot,
              !snapshot.readFailures.contains(tokens ? "dashboardUsageStats" : "dashboardCodeChanges") else {
            return nil
        }
        let points = tokens ? snapshot.dailyStats : snapshot.codeChanges
        let values = PhoneDashboardData.rhythm(points, period: snapshot.period, tokens: tokens)
        return values.count == 30 && values.allSatisfy { $0.isFinite && $0 >= 0 } ? values : nil
    }

    private var validCurrentHistorySnapshot: DashboardSnapshot? {
        guard let snapshot = entry.historySnapshot,
              PhoneDashboardData.accepts(snapshot, range: "30d"),
              let timeZone = TimeZone(identifier: snapshot.period.timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: entry.date)
        guard let start = calendar.date(byAdding: .day, value: -29, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today),
              snapshot.period.start == start,
              snapshot.period.end >= end else { return nil }
        return snapshot
    }

    private func monthlyRhythmAccessibility(tokens: Bool) -> String {
        let label = text(tokens ? "近 30 天词元" : "近 30 天行数",
                         tokens ? "Last 30 days of tokens" : "Last 30 days of lines")
        guard let snapshot = validCurrentHistorySnapshot,
              let values = monthlyRhythm(tokens: tokens),
              let timeZone = TimeZone(identifier: snapshot.period.timeZoneIdentifier) else { return label + ": N/A" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M/d"
        let points = values.enumerated().compactMap { index, value -> String? in
            guard let date = calendar.date(byAdding: .day, value: index, to: snapshot.period.start) else { return nil }
            return "\(formatter.string(from: date)) \(count(value))"
        }
        return label + ": " + points.joined(separator: ", ")
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
        var parts = [
            "\(text("今日词元", "Today tokens")): \(count(todayTokens))",
            "\(text("词元相对平常", "Tokens versus usual")): \(multiple(tokenRatio))",
            "\(text("今日行数", "Today lines")): \(count(todayLines))",
            "\(text("行数相对平常", "Lines versus usual")): \(multiple(lineRatio))",
            "\(text("活动强度", "Activity")): \(pulseText)",
            latestPulse.map {
                text("观测于 ", "Observed ")
                    + $0.asOf.formatted(date: .omitted, time: .shortened)
            }
        ].compactMap { $0 }
        if family == .systemMedium || family == .systemLarge {
            parts.append("\(text("本周词元", "This week tokens")): \(count(weekTokens)), \(text("相对上周", "versus last week")): \(multiple(weekTokenRatio))")
            parts.append("\(text("本周行数", "This week lines")): \(count(weekLines)), \(text("相对上周", "versus last week")): \(multiple(weekLineRatio))")
        }
        if family == .systemLarge {
            parts.append(monthlyRhythmAccessibility(tokens: true))
            parts.append(monthlyRhythmAccessibility(tokens: false))
        }
        if let footerStatus = status ?? weekCacheStatus ?? historyCacheStatus {
            parts.append(footerStatus)
        }
        return parts.joined(separator: ", ")
    }
}
