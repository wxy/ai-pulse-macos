import XCTest
@testable import AIPulse

final class ApiKeyIntegrationTests: XCTestCase {
    private let testId = "test-key-provider"

    override func tearDown() {
        ApiKeyManager.shared.delete(testId)
        super.tearDown()
    }

    private func makeIntegration(usesClaudeModels: Bool = false) -> ApiKeyIntegration {
        ApiKeyIntegration(
            id: testId,
            displayName: "Test Provider",
            providerId: testId,
            usesClaudeModels: usesClaudeModels,
            limitationKey: "limitation.assume_programming",
            confidence: .exact
        )
    }

    func testNoKeyYieldsNoCostSources() {
        ApiKeyManager.shared.delete(testId)
        XCTAssertTrue(makeIntegration().costSources.isEmpty)
    }

    func testWithKeyYieldsSingleCostSource() {
        ApiKeyManager.shared.set(testId, key: "sk-test-123")
        let sources = makeIntegration().costSources
        XCTAssertEqual(sources.count, 1)
        let source = sources[0]
        XCTAssertEqual(source.id, "api-key:\(testId)")
        XCTAssertEqual(source.label, "Test Provider API")
        if case .apiKey(let pid) = source.kind {
            XCTAssertEqual(pid, testId)
        } else {
            XCTFail("expected .apiKey kind")
        }
        XCTAssertEqual(source.confidence, .exact)
    }

    func testDetectReflectsKeyPresence() {
        ApiKeyManager.shared.delete(testId)
        XCTAssertFalse(makeIntegration().detect().found)

        ApiKeyManager.shared.set(testId, key: "sk-test-123")
        XCTAssertTrue(makeIntegration().detect().found)
    }

    func testClaudeModelCatalogUsedWhenFlagSet() {
        ApiKeyManager.shared.set(testId, key: "sk-test-123")
        let claudeSource = makeIntegration(usesClaudeModels: true).costSources[0]
        let providerSource = makeIntegration(usesClaudeModels: false).costSources[0]
        XCTAssertEqual(claudeSource.coveredModels, PricingManager.shared.claudeModels())
        XCTAssertEqual(providerSource.coveredModels,
                       PricingManager.shared.modelsForProvider(testId))
    }
}
