import Foundation

enum I18n {
    static let didChangeLanguage = Notification.Name("I18nDidChangeLanguage")

    private static let langKey = "app_language"
    private static let langLock = NSLock()
    private static nonisolated(unsafe) var _currentLang: String?
    private static nonisolated(unsafe) var _cachedStrings: [String: String]?
    private static nonisolated(unsafe) var _cacheLang: String?

    /// All languages the app supports (for Settings picker).
    /// Tag is the language code; label is shown in native script.
    static let supportedLanguages: [(code: String, label: String)] = [
        ("auto",           "跟随系统 / Follow System"),  // placeholder — UI uses t("settings.language_auto")
        ("en",             "English"),
        ("zh-Hans",        "简体中文"),
        ("zh-Hant-TW",     "繁體中文（台灣）"),
        ("zh-Hant-HK",     "繁體中文（香港）"),
        ("ja",             "日本語"),
        ("ko",             "한국어"),
        ("de",             "Deutsch"),
        ("fr",             "Français"),
        ("es",             "Español"),
        ("pt-BR",          "Português (Brasil)"),
    ]

    /// Set the app language. "auto" = follow system; otherwise an explicit code.
    /// Posts `didChangeLanguage` notification so views rebuild.
    static func setLang(_ lang: String) {
        langLock.lock()
        _currentLang = lang
        _cachedStrings = nil  // force reload on next t()
        _cacheLang = nil
        langLock.unlock()
        UserDefaults.standard.set(lang, forKey: langKey)
        if lang == "auto" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }
        NotificationCenter.default.post(name: didChangeLanguage, object: nil)
    }

    /// Get the stored language preference. "auto" = follow system; nil → auto.
    static func getLang() -> String {
        langLock.lock()
        if let l = _currentLang { langLock.unlock(); return l }
        langLock.unlock()

        let saved = UserDefaults.standard.string(forKey: langKey)
        let lang = saved ?? "auto"

        langLock.lock()
        _currentLang = lang
        langLock.unlock()
        return lang
    }

    /// The effectively resolved language code (never "auto").
    static func resolvedLang() -> String {
        let stored = getLang()
        if stored != "auto" { return stored }
        let preferred = Locale.preferredLanguages.first ?? ""
        if preferred.hasPrefix("zh-Hant-HK") { return "zh-Hant-HK" }
        if preferred.hasPrefix("zh-Hant")    { return "zh-Hant-TW" }
        if preferred.hasPrefix("zh")         { return "zh-Hans" }
        if preferred.hasPrefix("ja")         { return "ja" }
        if preferred.hasPrefix("ko")         { return "ko" }
        if preferred.hasPrefix("de")         { return "de" }
        if preferred.hasPrefix("fr")         { return "fr" }
        if preferred.hasPrefix("es")         { return "es" }
        if preferred.hasPrefix("pt")         { return "pt-BR" }
        return "en"
    }

    /// The Locale matching the resolved language (for date/number formatting).
    static var resolvedLocale: Locale {
        switch resolvedLang() {
        case "zh-Hans":    return Locale(identifier: "zh_CN")
        case "zh-Hant-TW": return Locale(identifier: "zh_TW")
        case "zh-Hant-HK": return Locale(identifier: "zh_HK")
        case "ja":         return Locale(identifier: "ja_JP")
        case "ko":         return Locale(identifier: "ko_KR")
        case "de":         return Locale(identifier: "de_DE")
        case "fr":         return Locale(identifier: "fr_FR")
        case "es":         return Locale(identifier: "es_ES")
        case "pt-BR":      return Locale(identifier: "pt_BR")
        default:           return Locale(identifier: "en_US")
        }
    }

    /// Load compiled .strings from bundle for a given language code.
    private static func loadStrings(for lang: String) -> [String: String] {
        guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: "\(lang).lproj"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String] else {
            return [:]
        }
        return dict
    }

    /// Localized string for key. Reads from compiled .strings files in the bundle,
    /// cached in memory for performance. Falls back: target lang → en → key itself.
    static func t(_ key: String) -> String {
        let target = resolvedLang()

        langLock.lock()
        if _cacheLang != target || _cachedStrings == nil {
            _cachedStrings = loadStrings(for: target)
            _cacheLang = target
        }
        let dict = _cachedStrings ?? [:]
        langLock.unlock()

        if let v = dict[key] { return v }

        // Fallback to English
        if target != "en", let enPath = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: "en.lproj"),
           let enDict = NSDictionary(contentsOfFile: enPath) as? [String: String],
           let v = enDict[key] { return v }

        return key
    }
}
