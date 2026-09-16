// AIPulseWatchWidget.swift — watchOS 表盘小组件（v2 §3.3 全端感知）
//
// 自包含实现：不链接 AIPulseShared，本地定义最小解码结构；载荷常量与
// Packages/AIPulseShared 的 CKSchema 保持一致（改动时两处同步）。
// 数据源：iCloud 私有库 DashboardCache_v2 / snapshot-today（Mac 每 5 分钟写）。

import WidgetKit
import SwiftUI
import CloudKit

// MARK: - 载荷常量（与 AIPulseShared.CKSchema 一致）

private enum Schema {
    static let recordType = "DashboardCache_v2"
    static let payloadVersion = "2.0.0"
    static let todayRecordName = "snapshot-today"
    static let jsonField = "json"
}

// MARK: - 最小解码结构（JSONDecoder 忽略未知键，缺键给默认值）

private struct Snapshot: Codable {
    struct Pulse: Codable {
        struct Signal: Codable {
            var kind: String
            var normalized: Double
        }
        var tier: String
        var primarySignal: String?
        var reason: String
        var signals: [Signal]
    }
    struct Spend: Codable {
        var amount: Double
        var currency: String
    }
    var pulse: Pulse?
    var observedSpend: [Spend]?
    var updatedAt: Date?
}

// MARK: - Timeline entry

struct BurnEntry: TimelineEntry {
    let date: Date
    let tier: String?
    let reason: String
    let normalized: Double
    let observedSpend: String?
}

// MARK: - CloudKit reader

private enum BurnSnapshotReader {
    static func loadToday() async -> BurnEntry {
        let fallback = BurnEntry(date: Date(), tier: nil,
                                 reason: pulseReasonText("no_recent_signal", primarySignal: nil),
                                 normalized: 0, observedSpend: nil)
        let container = CKContainer(identifier: "iCloud.com.wxy.aipulse")
        guard let status = try? await container.accountStatus(),
              status == .available else { return fallback }
        do {
            let id = CKRecord.ID(recordName: Schema.todayRecordName)
            let record = try await container.privateCloudDatabase.record(for: id)
            guard let json = record[Schema.jsonField] as? String,
                  let snap = try? JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
            else { return fallback }
            if let pulse = snap.pulse {
                let score = pulse.primarySignal.flatMap { primary in
                    pulse.signals.first { $0.kind == primary }?.normalized
                } ?? 0
                let money = snap.observedSpend?.filter { $0.amount > 0 }
                    .map { "\($0.currency.uppercased()) \(String(format: "%.2f", $0.amount))" }
                    .joined(separator: " + ")
                return BurnEntry(date: snap.updatedAt ?? Date(), tier: pulse.tier,
                                 reason: pulseReasonText(pulse.reason, primarySignal: pulse.primarySignal),
                                 normalized: score, observedSpend: money?.isEmpty == false ? money : nil)
            }
            return fallback
        } catch {
            return fallback
        }
    }
}

// MARK: - Provider

struct BurnProvider: TimelineProvider {
    func placeholder(in context: Context) -> BurnEntry {
        BurnEntry(date: Date(), tier: "active",
                  reason: pulseReasonText("recent_token_activity", primarySignal: "activity"),
                  normalized: 1.1, observedSpend: "USD 3.20")
    }

    func getSnapshot(in context: Context, completion: @escaping (BurnEntry) -> Void) {
        Task { completion(await BurnSnapshotReader.loadToday()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BurnEntry>) -> Void) {
        Task {
            let entry = await BurnSnapshotReader.loadToday()
            // 系统预算本就稀疏（约 15–60 分钟）；再约定 15 分钟后重取
            completion(Timeline(entries: [entry],
                                policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }
}

// MARK: - 档位颜色

private func tierColor(_ tier: String?) -> Color {
    switch tier {
    case "intense", "blaze": return .red
    case "elevated", "hot": return .orange
    case "active", "normal": return .yellow
    default: return .secondary
    }
}

private func shortUSD(_ value: Double) -> String {
    value >= 100 ? String(format: "%.0f", value) : String(format: "%.2f", value)
}

private var usesSimplifiedChinese: Bool {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        && !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh-Hant")
}

private func tierText(_ tier: String?) -> String {
    guard let tier else { return usesSimplifiedChinese ? "平静" : "Resting" }
    guard usesSimplifiedChinese else { return tier.capitalized }
    return ["resting": "平静", "active": "活跃", "elevated": "升高", "intense": "强烈"][tier] ?? "平静"
}

private func pulseReasonText(_ reason: String, primarySignal: String?) -> String {
    if reason.hasPrefix("token_rate_"), reason.hasSuffix("x") {
        let raw = String(reason.dropFirst("token_rate_".count).dropLast())
            .replacingOccurrences(of: "cold_start_", with: "")
        let pieces = raw.split(separator: "_")
        if pieces.count == 2, pieces.allSatisfy({ Int($0) != nil }) {
            let factor = "\(pieces[0]).\(pieces[1])"
            return usesSimplifiedChinese
                ? "词元速率为平时的 \(factor) 倍"
                : "Token rate is \(factor)× your usual pace"
        }
    }
    if reason.hasPrefix("quota_"), reason.hasSuffix("_percent") {
        let value = reason.dropFirst(6).dropLast(8).split(separator: "_").first ?? "0"
        return usesSimplifiedChinese ? "额度已使用 \(value)%" : "Quota is \(value)% used"
    }
    switch primarySignal {
    case "activity": return usesSimplifiedChinese ? "近期词元活动仍在持续" : "Recent token activity continues"
    case "observedSpend": return usesSimplifiedChinese ? "近期记录到真实消费" : "Recent observed spend"
    case "quota": return usesSimplifiedChinese ? "服务商额度正在承受压力" : "A provider quota is under pressure"
    case "attributedOutput": return usesSimplifiedChinese ? "近期产生了可归因代码变化" : "Recent attributed code changes"
    default: return usesSimplifiedChinese ? "近期没有 AI 活动" : "No recent AI activity"
    }
}

// MARK: - 视图

struct BurnCircularView: View {
    let entry: BurnEntry

    var body: some View {
        let fraction = min(max(entry.normalized / 3, 0), 1)
        Gauge(value: fraction) {
            Image(systemName: "flame.fill")
        } currentValueLabel: {
            Text(entry.tier.map { String($0.prefix(1)).uppercased() } ?? "–")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircular)
        .tint(tierColor(entry.tier))
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct BurnRectangularView: View {
    let entry: BurnEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(tierColor(entry.tier))
                Text("AI Pulse")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            Text(tierText(entry.tier))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7).lineLimit(1)
            if let money = entry.observedSpend {
                Text(money)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(tierColor(entry.tier))
            } else {
                Text(entry.reason).font(.caption2).foregroundColor(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct BurnInlineView: View {
    let entry: BurnEntry

    var body: some View {
        Text("● \(tierText(entry.tier))")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct BurnWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BurnEntry

    var body: some View {
        switch family {
        case .accessoryCircular: BurnCircularView(entry: entry)
        case .accessoryRectangular: BurnRectangularView(entry: entry)
        default: BurnInlineView(entry: entry)
        }
    }
}

// MARK: - Widget + Bundle

struct AIPulseWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AIPulseWatchBurn", provider: BurnProvider()) { entry in
            BurnWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Pulse 脉搏")
        .description("当前 AI 消费压力与主要原因")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct AIPulseWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        AIPulseWatchWidget()
    }
}
