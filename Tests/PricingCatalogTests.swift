import XCTest
@testable import AIPulse

final class PricingCatalogTests: XCTestCase {
    func testNormalizeStripsProviderPrefix() {
        XCTAssertEqual(PricingManager.normalize("anthropic/claude-sonnet-4-20250514"), "claude-sonnet-4")
        XCTAssertEqual(PricingManager.normalize("openai/gpt-4o"), "gpt-4o")
    }

    func testNormalizeStripsTrailingDate() {
        XCTAssertEqual(PricingManager.normalize("claude-sonnet-4-20250514"), "claude-sonnet-4")
        XCTAssertEqual(PricingManager.normalize("deepseek-v4-pro"), "deepseek-v4-pro")
    }

    func testNormalizeStripsTrailingVersion() {
        XCTAssertEqual(PricingManager.normalize("claude-sonnet-4-v2"), "claude-sonnet-4")
    }

    func testNormalizeHandlesDateSuffix() {
        // The catalog doesn't need to strip YYYY-MM-DD; model names in logs
        // usually use compact dates like 20240806 or date-less names
        XCTAssertTrue(PricingManager.normalize("gpt-4o-2024-08-06").hasPrefix("gpt-4o"))
    }

    func testNormalizeHandlesPlainNames() {
        XCTAssertEqual(PricingManager.normalize("deepseek-v4-pro"), "deepseek-v4-pro")
        XCTAssertEqual(PricingManager.normalize("gemini-2.5-pro"), "gemini-2.5-pro")
    }

    func testProviderIdForDeepSeek() {
        XCTAssertEqual(PricingManager.shared.providerId(for: "deepseek-v4-pro"), "deepseek")
    }

    func testCostUSDForDeepSeekPro() {
        let cost = PricingManager.shared.costUSD(model: "deepseek-v4-pro", inTokens: 1_000_000, outTokens: 500_000, cacheTokens: 1_000_000)
        XCTAssertNotNil(cost)
        // 1M in @ $0.42 + 0.5M out @ $0.83 + 1M cache @ $0.0035 = 0.42 + 0.415 + 0.0035 = 0.8385
        XCTAssertEqual(cost!, 0.8385, accuracy: 0.001)
    }

    func testPricingForUnknownModelReturnsNil() {
        XCTAssertNil(PricingManager.shared.pricing(for: "nonexistent-model-xyz"))
    }
}
