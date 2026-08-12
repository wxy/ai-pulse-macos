import SwiftUI

/// Tool detail sheet: three-line conclusion summary + session list.
/// Sessions expand to a profile card (no per-turn chart — macOS only).
struct ToolDetailSheetView: View {
    let detail: ToolDetailItem
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSessionId: String? = nil
    @State private var collapsedRepos: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    conclusionCard
                    if detail.sessions.isEmpty {
                        Text(I18n.t("tool.detail.no_sessions"))
                            .font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        sessionList
                    }
                }
                .padding()
            }
            .navigationTitle(I18n.t("tool.detail.title"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(I18n.t("tool.detail.done")) { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private var conclusionCard: some View {
        let c = detail.conclusion
        let delta = c.deltaPct
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: detail.source == "codex" ? "sparkles" : "bubble.left.and.bubble.right")
                    .foregroundColor(.accentColor)
                Text(detail.source == "codex" ? "ChatGPT" : "Claude Code")
                    .font(.headline)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                    Text(String(format: "%+.1f%%", delta))
                }
                .font(.caption2).fontWeight(.semibold).monospacedDigit()
                .foregroundColor(delta > 0 ? Color.deepRed : Color.marsGreen)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background((delta > 0 ? Color.deepRed : Color.marsGreen).opacity(0.12),
                            in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("$\(String(format: "%.2f", c.spend))")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.deepRed)
                Text(I18n.t("tool.detail.spend_label"))
                    .font(.caption).foregroundColor(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                      alignment: .leading, spacing: 10) {
                statCell(I18n.t("tool.detail.sessions_label"),
                         String(format: "%d", c.sessionCount))
                statCell(I18n.t("tool.detail.commits_label"),
                         String(format: "%d", c.commitCount))
                statCell(I18n.t("tool.detail.lines_label"),
                         String(format: "+%d/-%d", c.addedLines, c.deletedLines))
                statCell(I18n.t("tool.detail.avg_cost_label"),
                         "$\(String(format: "%.2f", c.avgCostPerSession))")
                statCell(I18n.t("tool.detail.cpl_label"),
                         String(format: "%.2f", c.cpl))
                statCell(I18n.t("tool.detail.projected_label"),
                         c.projectedMonth > 0 ? "$\(String(format: "%.0f", c.projectedMonth))" : "—")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.caption).fontWeight(.semibold).monospacedDigit()
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18n.t("tool.detail.sessions")).font(.caption).foregroundColor(.secondary)
            ForEach(groups) { group in
                groupSection(group)
            }
        }
    }

    private struct RepoGroup: Identifiable {
        var id: String { repo }
        let repo: String
        let sessions: [ToolSessionItem]
        var totalCost: Double { sessions.reduce(0) { $0 + $1.cost } }
    }

    private var groups: [RepoGroup] {
        Dictionary(grouping: detail.sessions, by: { $0.repo ?? I18n.t("tool.detail.no_repo") })
            .map { RepoGroup(repo: $0.key, sessions: $0.value) }
            .sorted { $0.totalCost > $1.totalCost }
    }

    private func groupSection(_ group: RepoGroup) -> some View {
        let collapsed = collapsedRepos.contains(group.repo)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if collapsed {
                        collapsedRepos.remove(group.repo)
                    } else {
                        collapsedRepos.insert(group.repo)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .foregroundColor(.accentColor.opacity(0.8))
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.caption2).foregroundColor(.secondary)
                        Text(group.repo)
                            .font(.caption).fontWeight(.semibold)
                            .lineLimit(3)
                        Spacer(minLength: 0)
                    }
                    Text(String(format: I18n.t("tool.detail.group_header"),
                                group.sessions.count,
                                "$\(String(format: "%.2f", group.totalCost))"))
                        .font(.caption2).foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)

            if !collapsed {
                ForEach(group.sessions, id: \.sessionId) { row in
                    sessionRow(row)
                    if expandedSessionId == row.sessionId {
                        profileCard(row)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func sessionRow(_ row: ToolSessionItem) -> some View {
        let expanded = expandedSessionId == row.sessionId
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(row.title ?? I18n.t("tool.detail.no_title"))
                    .font(.caption).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("$\(String(format: "%.2f", row.cost))")
                    .font(.caption).monospacedDigit()
                    .fontWeight(expanded ? .semibold : .regular)
                    .foregroundColor(expanded ? Color.accentColor : Color.primary)
            }
            HStack(spacing: 8) {
                Text(row.lastTs > 0 ? Date(timeIntervalSince1970: Double(row.lastTs) / 1000).formatted(date: .abbreviated, time: .shortened) : "")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                occupancyBar(row)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(expanded ? Color.accentColor.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedSessionId = expanded ? nil : row.sessionId
            }
        }
    }

    private func occupancyBar(_ row: ToolSessionItem) -> some View {
        let occ = row.windowTokens.flatMap { w in w > 0 ? Double(row.lastInput) / Double(w) : nil }
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.1)).frame(width: 40, height: 5)
            Capsule().fill(occ.map { $0 > 0.8 ? Color.orange : ($0 > 0.5 ? Color.yellow : Color.marsGreen) } ?? Color.primary.opacity(0.2))
                .frame(width: 40 * CGFloat(min(occ ?? 0, 1)), height: 5)
        }
    }

    private func profileCard(_ row: ToolSessionItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                metric(I18n.t("tool.detail.turns_label"),
                       String(format: "%d", row.turnCount))
                Spacer()
                metric(I18n.t("tool.detail.compactions_label"),
                       String(format: "%d", row.compactionCount))
            }
            HStack(spacing: 14) {
                metric(I18n.t("tool.detail.avg_cache_label"),
                       row.avgCacheRatio.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                Spacer()
                metric(I18n.t("tool.detail.avg_occupancy_label"),
                       row.avgOccupancy.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
            }
            Divider()
            Label(I18n.t("tool.detail.macos_note"), systemImage: "macwindow")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.caption).fontWeight(.semibold).monospacedDigit()
        }
    }
}
