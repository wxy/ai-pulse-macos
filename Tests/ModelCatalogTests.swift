import XCTest
@testable import AIPulse

final class ModelCatalogTests: XCTestCase {
    func testBundledCatalogContainsIdentificationOnly() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/model-catalog.json")
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
        XCTAssertFalse(catalog.models.isEmpty)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [String: [String: Any]])
        for model in models.values {
            XCTAssertEqual(Set(model.keys), Set(["provider", "name"]))
        }
        XCTAssertEqual(CostConfidence.declared.rawValue, "declared")
        XCTAssertNil(CostConfidence(rawValue: "estimated"))
        XCTAssertNil(CostConfidence(rawValue: "amortized"))
    }

    func testNormalizeStripsProviderPrefix() {
        XCTAssertEqual(ModelCatalogManager.normalize("anthropic/claude-sonnet-4-20250514"), "claude-sonnet-4")
        XCTAssertEqual(ModelCatalogManager.normalize("openai/gpt-4o"), "gpt-4o")
    }

    func testNormalizeStripsTrailingDate() {
        XCTAssertEqual(ModelCatalogManager.normalize("claude-sonnet-4-20250514"), "claude-sonnet-4")
        XCTAssertEqual(ModelCatalogManager.normalize("deepseek-v4-pro"), "deepseek-v4-pro")
    }

    func testNormalizeStripsTrailingVersion() {
        XCTAssertEqual(ModelCatalogManager.normalize("claude-sonnet-4-v2"), "claude-sonnet-4")
    }

    func testNormalizeHandlesDateSuffix() {
        // The catalog doesn't need to strip YYYY-MM-DD; model names in logs
        // usually use compact dates like 20240806 or date-less names
        XCTAssertTrue(ModelCatalogManager.normalize("gpt-4o-2024-08-06").hasPrefix("gpt-4o"))
    }

    func testNormalizeHandlesPlainNames() {
        XCTAssertEqual(ModelCatalogManager.normalize("deepseek-v4-pro"), "deepseek-v4-pro")
        XCTAssertEqual(ModelCatalogManager.normalize("gemini-2.5-pro"), "gemini-2.5-pro")
    }

    func testProviderIdForDeepSeek() {
        XCTAssertEqual(ModelCatalogManager.shared.providerId(for: "deepseek-v4-pro"), "deepseek")
    }

    func testUnknownAndKnownVendorNamesDoNotRequirePrices() {
        XCTAssertEqual(ModelCatalogManager.shared.providerId(for: "glm-5.3-flash"), "zhipu")
        XCTAssertNil(ModelCatalogManager.shared.descriptor(for: "nonexistent-model-xyz"))
        XCTAssertNil(ModelCatalogManager.shared.providerId(for: nil))
        XCTAssertEqual(ModelCatalogManager.shared.descriptor(for: "claude-sonnet-4")?.provider, "anthropic")
    }
}
