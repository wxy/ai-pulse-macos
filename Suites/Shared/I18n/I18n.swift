import Foundation
import AIPulseShared

/// Shared i18n for iOS/watchOS. The String Catalog is the sole translation
/// source for every client and extension.
enum I18n {

    /// Auto-follows system language.
    static var lang: String {
        let pref = Locale.preferredLanguages.first ?? "en"
        if pref.hasPrefix("zh-Hant-HK") { return "zh-Hant-HK" }
        if pref.hasPrefix("zh-Hant")    { return "zh-Hant-TW" }
        if pref.hasPrefix("zh")         { return "zh-Hans" }
        if pref.hasPrefix("ja")         { return "ja" }
        if pref.hasPrefix("ko")         { return "ko" }
        if pref.hasPrefix("de")         { return "de" }
        if pref.hasPrefix("fr")         { return "fr" }
        if pref.hasPrefix("es")         { return "es" }
        if pref.hasPrefix("pt")         { return "pt-BR" }
        return "en"
    }

    private static var locale: Locale {
        switch lang {
        case "zh-Hans": return Locale(identifier: "zh_CN")
        case "zh-Hant-TW": return Locale(identifier: "zh_TW")
        case "zh-Hant-HK": return Locale(identifier: "zh_HK")
        case "ja": return Locale(identifier: "ja_JP")
        case "ko": return Locale(identifier: "ko_KR")
        case "de": return Locale(identifier: "de_DE")
        case "fr": return Locale(identifier: "fr_FR")
        case "es": return Locale(identifier: "es_ES")
        case "pt-BR": return Locale(identifier: "pt_BR")
        default: return Locale(identifier: "en_US")
        }
    }

    /// Formats a unit-interval ratio according to the active app language.
    static func percent(_ ratio: Double, fractionDigits: Int = 0) -> String {
        let safeRatio = ratio.isFinite ? ratio : 0
        return safeRatio.formatted(
            .percent
                .precision(.fractionLength(fractionDigits))
                .locale(locale)
        )
    }

    static func prototype(_ simplifiedChinese: String, _ english: String) -> String {
        let localized = Bundle.main.localizedString(forKey: english, value: english, table: nil)
        if localized != english || lang == "en" { return localized }
        if lang.hasPrefix("zh-Hant") {
            return simplifiedChinese.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? simplifiedChinese
        }
        return lang == "zh-Hans" ? simplifiedChinese : english
    }

    static func t(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    static func pulseTier(_ tier: PulseTier) -> String {
        switch tier {
        case .resting: return prototype("平静", "Resting")
        case .active: return prototype("活跃", "Active")
        case .elevated: return prototype("升高", "Elevated")
        case .intense: return prototype("强烈", "Intense")
        }
    }

    static func pulseReason(_ pulse: PulseSnapshot) -> String {
        let reason = pulse.reason
        if let factor = multiplier(in: reason, prefix: "token_rate_") {
            let format = prototype("词元速率为平时的 %@ 倍", "Token rate is %@× your usual pace")
            return String(format: format, factor)
        }
        if reason.hasPrefix("quota_"), reason.hasSuffix("_percent") {
            let value = reason.dropFirst(6).dropLast(8).split(separator: "_").first ?? "0"
            let formatted = percent((Double(value) ?? 0) / 100)
            return String(format: t("pulse.reason.quota_used"), formatted)
        }
        switch pulse.primarySignal {
        case .activity: return prototype("AI 活动高于平时节奏", "AI activity is above your usual pace")
        case .observedSpend: return prototype("真实消费高于平时节奏", "Observed spend is above your usual pace")
        case .quota: return prototype("服务商额度正在承受压力", "A provider quota is under pressure")
        case .attributedOutput: return prototype("归因产出高于平时节奏", "Attributed output is above your usual pace")
        case .none: return prototype("近期没有 AI 活动", "No recent AI activity")
        }
    }

    private static func multiplier(in reason: String, prefix: String) -> String? {
        guard reason.hasPrefix(prefix), reason.hasSuffix("x") else { return nil }
        let raw = String(reason.dropFirst(prefix.count).dropLast())
            .replacingOccurrences(of: "cold_start_", with: "")
        let pieces = raw.split(separator: "_")
        guard pieces.count == 2, pieces.allSatisfy({ Int($0) != nil }) else { return nil }
        return "\(pieces[0]).\(pieces[1])"
    }
}
