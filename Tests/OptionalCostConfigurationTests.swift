import XCTest
@testable import AIPulse

final class OptionalCostConfigurationTests: XCTestCase {
    func testRemovingFixedCostPreservesActivityConfiguration() {
        var config = IntegrationConfig()
        config.enabled = true
        config.subscriptionTier = "Pro"
        let cleared = config.declaringSubscription("")
        XCTAssertEqual(cleared.subscriptionTier, "")
        XCTAssertTrue(cleared.enabled)
        XCTAssertEqual(config.subscriptionTier, "Pro")
    }
    func testConnectionFailuresDoNotClaimBadCredentials() {
        XCTAssertTrue(IntegrationRow.isCredentialRejection("HTTP 401"))
        XCTAssertFalse(IntegrationRow.isCredentialRejection("HTTP 503"))
        XCTAssertFalse(IntegrationRow.isCredentialRejection("HTTP 403"))
        XCTAssertFalse(IntegrationRow.isCredentialRejection("timeout"))
    }
}
