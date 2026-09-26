import XCTest
@testable import AIPulse

final class CloudSyncFingerprintStoreTests: XCTestCase {
    func testFullWidthFingerprintsRoundTripAcrossRanges() throws {
        let suite = "CloudSyncFingerprintStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(CloudSyncFingerprintStore.read(rangeKey: "today", defaults: defaults))
        CloudSyncFingerprintStore.write(UInt64.max, rangeKey: "today", defaults: defaults)
        CloudSyncFingerprintStore.write(9_007_199_254_740_993, rangeKey: "week", defaults: defaults)

        XCTAssertEqual(CloudSyncFingerprintStore.read(rangeKey: "today", defaults: defaults), UInt64.max)
        XCTAssertEqual(CloudSyncFingerprintStore.read(rangeKey: "week", defaults: defaults), 9_007_199_254_740_993)
        XCTAssertEqual(defaults.string(forKey: "cloud_sync_fingerprint_today"), String(UInt64.max))
    }

    func testLegacyFloatingPointFingerprintIsIgnored() throws {
        let suite = "CloudSyncFingerprintStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Double(UInt64.max), forKey: "cloud_sync_fingerprint_today")
        XCTAssertNil(CloudSyncFingerprintStore.read(rangeKey: "today", defaults: defaults))
        CloudSyncFingerprintStore.write(0, rangeKey: "today", defaults: defaults)
        XCTAssertEqual(CloudSyncFingerprintStore.read(rangeKey: "today", defaults: defaults), 0)
    }
}
