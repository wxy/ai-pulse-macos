import XCTest
import AIPulseShared

final class CloudKitSchemaTests: XCTestCase {
    func testDashboardContractUsesTheUnreleasedTwoPointZeroSeries() throws {
        XCTAssertEqual(CKSchema.recordType, "DashboardCache_v2")
        XCTAssertEqual(CKSchema.payloadVersion, "2.0.0")
        XCTAssertNotEqual(CKSchema.Subscription.dashboardChanges, "dashboard-changes")
        XCTAssertEqual(CKSchema.SpendAlert.recordType, "SpendAlert_v1")
    }

    func testDashboardSnapshotEmitsTheTwoPointZeroEnvelope() throws {
        var snapshot = DashboardSnapshot()
        snapshot.payloadVersion = CKSchema.payloadVersion
        snapshot.writerAppVersion = "2.0.0"

        let decoded = try JSONDecoder().decode(
            DashboardSnapshot.self,
            from: Data(snapshot.jsonString().utf8))

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.payloadVersion, "2.0.0")
        XCTAssertEqual(decoded.writerAppVersion, "2.0.0")
    }
}

// MARK: - v2 Pulse contract

final class BurnSnapshotContractTests: XCTestCase {
    func testNativePulseRoundTripsWithUnitPreservingSignals() throws {
        var snapshot = DashboardSnapshot()
        snapshot.pulse = PulseSnapshot(
            tier: .elevated, primarySignal: .activity, reason: "token_rate_2_0x",
            signals: [PulseSignal(
                kind: .activity, rawValue: 40_000, unit: "tokens/h", baseline: 20_000,
                normalized: 2, freshness: .fresh, completeness: .complete,
                observedAt: Date(timeIntervalSince1970: 100), reason: "token_rate_2_0x")],
            asOf: Date(timeIntervalSince1970: 110))

        let decoded = try JSONDecoder().decode(
            DashboardSnapshot.self, from: Data(snapshot.jsonString().utf8))

        XCTAssertEqual(decoded.pulse, snapshot.pulse)
        XCTAssertEqual(decoded.pulse?.activity?.unit, "tokens/h")
        XCTAssertEqual(decoded.pulse?.primarySignal, .activity)
    }

    func testSemanticMoneyFieldsRoundTrip() throws {
        var snapshot = DashboardSnapshot()
        snapshot.observedSpend = [ObservedSpendItem(
            providerId: "deepseek", amount: 9, currency: "CNY",
            convertedUSD: 1.26, conversionRateToUSD: 0.14,
            conversionSource: "internal-static-approximation-v1", observedAt: 100)]
        snapshot.convertedObservedSpendUSD = 1.26
        snapshot.catalogEquivalentUSD = 4.5
        snapshot.declaredMonthlyCostUSD = 20

        let decoded = try JSONDecoder().decode(
            DashboardSnapshot.self,
            from: Data(snapshot.jsonString().utf8))

        XCTAssertEqual(decoded.observedSpend?.first?.amount, 9)
        XCTAssertEqual(decoded.observedSpend?.first?.currency, "CNY")
        XCTAssertEqual(decoded.observedSpend?.first?.conversionRateToUSD, 0.14)
        XCTAssertEqual(decoded.observedSpend?.first?.conversionSource, "internal-static-approximation-v1")
        XCTAssertEqual(decoded.convertedObservedSpendUSD, 1.26)
        XCTAssertEqual(decoded.catalogEquivalentUSD, 4.5)
        XCTAssertEqual(decoded.declaredMonthlyCostUSD, 20)
    }

}
