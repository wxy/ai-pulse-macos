import XCTest
@testable import AIPulse

final class I18nResolutionTests: XCTestCase {
    func testSystemLanguageUsesFirstSupportedLanguageAndNormalizesRegions() {
        XCTAssertEqual(I18n.resolveSystemLanguage(["it-IT", "ja-JP", "en-US"]), "ja")
        XCTAssertEqual(I18n.resolveSystemLanguage(["zh-Hant-HK"]), "zh-Hant-HK")
        XCTAssertEqual(I18n.resolveSystemLanguage(["zh-HK"]), "zh-Hant-HK")
        XCTAssertEqual(I18n.resolveSystemLanguage(["zh-TW"]), "zh-Hant-TW")
        XCTAssertEqual(I18n.resolveSystemLanguage(["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(I18n.resolveSystemLanguage([]), "en")
    }

    func testSupportedLanguageSetIncludesTenLocalesPlusAutomaticSelection() {
        XCTAssertEqual(
            I18n.supportedLanguages.map(\.code),
            ["auto", "en", "zh-Hans", "zh-Hant-TW", "zh-Hant-HK", "ja", "ko", "de", "fr", "es", "pt-BR"]
        )
    }

    func testAutoClearsTheApplicationOverrideAndUsesGlobalLanguage() {
        let defaults = UserDefaults.standard
        let oldPreference = defaults.object(forKey: "app_language")
        let oldOverride = defaults.object(forKey: "AppleLanguages")
        let oldLanguage = I18n.getLang()
        defer {
            I18n.setLang(oldLanguage)
            defaults.set(oldPreference, forKey: "app_language")
            defaults.set(oldOverride, forKey: "AppleLanguages")
        }
        I18n.setLang("en")
        XCTAssertEqual(I18n.resolvedLang(), "en")
        I18n.setLang("auto")
        let appDomain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) }
        XCTAssertNil(appDomain?["AppleLanguages"])
        if let system = defaults.persistentDomain(forName: "NSGlobalDomain")?["AppleLanguages"] as? [String] {
            XCTAssertEqual(I18n.resolvedLang(), I18n.resolveSystemLanguage(system))
        }
    }

}
