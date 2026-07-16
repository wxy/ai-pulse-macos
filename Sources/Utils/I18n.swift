import Foundation

enum I18n {
    static let didChangeLanguage = Notification.Name("I18nDidChangeLanguage")

    private static let langKey = "app_language"
    private static let langLock = NSLock()
    private static nonisolated(unsafe) var _currentLang: String?

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
        langLock.unlock()
        UserDefaults.standard.set(lang, forKey: langKey)
        if lang == "auto" {
            // Remove override — let system language take effect
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }
        NotificationCenter.default.post(name: didChangeLanguage, object: nil)
    }

    /// Get the stored language preference. "auto" = follow system; nil → auto.
    /// Resolved language for actual display can differ from this value.
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
    /// Used internally when we need to know which language is actually active.
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

    /// Localized string for key. Reads from compiled .xcstrings via Bundle.
    /// Bundle uses AppleLanguages (or system locale if "auto") to pick language.
    static func t(_ key: String) -> String {
        return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}
