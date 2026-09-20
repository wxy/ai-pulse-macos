import AIPulseShared
import SwiftUI
import WidgetKit

private enum MacWidgetCopy {
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

private struct MacWidgetRing: View {
    let ratio: Double?
    let color: Color
    let trackColor: Color
    let width: CGFloat
    var allowsLaps = true

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let value = ratio.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let arc = WatchDashboardData.remainingArc(value ?? 0)
            ZStack {
                Circle()
                    .stroke(value == nil ? Color.gray.opacity(0.24) : trackColor, lineWidth: width)
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
                }
            }
            .frame(width: diameter - width, height: diameter - width)
            .position(x: diameter / 2, y: diameter / 2)
        }
        .accessibilityHidden(true)
    }
}

struct AIPulseMacWidgetEntryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.showsWidgetContainerBackground) private var showsContainerBackground
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: MacWidgetEntry

    private let tokenColor = Color.deepRed
    private let lineColor = Color.marsGreen
    private let activityColor = Color(red: 212 / 255, green: 163 / 255, blue: 38 / 255)
    private var projection: MacWidgetProjection { MacWidgetProjection(entry: entry) }
    private var isFullColor: Bool { renderingMode == .fullColor }
    private var background: Color {
        colorScheme == .dark
            ? Color(red: 0.045, green: 0.065, blue: 0.055)
            : Color(red: 0.91, green: 0.93, blue: 0.90)
    }
    private var primaryText: Color {
        guard isFullColor && showsContainerBackground else { return .primary }
        return colorScheme == .dark ? .white : Color(red: 0.10, green: 0.14, blue: 0.12)
    }
    private var secondaryText: Color {
        guard isFullColor && showsContainerBackground else { return .secondary }
        return colorScheme == .dark
            ? Color.white.opacity(0.82)
            : Color(red: 0.23, green: 0.29, blue: 0.25)
    }
    private var trackOpacity: Double { colorScheme == .dark ? 0.28 : 0.24 }

    var body: some View {
        widgetContent
        .widgetURL(AIPulseDeepLink.dashboardURL)
        .containerBackground(background, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(MacWidgetCopy.text("打开仪表盘", "Open dashboard"))
    }

    private var widgetContent: some View {
        GeometryReader { geometry in
            let edge = min(geometry.size.width, geometry.size.height)
            let side = edge * 0.80
            let thickness = side * 13 / 184
            ZStack {
                rings(side: side, thickness: thickness)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2 + 2)
                cornerFacts(in: geometry.size, ringSide: side, ringWidth: thickness)
                if let statusText {
                    Text(statusText)
                        .font(.system(size: 7))
                        .foregroundStyle(activityColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 6)
                }
            }
        }
        .invalidatableContent()
    }

    private func rings(side: CGFloat, thickness: CGFloat) -> some View {
        ZStack {
            MacWidgetRing(
                ratio: projection.tokenRatio,
                color: tokenColor,
                trackColor: Color.deepRed2.opacity(trackOpacity),
                width: thickness
            )
            .opacity(projection.summaryIsStale ? 0.55 : 1)
            .widgetAccentable()
            MacWidgetRing(
                ratio: projection.lineRatio,
                color: lineColor,
                trackColor: Color.marsGreenLight.opacity(trackOpacity),
                width: thickness
            )
            .padding(side * 16 / 184)
            .opacity(projection.summaryIsStale ? 0.55 : 1)
            .widgetAccentable()
            MacWidgetRing(
                ratio: projection.intensity,
                color: activityColor,
                trackColor: activityColor.opacity(trackOpacity),
                width: thickness,
                allowsLaps: false
            )
            .padding(side * 32 / 184)
            .widgetAccentable()
            centerFact
        }
        .frame(width: side, height: side)
    }

    private var centerFact: some View {
        VStack(spacing: 3) {
            Text(MacWidgetCopy.text("当前强度", "Current activity"))
                .font(.system(size: 8))
                .foregroundStyle(secondaryText)
            Text(pulseText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let date = entry.pulseEnvelope?.pulse?.asOf {
                Text(MacWidgetCopy.text("观测于 ", "Observed ")
                     + date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 7))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(width: 70)
    }

    private func cornerFacts(in size: CGSize, ringSide: CGFloat, ringWidth: CGFloat) -> some View {
        let gapRadius = ringSide / 2 + ringWidth * 1.70
        let lineSpacing: CGFloat = 3
        let bottomOpticalOffset = ringWidth * 0.15
        let ringCenter = CGPoint(x: size.width / 2, y: size.height / 2 + 2)
        let edgePadding: CGFloat = 7
        let leftReach = max(1, ringCenter.x - edgePadding)
        let rightReach = max(1, size.width - ringCenter.x - edgePadding)
        let topReach = max(1, ringCenter.y - edgePadding)
        let bottomReach = max(1, size.height - ringCenter.y - edgePadding)
        let topLeftAngle = Angle.radians(Double(atan2(-topReach, -leftReach)))
        let topRightAngle = Angle.radians(Double(atan2(-topReach, rightReach)))
        let bottomLeftAngle = Angle.radians(Double(atan2(bottomReach, -leftReach)))
        let bottomRightAngle = Angle.radians(Double(atan2(bottomReach, rightReach)))
        return ZStack {
            curvedCorner(
                MacWidgetCopy.text("今日词元", "Today tokens"),
                projection.count(projection.todayTokens),
                color: tokenColor,
                centerAngle: topLeftAngle,
                direction: .clockwise,
                gapRadius: gapRadius,
                lineSpacing: lineSpacing
            )

            curvedCorner(
                MacWidgetCopy.text("今日行数", "Today lines"),
                projection.count(projection.todayLines),
                color: lineColor,
                centerAngle: topRightAngle,
                direction: .clockwise,
                gapRadius: gapRadius,
                lineSpacing: lineSpacing
            )

            curvedCorner(
                MacWidgetCopy.text("词元 / 平常", "Tokens / usual"),
                projection.multiple(projection.tokenRatio),
                color: tokenColor,
                centerAngle: bottomLeftAngle,
                direction: .counterClockwise,
                gapRadius: gapRadius + bottomOpticalOffset,
                lineSpacing: lineSpacing
            )

            curvedCorner(
                MacWidgetCopy.text("行数 / 平常", "Lines / usual"),
                projection.multiple(projection.lineRatio),
                color: lineColor,
                centerAngle: bottomRightAngle,
                direction: .counterClockwise,
                gapRadius: gapRadius + bottomOpticalOffset,
                lineSpacing: lineSpacing
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
                color: secondaryText,
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
                color: isFullColor ? color : primaryText,
                characterSpacing: 0.1,
                minimumScaleFactor: 0.8
            )
            .opacity(projection.summaryIsStale ? 0.65 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private var pulseText: String {
        guard let pulse = projection.currentPulse else {
            return entry.pulseEnvelope?.pulse == nil
                ? MacWidgetCopy.text("暂无观测", "No observation")
                : MacWidgetCopy.text("观测已过期", "Expired")
        }
        switch pulse.tier {
        case .resting: return MacWidgetCopy.text("平静", "Resting")
        case .active: return MacWidgetCopy.text("活跃", "Active")
        case .elevated: return MacWidgetCopy.text("升高", "Elevated")
        case .intense: return MacWidgetCopy.text("强烈", "Intense")
        }
    }

    private var statusText: String? {
        if projection.shouldOpenApp {
            let action = MacWidgetCopy.text("打开仪表盘", "Open dashboard")
            guard let writtenAt = entry.snapshotWrittenAt else { return action }
            return writtenAt.formatted(date: .omitted, time: .shortened) + " · " + action
        }
        switch entry.loadStatus {
        case .available:
            guard projection.summaryIsStale, let snapshot = entry.todaySnapshot else { return nil }
            return MacWidgetCopy.text("缓存 ", "Cached ")
                + snapshot.updatedAt.formatted(date: .omitted, time: .shortened)
        case .waitingForRefresh: return MacWidgetCopy.text("等待刷新", "Waiting to refresh")
        case .noData: return MacWidgetCopy.text("暂无数据", "No data")
        case .failed: return MacWidgetCopy.text("暂无数据", "No data")
        }
    }

    private var accessibilitySummary: String {
        [
            MacWidgetCopy.text("今日词元", "Today tokens") + " " + projection.count(projection.todayTokens),
            MacWidgetCopy.text("今日行数", "Today lines") + " " + projection.count(projection.todayLines),
            MacWidgetCopy.text("当前强度", "Current activity") + " " + pulseText,
            statusText,
        ].compactMap { $0 }.joined(separator: ", ")
    }
}
