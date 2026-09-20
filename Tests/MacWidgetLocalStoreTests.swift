import XCTest
import AIPulseShared

final class MacWidgetLocalStoreTests: XCTestCase {
    func testRoundTripsAndAtomicallyReplacesPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWidgetLocalStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(MacWidgetLocalStore.fileName)
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let secondDate = Date(timeIntervalSince1970: 2_000)

        try MacWidgetLocalStore.write(payload(at: firstDate), to: url)
        XCTAssertEqual(try MacWidgetLocalStore.load(from: url)?.writtenAt, firstDate)

        try MacWidgetLocalStore.write(payload(at: secondDate), to: url)
        let loaded = try XCTUnwrap(MacWidgetLocalStore.load(from: url))
        XCTAssertEqual(loaded.writtenAt, secondDate)
        XCTAssertEqual(loaded.todaySnapshot?.todayTokens, 42)
        XCTAssertEqual(loaded.pulseEnvelope?.generatedAt, secondDate)
    }

    func testMissingFileReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json")
        XCTAssertNil(try MacWidgetLocalStore.load(from: url))
    }

    func testRoundTripsThroughAppGroupDefaults() throws {
        let suiteName = "MacWidgetLocalStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = Date(timeIntervalSince1970: 3_000)

        try MacWidgetLocalStore.write(payload(at: date), to: defaults)

        let loaded = try XCTUnwrap(MacWidgetLocalStore.load(from: defaults))
        XCTAssertEqual(loaded.writtenAt, date)
        XCTAssertEqual(loaded.todaySnapshot?.todayTokens, 42)
    }

    func testDashboardDeepLinkRecognition() {
        XCTAssertEqual(
            AIPulseDeepLink.dashboardURL(for: "xingyu.wang.aipulse.debug.widget").absoluteString,
            "aipulse-debug://dashboard"
        )
        XCTAssertEqual(
            AIPulseDeepLink.dashboardURL(for: "com.wxy.aipulse.macoswidget").absoluteString,
            "aipulse://dashboard"
        )
        XCTAssertTrue(AIPulseDeepLink.opensDashboard(URL(string: "aipulse-debug://dashboard")!))
        XCTAssertTrue(AIPulseDeepLink.opensDashboard(URL(string: "AIPULSE://DASHBOARD")!))
        XCTAssertFalse(AIPulseDeepLink.opensDashboard(URL(string: "aipulse://settings")!))
        XCTAssertFalse(AIPulseDeepLink.opensDashboard(URL(string: "https://dashboard")!))
    }

    func testProducerFreshnessUsesPublisherAndWidgetWindow() {
        let writtenAt = Date(timeIntervalSince1970: 10_000)
        let value = payload(at: writtenAt)

        XCTAssertTrue(value.isProducerFresh(asOf: writtenAt.addingTimeInterval(20 * 60)))
        XCTAssertFalse(value.isProducerFresh(asOf: writtenAt.addingTimeInterval(20 * 60 + 1)))
        XCTAssertFalse(value.isProducerFresh(asOf: writtenAt.addingTimeInterval(-61)))
    }

    private func payload(at date: Date) -> MacWidgetLocalPayload {
        var today = DashboardSnapshot(todayTokens: 42, updatedAt: date)
        today.period = DashboardPeriod(kind: .today, now: date)
        let pulse = PulseSnapshot(
            tier: .active,
            primarySignal: .activity,
            reason: "test",
            signals: [],
            asOf: date,
            validUntil: date.addingTimeInterval(60)
        )
        return MacWidgetLocalPayload(
            writtenAt: date,
            todaySnapshot: today,
            historySnapshot: nil,
            pulseEnvelope: CurrentPulseEnvelope(
                pulse: pulse,
                writerAppVersion: "test",
                generatedAt: date
            )
        )
    }
}
