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
    func testTwoPointZeroDoesNotEmitLegacyBillingFields() throws {
        let snapshot = DashboardSnapshot()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshot.jsonString().utf8)) as? [String: Any])
        for field in ["todayCost", "weekCost", "monthCost", "yesterdaySpend", "previousPeriodSpend",
                      "subDaily", "catalogEquivalentUSD", "prediction"] {
            XCTAssertNil(json[field], "Legacy billing field must not reappear: \(field)")
        }
        XCTAssertNotNil(json["period"])
        XCTAssertNil(json["convertedObservedSpendUSD"], "Unknown observed amount must not become zero")
    }

    func testActivityBreakdownsDoNotEncodeMoneyOrLegacyDetails() throws {
        var snapshot = DashboardSnapshot()
        snapshot.toolBreakdown = [ToolActivityItem(toolId: "codex", name: "Codex", tokens: 100, calls: 2)]
        snapshot.topRepos = [RepoItem(repoPath: "/a/project", name: "project", added: 10, deleted: 2, tokens: 100)]
        snapshot.modelBreakdown = [ModelActivityItem(model: "model", providerId: "provider", toolId: "codex", tokens: 100, calls: 2)]
        snapshot.periodSessions = 2
        let data = Data(snapshot.jsonString().utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["toolDetails"])
        XCTAssertNil(json["rateSeries"])
        XCTAssertNil(json["pulse"], "Historical periods must not carry transient state")
        for key in ["toolBreakdown", "topRepos", "modelBreakdown"] {
            let item = try XCTUnwrap((json[key] as? [[String: Any]])?.first)
            for field in ["cost", "cpl", "costIsEstimate", "projectedMonth"] { XCTAssertNil(item[field]) }
        }
        let decoded = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
        XCTAssertEqual(decoded.periodSessions, 2)
        XCTAssertEqual(decoded.topRepos.first?.repoPath, "/a/project")
    }

    func testRepositoryIdentityIsNotItsDisplayName() {
        let first = RepoItem(repoPath: "/a/project", name: "project", added: 0, deleted: 0)
        let second = RepoItem(repoPath: "/b/project", name: "project", added: 0, deleted: 0)
        XCTAssertEqual(first.name, second.name)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testNativePulseRoundTripsWithUnitPreservingSignals() throws {
        let pulse = PulseSnapshot(
            tier: .elevated, primarySignal: .activity, reason: "token_rate_2_0x",
            signals: [PulseSignal(
                kind: .activity, rawValue: 40_000, unit: "tokens/h", baseline: 20_000,
                normalized: 2, freshness: .fresh, completeness: .complete,
                observedAt: Date(timeIntervalSince1970: 100), reason: "token_rate_2_0x")],
            asOf: Date(timeIntervalSince1970: 110))

        let envelope = CurrentPulseEnvelope(pulse: pulse, writerAppVersion: "2.0.0",
                                            generatedAt: Date(timeIntervalSince1970: 110))
        let decoded = try JSONDecoder().decode(CurrentPulseEnvelope.self, from: JSONEncoder().encode(envelope))

        XCTAssertEqual(decoded.pulse, pulse)
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
        snapshot.declaredMonthlyCostUSD = 20

        let decoded = try JSONDecoder().decode(
            DashboardSnapshot.self,
            from: Data(snapshot.jsonString().utf8))

        XCTAssertEqual(decoded.observedSpend?.first?.amount, 9)
        XCTAssertEqual(decoded.observedSpend?.first?.currency, "CNY")
        XCTAssertEqual(decoded.observedSpend?.first?.conversionRateToUSD, 0.14)
        XCTAssertEqual(decoded.observedSpend?.first?.conversionSource, "internal-static-approximation-v1")
        XCTAssertEqual(decoded.convertedObservedSpendUSD, 1.26)
        XCTAssertEqual(decoded.declaredMonthlyCostUSD, 20)
    }

}
