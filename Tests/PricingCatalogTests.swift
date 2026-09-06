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

    func testGLMAttributionWithoutPricing() {
        XCTAssertEqual(PricingManager.shared.providerId(for: "glm-5.3-flash"), "zhipu")
        XCTAssertNil(PricingManager.shared.pricing(for: "glm-5.3-flash"))
        XCTAssertNil(PricingManager.shared.costUSD(
            model: "glm-5.3-flash", inTokens: 1, outTokens: 1, cacheTokens: 0))
    }

    func testCostUSDForDeepSeekPro() {
        let cost = PricingManager.shared.costUSD(model: "deepseek-v4-pro", inTokens: 1_000_000, outTokens: 500_000, cacheTokens: 1_000_000)
        XCTAssertNotNil(cost)
        // cacheTokens is a subset of inTokens, so the cached 1M is billed at
        // cache price (not additionally at full input price):
        // non-cached input = 0 → $0
        // 0.5M out @ $0.83 = 0.415
        // 1M cache @ $0.0035 = 0.0035
        // total = 0.4185
        XCTAssertEqual(cost!, 0.4185, accuracy: 0.001)
    }

    func testPricingForUnknownModelReturnsNil() {
        XCTAssertNil(PricingManager.shared.pricing(for: "nonexistent-model-xyz"))
    }

    // MARK: - costUSD edge cases

    func testCostUSDWithNilModel() {
        let cost = PricingManager.shared.costUSD(model: nil, inTokens: 1000, outTokens: 500, cacheTokens: 0)
        XCTAssertNil(cost, "nil model should return nil cost")
    }

    func testCostUSDWithZeroTokens() {
        let cost = PricingManager.shared.costUSD(model: "deepseek-v4-pro", inTokens: 0, outTokens: 0, cacheTokens: 0)
        XCTAssertNotNil(cost)
        XCTAssertEqual(cost!, 0.0, accuracy: 0.0001, "zero tokens should cost $0")
    }

    func testCostUSDScalesLinearly() {
        // 2x tokens → 2x cost
        let cost1 = PricingManager.shared.costUSD(model: "deepseek-v4-pro", inTokens: 1_000_000, outTokens: 0, cacheTokens: 0)
        let cost2 = PricingManager.shared.costUSD(model: "deepseek-v4-pro", inTokens: 2_000_000, outTokens: 0, cacheTokens: 0)
        XCTAssertNotNil(cost1); XCTAssertNotNil(cost2)
        XCTAssertEqual(cost2!, cost1! * 2.0, accuracy: 0.001)
    }

    func testCostUSDWithCacheTokensExceedingInputBillsOnlyCache() {
        // Cache tokens may exceed input tokens in corrupt logs; the non-cached
        // portion must clamp to zero instead of going negative.
        let cost = PricingManager.shared.costUSD(model: "deepseek-v4-pro", inTokens: 1_000, outTokens: 0, cacheTokens: 2_000)
        XCTAssertNotNil(cost)
        XCTAssertEqual(cost ?? -1, Double(2_000) / 1_000_000 * 0.0035, accuracy: 0.0001)
    }

    func testCostUSDWithHugeCacheTokensDoesNotTrap() {
        // The old `inTokens - cacheTokens` subtraction can trap when the token
        // fields are extreme. The subtraction must be overflow-safe.
        let cost = PricingManager.shared.costUSD(model: "deepseek-v4-pro", inTokens: .max, outTokens: 0, cacheTokens: -1)
        XCTAssertNotNil(cost)
        XCTAssertTrue(cost!.isFinite)
        XCTAssertGreaterThan(cost!, 0)
    }
}
