import SwiftUI
import Charts

/// Full-window overlay exploring one tool's sessions: sessions grouped by repo,
/// each row expandable to show the per-turn context-window trend chart.
/// Covers the whole dashboard window, so its internal scrolling never
/// conflicts with the dashboard's scroll area.
struct ToolDetailOverlayView: View {
    let toolId: String
    let sinceMs: Int64
    let onClose: () -> Void

    @State private var groups: [RepoSessionGroup] = []
    @State private var expandedSessionId: String? = nil
    @State private var trend: ContextTrend?
    @State private var sortByCost = false
    @State private var collapsedRepos: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        groupSection(group)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .task { await load() }
        .onExitCommand(perform: onClose)
    }

    private var toolDisplayName: String {
        toolId == "codex" ? "ChatGPT" : "Claude Code"
    }

    private var totalCostText: String {
        String(format: "$%.2f", groups.reduce(0) { $0 + $1.totalCost })
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(toolDisplayName).font(.headline)
            Text("\(String(format: I18n.t("panel.repos_count"), groups.count)) · 共 \(totalCostText)")
                .font(.caption).foregroundColor(.secondary)
            Spacer()
            Picker("", selection: $sortByCost) {
                Text(I18n.t("panel.recent")).tag(false)
                Text(I18n.t("panel.most_expensive")).tag(true)
            }
            .pickerStyle(.segmented).frame(width: 160)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain).foregroundColor(.secondary)
        }
        .padding(12)
    }

    private func groupSection(_ group: RepoSessionGroup) -> some View {
        let collapsed = collapsedRepos.contains(group.repo)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { toggleCollapse(group.repo) }
            } label: {
                HStack {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    Text(group.repo == SessionStats.noRepoKey ? I18n.t("panel.no_repo_group") : group.repo)
                        .font(.caption).fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    Text("\(String(format: I18n.t("panel.sessions_count"), group.sessions.count)) · \(String(format: "$%.2f", group.totalCost))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

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
        rows.sorted { sortByCost ? $0.cost > $1.cost : $0.lastTs > $1.lastTs }
    }

    private func sessionRow(_ row: SessionRow) -> some View {
        let expanded = expandedSessionId == row.sessionId
        return HStack(spacing: 8) {
            Text(timeText(row.lastTs))
                .font(.caption2).foregroundColor(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(row.title ?? I18n.t("panel.no_title"))
                .font(.caption).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            occupancyBar(row)
            Text(String(format: "$%.2f", row.cost))
                .font(.caption).monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedSessionId = expanded ? nil : row.sessionId
            }
            if expandedSessionId == row.sessionId, let sid = row.sessionId {
                trend = nil
                Task { trend = await StatsService.turnSeries(source: row.source, sessionId: sid) }
            }
        }
    }

    @ViewBuilder
    private func trendCard(for row: SessionRow) -> some View {
        if let trend {
            VStack(alignment: .leading, spacing: 6) {
                contextChart(trend)
                HStack(spacing: 12) {
                    Text(String(format: I18n.t("panel.turns"), trend.turns.count))
                    Text(occupancyText(trend.finalOccupancy))
                    Text(String(format: I18n.t("panel.total_cost"), String(format: "$%.2f", trend.totalCost)))
                    Text(String(format: I18n.t("panel.cache_savings"), String(format: "$%.2f", cacheSavingsText(trend))))
                }
                .font(.caption2).foregroundColor(.secondary)
                if trend.needsCompactionHint {
                    Text(I18n.t("panel.compact_hint"))
                        .font(.caption2).foregroundColor(.orange)
                }
            }
            .padding(8)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        } else {
            ProgressView().controlSize(.small).padding(8)
        }
    }

    private func contextChart(_ trend: ContextTrend) -> some View {
        let maxInput = trend.turns.map(\.inputTokens).max() ?? 1
        let yMax = trend.windowTokens.map { max($0, maxInput) } ?? maxInput * 2
        return Chart {
            ForEach(trend.turns) { t in
                AreaMark(x: .value("turn", t.index), y: .value("input", t.inputTokens))
                    .foregroundStyle(Color.marsGreenLight.opacity(0.35))
                LineMark(x: .value("turn", t.index), y: .value("input", t.inputTokens))
                    .foregroundStyle(Color.marsGreen)
            }
            if let window = trend.windowTokens, window > 0 {
                RuleMark(y: .value("window", window))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.secondary)
            }
            ForEach(Array(trend.compactionIndexes), id: \.self) { idx in
                if let point = trend.turns.first(where: { $0.index == idx }) {
                    PointMark(x: .value("turn", idx), y: .value("input", point.inputTokens))
                        .foregroundStyle(Color.deepRed)
                }
            }
        }
        .chartYScale(domain: 0...yMax)
        .frame(height: 140)
    }

    private func occupancyBar(_ row: SessionRow) -> some View {
        let occ = row.finalOccupancy ?? 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(occColor(occ))
                    .frame(width: geo.size.width * CGFloat(min(occ, 1)))
            }
        }
        .frame(width: 40, height: 4)
    }

    private func load() async {
        let source = toolId == "codex" ? "codex" : "claude-code"
        let rows = await StatsService.sessionRows(source: source, sinceMs: sinceMs)
        await MainActor.run { groups = SessionStats.groupSessions(rows) }
    }

    private func toggleCollapse(_ repo: String) {
        if collapsedRepos.contains(repo) { collapsedRepos.remove(repo) } else { collapsedRepos.insert(repo) }
    }

    private func timeText(_ ts: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ts) / 1000))
    }

    private func occupancyText(_ occ: Double?) -> String {
        guard let occ else { return I18n.t("panel.occupancy_na") }
        return String(format: I18n.t("panel.occupancy"), Int(occ * 100))
    }

    private func occColor(_ occ: Double) -> Color {
        occ > 0.8 ? .orange : (occ > 0.5 ? .yellow : .marsGreen)
    }

    private func cacheSavingsText(_ trend: ContextTrend) -> Double {
        guard let model = trend.model,
              let pricing = PricingManager.shared.pricing(for: model)
        else { return 0 }
        return SessionStats.cacheSavings(
            cacheTokens: trend.cacheTokensTotal,
            inPricePerMtok: pricing.inPricePerMtok,
            cachePricePerMtok: pricing.cachePricePerMtok)
    }
}
