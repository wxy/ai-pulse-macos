import Foundation
import UserNotifications
import AIPulseShared

struct ClosingBellSummary: Codable, Equatable {
    let tier: PulseTier
    let reason: String
    let activityTokens: Int64
    let observedSpend: [ObservedSpendItem]
    let quotaPercent: Double?
    let attributedLines: Int

    var hasActivity: Bool {
        activityTokens > 0 || observedSpend.contains { $0.amount > 0 }
            || attributedLines > 0 || quotaPercent != nil
    }
}

/// One daily, fact-preserving recap. Notification delivery and sound are only
/// optional transports: the same text is persisted for an in-app fallback.
enum ClosingBell {
    static let lastSummaryKey = "closing_bell_last_summary"
    static let lastSummaryDataKey = "closing_bell_last_summary_data"
    static let lastSummaryDateKey = "closing_bell_last_summary_date"

    static func body(_ summary: ClosingBellSummary) -> String {
        var parts = ["\(I18n.t("pulse.tier.\(summary.tier.rawValue)")) · \(PulseCopy.localizedReason(summary.reason))"]
        if summary.activityTokens > 0 {
            parts.append("\(ChartMath.compactCount(summary.activityTokens)) \(I18n.t("pulse.unit.tokens"))")
        }
        parts.append(contentsOf: summary.observedSpend.filter { $0.amount.isFinite && $0.amount > 0 }.map {
            "\($0.currency.uppercased()) \(String(format: "%.2f", $0.amount)) \(I18n.t("pulse.fact.observed"))"
        })
        if let quota = summary.quotaPercent, quota.isFinite {
            parts.append("\(I18n.t("pulse.fact.quota")) \(Int(min(max(quota, 0), 100).rounded()))%")
        }
        if summary.attributedLines > 0 {
            parts.append("\(summary.attributedLines) \(I18n.t("pulse.fact.attributed_lines"))")
        }
        return parts.joined(separator: " · ")
    }

    static func lastSummary(defaults: UserDefaults = .standard) -> String? {
        if let data = defaults.data(forKey: lastSummaryDataKey),
           let summary = try? JSONDecoder().decode(ClosingBellSummary.self, from: data) {
            return body(summary)
        }
        // Legacy versions persisted a final sentence in whichever language was
        // active at fire time. It cannot be safely relocalized, so hide it until
        // the next structured daily close instead of mixing languages in menus.
        return nil
    }

    @MainActor static func fire(summary: ClosingBellSummary, at now: Date = Date()) async {
        guard summary.hasActivity else { return }
        let text = body(summary)
        if let data = try? JSONEncoder().encode(summary) {
            UserDefaults.standard.set(data, forKey: lastSummaryDataKey)
        }
        // Keep the legacy string while older builds may still read this defaults
        // domain; current builds prefer and re-render the structured payload.
        UserDefaults.standard.set(text, forKey: lastSummaryKey)
        UserDefaults.standard.set(now, forKey: lastSummaryDateKey)
        NotificationCenter.default.post(name: .dataDidChange, object: nil)

        let settings = SoundSettings.current()
        let isQuiet = CoinSound.isQuietTime(now, settings: settings)
        if !isQuiet {
            CoinSound.playDecision(.chime, settings: settings)
        }

        guard Bundle.main.bundleIdentifier != nil else { return }
        guard SystemNotifications.isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let auth = await center.notificationSettings()
        guard auth.authorizationStatus == .authorized || auth.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = I18n.t("closing_bell_notif.title")
        content.body = text
        content.sound = (!isQuiet && settings.enabled && !settings.muted) ? .default : nil
        let req = UNNotificationRequest(
            identifier: "ai-pulse-closing-\(Int(now.timeIntervalSince1970))",
            content: content, trigger: nil)
        try? await center.add(req)
    }

}
