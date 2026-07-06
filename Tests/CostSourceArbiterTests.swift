import XCTest
@testable import AIPulse

final class CostSourceArbiterTests: XCTestCase {

    // Helper to create test CostSources
    func makeAPIKey(id: String, providerId: String, models: Set<String>, confidence: CostConfidence = .exact) -> CostSource {
        CostSource(id: id, label: id, kind: .apiKey(providerId: providerId),
                   coveredModels: models, confidence: confidence, limitations: [])
    }

    func makeSubscription(id: String, toolId: String, models: Set<String>, fee: Double = 20) -> CostSource {
        CostSource(id: id, label: id,
                   kind: .subscription(toolId: toolId, tierLabel: "Pro", monthlyFee: fee),
                   coveredModels: models, confidence: .amortized, limitations: [])
    }

    // MARK: - Single match

    func testResolveSingleAPIKeyMatch() {
        let sources = [makeAPIKey(id: "api-key:deepseek", providerId: "deepseek", models: ["deepseek-v4-pro"])]
        let (csId, conf) = Arbitrator.resolve(model: "deepseek-v4-pro", source: "claude-code", costSources: sources)
        XCTAssertEqual(csId, "api-key:deepseek")
        XCTAssertEqual(conf, .exact)
    }

    func testResolveSingleSubscriptionMatch() {
        let sources = [makeSubscription(id: "sub:claude-code:pro", toolId: "claude-code", models: ["claude-sonnet-4"])]
        let (csId, conf) = Arbitrator.resolve(model: "claude-sonnet-4", source: "claude-code", costSources: sources)
        XCTAssertEqual(csId, "sub:claude-code:pro")
        XCTAssertEqual(conf, .amortized)
    }

    // MARK: - Zero match

    func testResolveNoMatch() {
        let sources = [makeAPIKey(id: "api-key:deepseek", providerId: "deepseek", models: ["deepseek-v4-pro"])]
        let (csId, conf) = Arbitrator.resolve(model: "gpt-5", source: "claude-code", costSources: sources)
        XCTAssertEqual(csId, CostSource.unknownId)
        XCTAssertEqual(conf, .incomplete)
    }

    func testResolveNilModel() {
        let sources = [makeAPIKey(id: "api-key:deepseek", providerId: "deepseek", models: ["deepseek-v4-pro"])]
        let (csId, conf) = Arbitrator.resolve(model: nil, source: "claude-code", costSources: sources)
        XCTAssertEqual(csId, CostSource.unknownId)
        XCTAssertEqual(conf, .incomplete)
    }

    // MARK: - Multiple match (apiKey > subscription)

    func testAPIKeyWinsOverSubscription() {
        let apiKey = makeAPIKey(id: "api-key:anthropic", providerId: "anthropic", models: ["claude-sonnet-4"], confidence: .estimated)
        let sub = makeSubscription(id: "sub:claude-code:pro", toolId: "claude-code", models: ["claude-sonnet-4"])
        let sources = [apiKey, sub]
        let (csId, conf) = Arbitrator.resolve(model: "claude-sonnet-4", source: "claude-code", costSources: sources)
        XCTAssertEqual(csId, "api-key:anthropic")
        XCTAssertEqual(conf, .estimated)
    }

    // MARK: - Preferred API Key override

    func testPreferredAPIKeySelected() {
        let deepseek = makeAPIKey(id: "api-key:deepseek", providerId: "deepseek", models: ["deepseek-v4-pro", "claude-sonnet-4"])
        let anthropic = makeAPIKey(id: "api-key:anthropic", providerId: "anthropic", models: ["claude-sonnet-4"], confidence: .estimated)
        let sub = makeSubscription(id: "sub:claude-code:pro", toolId: "claude-code", models: ["claude-sonnet-4"])
        let sources = [deepseek, anthropic, sub]
        // Without preference, apiKey wins (first match)
        let (csId1, _) = Arbitrator.resolve(model: "claude-sonnet-4", source: "claude-code", costSources: sources)
        XCTAssertEqual(csId1, "api-key:deepseek")  // first apiKey in sources wins

        // With preference, specified key wins even if not first
        let (csId2, conf2) = Arbitrator.resolve(model: "claude-sonnet-4", source: "claude-code", costSources: sources, preferredAPIKeyId: "api-key:anthropic")
        XCTAssertEqual(csId2, "api-key:anthropic")
        XCTAssertEqual(conf2, .estimated)
    }

    // MARK: - Model name normalization

    func testModelWithDateStampMatches() {
        let sources = [makeAPIKey(id: "api-key:anthropic", providerId: "anthropic", models: ["claude-sonnet-4"])]
        let (csId, _) = Arbitrator.resolve(model: "claude-sonnet-4-20250514", source: "claude-code", costSources: sources)
        XCTAssertEqual(csId, "api-key:anthropic")
    }
}
