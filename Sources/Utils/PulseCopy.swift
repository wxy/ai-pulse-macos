import Foundation
import AIPulseShared

/// Converts PulseEngine's stable machine reasons into user-facing copy.
/// Raw identifiers remain in diagnostics and synced data, never in UI.
enum PulseCopy {
    static func localizedReason(_ reason: String, primarySignal: PulseSignalKind? = nil) -> String {
        if reason == "no_recent_signal" { return I18n.t("pulse.reason.no_recent_signal") }
        if reason == "recent_token_activity" { return I18n.t("pulse.reason.recent_token_activity") }
        if reason == "recent_observed_spend" { return I18n.t("pulse.reason.recent_observed_spend") }
        if reason == "recent_attributed_output" { return I18n.t("pulse.reason.recent_attributed_output") }
        if reason == "quota_unavailable_or_stale" { return I18n.t("pulse.reason.quota_unavailable_or_stale") }

        if reason.hasPrefix("quota_"), reason.hasSuffix("_percent"),
           let percent = reason.dropFirst("quota_".count).dropLast("_percent".count).split(separator: "_").first {
            return I18n.resolvedLang() == "zh-Hans"
                ? "额度已使用 \(percent)%"
                : "Quota is \(percent)% used"
        }

        if let factor = multiplier(in: reason, prefix: "token_rate_") {
            return I18n.resolvedLang() == "zh-Hans"
                ? "词元速率为平时的 \(factor) 倍"
                : "Token rate is \(factor)× your usual pace"
        }
        if let factor = multiplier(in: reason, prefix: "observed_spend_") {
            return I18n.resolvedLang() == "zh-Hans"
                ? "真实消费为平时的 \(factor) 倍"
                : "Observed spend is \(factor)× your usual pace"
        }
        if let factor = multiplier(in: reason, prefix: "attributed_output_") {
            return I18n.resolvedLang() == "zh-Hans"
                ? "归因产出为平时的 \(factor) 倍"
                : "Attributed output is \(factor)× your usual pace"
        }

        switch primarySignal {
        case .activity: return I18n.t("pulse.reason.token_rate")
        case .observedSpend: return I18n.t("pulse.reason.observed_spend")
        case .quota: return I18n.t("pulse.reason.quota_pressure")
        case .attributedOutput: return I18n.t("pulse.reason.attributed_output")
        case .none: return I18n.t("pulse.reason.no_recent_signal")
        }
    }

    private static func multiplier(in reason: String, prefix: String) -> String? {
        guard reason.hasPrefix(prefix), reason.hasSuffix("x") else { return nil }
        var raw = String(reason.dropFirst(prefix.count).dropLast())
        raw = raw.replacingOccurrences(of: "cold_start_", with: "")
        let pieces = raw.split(separator: "_")
        guard pieces.count == 2, pieces.allSatisfy({ Int($0) != nil }) else { return nil }
        return "\(pieces[0]).\(pieces[1])"
    }
}
