import SwiftUI

/// Tool detail sheet: three-line conclusion summary + session list.
/// Sessions expand to a profile card (no per-turn chart — macOS only).
struct ToolDetailSheetView: View {
    let detail: ToolDetailItem
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSessionId: String? = nil

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
            Text(detail.source == "codex" ? "ChatGPT" : "Claude Code")
                .font(.headline)
            Text(String(format: I18n.t("tool.detail.spend"), "$\(String(format: "%.2f", c.spend))"))
                .font(.title3).fontWeight(.bold)
            Text(String(format: I18n.t("tool.detail.delta"), String(format: "%+.1f%%", delta)))
                .font(.caption).foregroundColor(delta > 0 ? Color.deepRed : Color.marsGreen)
            HStack(spacing: 10) {
                Text(String(format: I18n.t("tool.detail.sessions_count"), c.sessionCount))
                Text(String(format: I18n.t("tool.detail.commits"), c.commitCount))
                Text(String(format: I18n.t("tool.detail.lines"), c.addedLines, c.deletedLines))
            }
            .font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 10) {
                Text(String(format: I18n.t("tool.detail.avg_cost"), "$\(String(format: "%.2f", c.avgCostPerSession))"))
                Text(String(format: I18n.t("tool.detail.cpl"), String(format: "%.2f", c.cpl)))
                if c.projectedMonth > 0 {
                    Text(String(format: I18n.t("tool.detail.projected"), "$\(String(format: "%.0f", c.projectedMonth))"))
                }
            }
            .font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18n.t("tool.detail.sessions")).font(.caption).foregroundColor(.secondary)
            ForEach(detail.sessions, id: \.sessionId) { row in
                sessionRow(row)
                if expandedSessionId == row.sessionId {
                    profileCard(row)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func sessionRow(_ row: ToolSessionItem) -> some View {
        let expanded = expandedSessionId == row.sessionId
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(row.title ?? I18n.t("tool.detail.no_title"))
                    .font(.caption).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                occupancyBar(row)
                Text("$\(String(format: "%.2f", row.cost))")
                    .font(.caption).monospacedDigit()
                    .foregroundColor(expanded ? Color.accentColor : Color.primary)
            }
            Text("\(row.lastTs > 0 ? Date(timeIntervalSince1970: Double(row.lastTs) / 1000).formatted(date: .abbreviated, time: .shortened) : "") · \(row.repo ?? I18n.t("tool.detail.no_repo"))")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(expanded ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
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
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: I18n.t("tool.detail.turns"), row.turnCount))
            Text(String(format: I18n.t("tool.detail.avg_occupancy"), row.avgOccupancy.map { String(format: "%.0f%%", $0 * 100) } ?? "—"))
            Text(String(format: I18n.t("tool.detail.avg_cache"), row.avgCacheRatio.map { String(format: "%.0f%%", $0 * 100) } ?? "—"))
            Text(String(format: I18n.t("tool.detail.compactions"), row.compactionCount))
            Text(I18n.t("tool.detail.macos_note"))
                .font(.caption2).foregroundColor(.secondary)
        }
        .font(.caption)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
