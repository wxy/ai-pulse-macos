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

    @MainActor
    func testSuccessfulCachedBalanceIsAValidAccountObservation() {
        let cached = CachedBalance(
            balances: [BalanceEntry(currency: "CNY", totalBalance: 12.5, grantedBalance: 0, toppedUpBalance: 0)],
            lastFetchTimestamp: 1_750_000_000_000,
            error: nil
        )

        XCTAssertEqual(IntegrationRow.cachedKeyStatus(cached), .valid)
    }
}
