import SwiftUI
import Charts
import AIPulseShared

/// Same-window detail destination exploring one tool's sessions: grouped by repo,
/// each row expandable to show the per-turn context-window trend chart.
/// Covers the whole dashboard window, so its internal scrolling never
/// conflicts with the dashboard's scroll area.
struct ToolDetailOverlayView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let toolId: String
    let sinceMs: Int64
    let onBack: () -> Void
    var embedded = false

    @State private var groups: [RepoSessionGroup] = []
    @State private var expandedSessionId: String? = nil
    @State private var trend: ContextTrend?
    @State private var sortByActivity = false
    @State private var collapsedRepos: Set<String> = []
    @State private var hoveredSessionId: String? = nil
    @State private var selectedTurnIndex: Int? = nil
    @State private var trendSessionId: String? = nil
    @State private var conclusion: ToolActivitySummary? = nil
    private enum LoadState { case loading, ready, failed, demo }
    @State private var loadState: LoadState = .loading
    @State private var outputUnavailable = false
    @State private var retryGeneration = 0
    @State private var loadGeneration = 0
    @State private var observationDate = Date()
    @State private var trendFailed = false
    @State private var trendGeneration = 0

    // Chart axis labels as runtime values so Xcode's string catalog does not
    // auto-extract them as translatable keys.
    private let turnLabel = "turn"
    private let contextLabel = "context"
    private let cacheLabel = "cache"
    private let zeroLabel = "zero"
    private let windowLabel = "window"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if (conclusion?.sessionCount ?? 0) > 0 {
                conclusionSummary
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if loadState == .loading {
                        ProgressView(detailText("正在读取会话…", "Reading sessions…"))
                            .frame(maxWidth: .infinity)
                    } else if loadState == .demo {
                        Label(detailText("演示模式仅展示汇总；配置真实工具后可查看会话详情。", "Demo mode shows summaries only; configure a real tool to explore sessions."), systemImage: "info.circle")
                            .font(.caption).foregroundColor(.secondary)
                    } else if loadState == .failed {
                        Label(detailText("会话读取失败，不代表没有活动。", "Sessions could not be read; this does not mean no activity."), systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        retryButton
                    } else if groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(groups) { group in
                            groupSection(group)
                        }
                    }
                    if loadState == .ready && outputUnavailable {
                        Text(detailText("会话已读取，但仓库产出暂不可用。", "Sessions loaded, but repository output is unavailable."))
                            .font(.caption).foregroundColor(.orange)
                        retryButton
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(embedded ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .task(id: "\(toolId)/\(sinceMs)/\(retryGeneration)") { await load() }
        .onExitCommand(perform: onBack)
    }

    private var toolDisplayName: String {
        IntegrationRegistry.toolDisplayName(for: toolId)
    }

    private var totalActivityText: String {
        Self.abbrevTokens(Int(clamping: groups.flatMap(\.sessions).reduce(Int64(0)) { $0 + $1.observedTokens }))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Label(embedded ? detailText("返回", "Back") : I18n.t("panel.back_to_dashboard"), systemImage: "arrow.left")
                    .font(.caption)
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.borderless)
            .pointingHandCursor()
            Image(systemName: toolId == "deepseek-harness"
                  ? "terminal" : toolId == "codex" ? "sparkles" : "bubble.left.and.bubble.right")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(toolDisplayName).font(.headline)
                Text(loadState == .ready
                     ? String(format: I18n.t("panel.header_activity"), groups.count, totalActivityText)
                     : loadState == .demo ? detailText("演示汇总 · 无真实会话详情", "Demo summary · no real session details")
                     : detailText("会话统计暂不可用", "Session statistics unavailable"))
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: $sortByActivity) {
                Text(I18n.t("panel.recent")).tag(false)
                Text(I18n.t("panel.most_active")).tag(true)
            }
            .pickerStyle(.segmented).frame(width: embedded ? 110 : 170).labelsHidden()
            .pointingHandCursor()
        }
        .padding(.horizontal, embedded ? 0 : 14).padding(.top, embedded ? 0 : 30).padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2).foregroundColor(.secondary)
            Text(I18n.t("panel.empty_sessions"))
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupSection(_ group: RepoSessionGroup) -> some View {
        let collapsed = collapsedRepos.contains(group.repo)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { toggleCollapse(group.repo) }
            } label: {
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.accentColor.opacity(0.8))
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(group.repo == SessionStats.noRepoKey ? I18n.t("panel.no_repo_group") : group.repo)
                        .font(.caption).fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: I18n.t("panel.group_activity"), group.sessions.count,
                                Self.abbrevTokens(Int(clamping: group.sessions.reduce(Int64(0)) { $0 + $1.observedTokens }))))
                        .font(.caption2).foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if !collapsed {
                ForEach(sortedSessions(group.sessions)) { row in
                    sessionRow(row)
                    if expandedSessionId == row.sessionId {
                        trendCard(for: row)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func sortedSessions(_ rows: [SessionRow]) -> [SessionRow] {
        rows.sorted { sortByActivity ? $0.observedTokens > $1.observedTokens : $0.lastTs > $1.lastTs }
    }

    private func sessionRow(_ row: SessionRow) -> some View {
        let expanded = expandedSessionId == row.sessionId
        let hovered = hoveredSessionId == row.sessionId
        return HStack(spacing: 8) {
            Text(timeText(row.lastTs))
                .font(.caption2).foregroundColor(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(row.title ?? I18n.t("panel.no_title"))
                .font(.caption).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            occupancyBar(row)
            Text(String(format: I18n.t("panel.observed_tokens"), Self.abbrevTokens(Int(clamping: row.observedTokens))))
                .font(.caption).fontWeight(expanded ? .semibold : .regular).monospacedDigit()
                .foregroundColor(expanded ? .accentColor : .primary)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(hovered ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredSessionId = inside ? row.sessionId : nil
        }
        .onTapGesture {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                expandedSessionId = expanded ? nil : row.sessionId
            }
            if expandedSessionId == row.sessionId, let sid = row.sessionId {
                loadTrend(source: row.source, sessionId: sid)
            }
        }
        .pointingHandCursor()
    }

    @ViewBuilder
    private func trendCard(for row: SessionRow) -> some View {
        if let trend {
            VStack(alignment: .leading, spacing: 6) {
                if trend.isContextLike {
                    contextChart(trend)
                } else {
                    Label(I18n.t("panel.context_unavailable"), systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundColor(.secondary)
                        .padding(.vertical, 4)
                }
                if trend.isContextLike && trend.needsCompactionHint {
                    Label(I18n.t("panel.compact_hint"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundColor(.orange)
                }
                HStack(spacing: 12) {
                    HStack(spacing: 14) {
                        metric("arrow.turn.up.right", String(format: I18n.t("panel.turns"), trend.turns.count))
                        if let occ = trend.finalOccupancy {
                            metric("cylinder.split.1x2", occupancyText(occ))
                        }
                        metric("arrow.down", trend.observedOutputTokens.map {
                            String(format: I18n.t("panel.output_tokens"), Self.abbrevTokens($0))
                        } ?? detailText("输出词元不可用", "Output tokens unavailable"))
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 10) {
                        legendSwatch(line: Color.marsGreen, I18n.t("panel.chart_context"))
                        legendSwatch(fill: Color.marsGreenLight, I18n.t("panel.chart_cache"))
                        legendSwatch(cross: Color.deepRed, I18n.t("panel.chart_compaction"))
                    }
                }
                .font(.caption2).foregroundColor(.secondary)
                Text(detailText("完整会话截至本次读取；曲线仅含有效输入观察，输出合计另含仅输出记录。", "Full session up to this read; the plot contains input observations, while output totals also include output-only records."))
                    .font(.caption2).foregroundColor(.secondary)
                if (trend.incompleteEvents ?? 0) > 0 {
                    Text(detailText("部分字段缺失，词元合计仅包含已知部分。", "Some fields are missing; token totals include known components only."))
                        .font(.caption2).foregroundColor(.orange)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        } else if trendFailed {
            VStack(alignment: .leading, spacing: 6) {
                Text(detailText("会话轨迹读取失败。", "Session trajectory could not be read."))
                    .font(.caption).foregroundColor(.orange)
                if let sid = row.sessionId {
                    Button(detailText("重试", "Retry")) { loadTrend(source: row.source, sessionId: sid) }
                }
            }.padding(8)
        } else {
            ProgressView().controlSize(.small).padding(8)
        }
    }

    private func metric(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2).foregroundColor(.secondary)
            .labelStyle(.titleAndIcon)
    }

    private func legendSwatch(line color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 16, height: 3)
            Text(label)
        }
    }

    private func legendSwatch(fill color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.55)).frame(width: 12, height: 8)
            Text(label)
        }
    }

    private func legendSwatch(cross color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "multiply")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color)
                .frame(width: 10, height: 10)
            Text(label)
        }
    }

    private func contextChart(_ trend: ContextTrend) -> some View {
        let maxContext = trend.turns.map(\.contextTokens).max() ?? 1
        let yMax = ChartMath.tokenAxisMax(
            context: maxContext,
            window: trend.windowTokens
        )
        return Chart {
            ForEach(trend.turns) { t in
                // Single fill: cache area from zero. The space between this
                // fill's top and the context line is the uncached portion —
                // naturally visible as a narrow gap (cache is usually ~99%).
                AreaMark(
                    x: .value(turnLabel, t.index),
                    yStart: .value(zeroLabel, 0),
                    yEnd: .value(cacheLabel, ChartMath.barValue(base: Double(t.cacheTokens), progress: 1))
                )
                    .foregroundStyle(Color.marsGreenLight.opacity(0.40))
                    .interpolationMethod(.monotone)
                // Context window curve — dark green line.
                LineMark(x: .value(turnLabel, t.index), y: .value(contextLabel, ChartMath.barValue(base: Double(t.contextTokens), progress: 1)))
                    .foregroundStyle(Color.marsGreen)
                    .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let window = trend.windowTokens, window > 0 {
                RuleMark(y: .value(windowLabel, window))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.secondary)
            }
            if let idx = selectedTurnIndex {
                RuleMark(x: .value(turnLabel, idx))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        if let point = trend.turns.first(where: { $0.index == idx }) {
                            turnTooltip(point, isCompaction: trend.compactionIndexes.contains(point.index))
                        }
                    }
            }
            ForEach(Array(trend.compactionIndexes), id: \.self) { idx in
                if let point = trend.turns.first(where: { $0.index == idx }) {
                    PointMark(x: .value(turnLabel, idx), y: .value(contextLabel, point.contextTokens))
                        .foregroundStyle(Color.deepRed)
                        .symbol(.cross)
                        .symbolSize(8)
                }
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            // Location.x is measured from the chart's left edge,
                            // including the y-axis labels. Subtract the plot
                            // area origin so the selection starts at the axis.
                            if let plotAnchor = proxy.plotFrame {
                                let plotFrame = geo[plotAnchor]
                                let plotX = location.x - plotFrame.minX
                                selectedTurnIndex = proxy.value(atX: plotX)
                            }
                        case .ended:
                            selectedTurnIndex = nil
                        }
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Self.abbrevTokens(ChartMath.safeInt(v)))
                    }
                }
            }
        }
        .frame(height: 140)
    }

    private func turnTooltip(_ point: TurnPoint, isCompaction: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: I18n.t("panel.turns"), point.index))
                .font(.caption2).fontWeight(.semibold)
            Text("\(I18n.t("panel.chart_context")) \(Self.abbrevTokens(point.contextTokens))")
            Text("\(I18n.t("panel.chart_cache")) \(Self.abbrevTokens(point.cacheTokens))")
            let uncached = point.contextTokens > point.cacheTokens
                ? point.contextTokens - point.cacheTokens
                : 0
            Text("\(I18n.t("panel.chart_uncached")) \(Self.abbrevTokens(uncached))")
            if isCompaction {
                Text(I18n.t("panel.chart_compaction"))
                    .foregroundColor(Color.deepRed)
            }
        }
        .font(.caption2).monospacedDigit()
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Compact axis labels: 250000 → "250K", 1200000 → "1.2M".
    private static func abbrevTokens(_ tokens: Int) -> String {
        ChartMath.compactCount(Int64(tokens))
    }

    private func occupancyBar(_ row: SessionRow) -> some View {
        let occ = row.finalOccupancy ?? 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(occColor(occ))
                    .frame(width: geo.size.width * CGFloat(ChartMath.unit(occ)))
            }
        }
        .frame(width: 40, height: 4)
    }

    private func detailText(_ zh: String, _ en: String) -> String {
        I18n.prototype(zh, en)
    }

    private var retryButton: some View {
        Button(detailText("重试", "Retry")) { retryGeneration += 1 }
    }

    @MainActor
    private func loadTrend(source: String, sessionId: String) {
        trendGeneration += 1
        let generation = trendGeneration
        let now = observationDate
        trend = nil
        trendFailed = false
        trendSessionId = sessionId
        Task { @MainActor in
            do {
                let loaded = try await StatsService.turnSeries(source: source, sessionId: sessionId, now: now)
                guard !Task.isCancelled, generation == trendGeneration,
                      expandedSessionId == sessionId else { return }
                trend = loaded
            } catch {
                guard !Task.isCancelled, generation == trendGeneration,
                      expandedSessionId == sessionId else { return }
                trendFailed = true
            }
        }
    }

    @MainActor
    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        loadState = .loading
        groups = []
        conclusion = nil
        outputUnavailable = false
        expandedSessionId = nil
        trend = nil
        trendSessionId = nil
        trendGeneration += 1
        trendFailed = false
        guard !DemoData.isActive else {
            loadState = .demo
            return
        }
        let source = toolId
        let now = Date()
        observationDate = now
        let rows: [SessionRow]
        do {
            rows = try await StatsService.sessionRows(source: source, sinceMs: sinceMs, now: now)
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            loadState = .failed
            return
        }
        let c: ToolActivitySummary?
        do {
            c = try await StatsService.toolActivitySummary(source: source, sinceMs: sinceMs, sessionCount: rows.count, now: now)
        } catch {
            Logger.error("Tool activity summary failed: \(error)")
            c = nil
        }
        guard !Task.isCancelled, generation == loadGeneration else { return }
        groups = SessionStats.groupSessions(rows)
        conclusion = c
        outputUnavailable = c == nil
        loadState = .ready
    }

    /// Output is a companion fact, not evidence that spending was worthwhile.
    @ViewBuilder
    private var conclusionSummary: some View {
        if let c = conclusion, c.sessionCount > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: I18n.t("card.output"),
                            c.sessionCount, c.commitCount, c.addedLines, c.deletedLines))
                Text(I18n.t("panel.activity_explanation"))
            }
            .font(.caption2).foregroundColor(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    private func toggleCollapse(_ repo: String) {
        if collapsedRepos.contains(repo) { collapsedRepos.remove(repo) } else { collapsedRepos.insert(repo) }
    }

    private func timeText(_ ts: Int) -> String {
        Self.timeFormatter.string(from: Date(timeIntervalSince1970: Double(ts) / 1000))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private func occupancyText(_ occ: Double) -> String {
        let pct = occ.formatted(.percent.precision(.fractionLength(0)))
        return String(format: I18n.t("panel.occupancy"), pct)
    }

    private func occColor(_ occ: Double) -> Color {
        occ > 0.8 ? .orange : (occ > 0.5 ? .yellow : .marsGreen)
    }

}
