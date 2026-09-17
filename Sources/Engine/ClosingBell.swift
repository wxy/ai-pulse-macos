import Foundation
import UserNotifications
import AIPulseShared

struct ClosingBellSummary: Codable, Equatable {
    let tier: PulseTier
    let reason: String
    let activityTokens: Int64?
    let observedSpend: [ObservedSpendItem]
    let quotaPercent: Double?
    let changedLines: Int?
    var commits: Int? = nil

    var hasActivity: Bool {
        (activityTokens ?? 0) > 0 || observedSpend.contains { $0.amount.isFinite && $0.amount > 0 }
            || (changedLines ?? 0) > 0 || (commits ?? 0) > 0 || quotaPercent != nil
    }
}

/// One daily, fact-preserving recap. Notification delivery and sound are only
/// optional transports: the same text is persisted for an in-app fallback.
enum ClosingBell {
    static let lastSummaryDataKey = "closing_bell_last_summary_v2_facts"
    static let lastSummaryDateKey = "closing_bell_last_summary_date"

    /// Claim immediately before delivery, after asynchronous reads finish.
    /// Main-actor serialization prevents competing tasks from both winning.
    @MainActor static func claimDailyDelivery(for dayStart: Date, at now: Date = Date(),
                                              calendar: Calendar = .current,
                                              defaults: UserDefaults = .standard) -> Bool {
        guard calendar.startOfDay(for: now) == dayStart,
              defaults.object(forKey: "closing_bell_enabled") as? Bool ?? true else { return false }
        let closingMinutes = SoundSettings.parseHM(defaults.string(forKey: "closing_bell_time") ?? "21:30")
            ?? 21 * 60 + 30
        let minutesNow = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard minutesNow >= closingMinutes else { return false }
        let key = String(Int64(dayStart.timeIntervalSince1970 * 1000))
        guard defaults.string(forKey: "closing_bell_last_fired") != key else { return false }
        defaults.set(key, forKey: "closing_bell_last_fired")
        return true
    }

    static func body(_ summary: ClosingBellSummary) -> String {
        var parts = ["\(I18n.t("pulse.tier.\(summary.tier.rawValue)")) · \(PulseCopy.localizedReason(summary.reason))"]
        if let tokens = summary.activityTokens, tokens > 0 {
            parts.append("\(ChartMath.compactCount(tokens)) \(I18n.t("pulse.unit.tokens"))")
        }
        parts.append(contentsOf: summary.observedSpend.filter { $0.amount.isFinite && $0.amount > 0 }.map {
            "\($0.currency.uppercased()) \(String(format: "%.1f", $0.amount)) \(I18n.t("pulse.fact.observed"))"
        })
        if let quota = summary.quotaPercent, quota.isFinite {
            parts.append("\(I18n.t("pulse.fact.quota")) \(Int(min(max(quota, 0), 100).rounded()))%")
        }
        if let lines = summary.changedLines, lines > 0 {
            parts.append("\(ChartMath.compactCount(Int64(lines))) \(I18n.t("pulse.fact.code_changes"))")
        }
        if let commits = summary.commits, commits > 0 {
            parts.append("\(ChartMath.compactCount(Int64(commits))) \(I18n.t("menu.commits"))")
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
        // The sound pack's chime above is the single audible closing signal.
        // Notification delivery must not add a second, unrelated system ding.
        content.sound = nil
        let req = UNNotificationRequest(
            identifier: "ai-pulse-closing-\(Int(now.timeIntervalSince1970))",
            content: content, trigger: nil)
        try? await center.add(req)
    }

}
