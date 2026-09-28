import XCTest
@testable import AIPulse

/// Some toolchains copy Localizable.xcstrings verbatim instead of compiling
/// per-locale tables; I18n then resolves languages straight from the catalog
/// JSON. These tests run the fallback resolver against the real catalog so a
/// schema surprise cannot break it silently.
final class I18nCatalogFallbackTests: XCTestCase {
    private static func catalogDocument() throws -> [String: Any] {
        // Tests/Fixtures → repo root is a few levels up from the test file.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let sampleKey = "pulse.activity.recent"

    func testResolvesEnglishInsteadOfReturningTheKey() throws {
        let doc = try Self.catalogDocument()
        let en = I18n.stringsFromCatalog(doc, lang: "en")
        let value = try XCTUnwrap(en[Self.sampleKey])
        XCTAssertFalse(value.isEmpty)
        XCTAssertNotEqual(value, Self.sampleKey)
    }

    func testResolvesEverySupportedLocale() throws {
        let doc = try Self.catalogDocument()
        for lang in ["en", "ja", "ko", "de", "fr", "es", "pt-BR", "zh-Hans", "zh-Hant-TW", "zh-Hant-HK"] {
            let dict = I18n.stringsFromCatalog(doc, lang: lang)
            let value = try XCTUnwrap(dict[Self.sampleKey], "\(lang) resolved nothing for the sample key")
            XCTAssertNotEqual(value, Self.sampleKey, "\(lang) fell through to the raw key")
        }
    }

    func testChineseResolvesIntoHanScript() throws {
        let doc = try Self.catalogDocument()
        let hans = I18n.stringsFromCatalog(doc, lang: "zh-Hans")
        let value = try XCTUnwrap(hans[Self.sampleKey])
        XCTAssertTrue(value.unicodeScalars.contains { $0.properties.isIdeographic },
                      "zh-Hans resolution should be Chinese text, got '\(value)'")
    }

    func testShouldTranslateFalseKeysAreExcluded() throws {
        let doc = try Self.catalogDocument()
        let en = I18n.stringsFromCatalog(doc, lang: "en")
        for (key, entryAny) in doc["strings"] as? [String: Any] ?? [:] {
            if (entryAny as? [String: Any])?["shouldTranslate"] as? Bool == false {
                XCTAssertNil(en[key], "format-only key \(key) must not leak into lookups")
            }
        }
    }

    func testMissingLocaleFallsBackToEnglish() throws {
        var doc = try Self.catalogDocument()
        doc["strings"] = [
            "bridge.only.en": [
                "localizations": ["en": ["stringUnit": ["state": "translated", "value": "Only English"]]],
            ],
        ]
        let dict = I18n.stringsFromCatalog(doc, lang: "ja")
        XCTAssertEqual(dict["bridge.only.en"], "Only English")
    }
}
