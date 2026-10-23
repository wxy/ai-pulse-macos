import XCTest
import AIPulseShared
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

    // MARK: - 2026-10-23 review F08:指纹必须来自规范化键序的确定性编码

    func testContentFingerprintIsStableAcrossRepeatedEncodes() {
        let snapshot = Self.snapshot()
        let first = CloudSyncFingerprintStore.contentFingerprint(snapshot)
        XCTAssertNotNil(first)
        // 100 re-encodes of identical content: the default encoder serializes
        // dictionary properties in per-process order, so an unnormalized hash
        // drifted across encodes and processes.
        for _ in 0..<100 {
            XCTAssertEqual(CloudSyncFingerprintStore.contentFingerprint(snapshot), first)
        }
    }

    func testContentFingerprintMatchesManuallySortedKeysEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expected = stableHash(String(decoding: try encoder.encode(Self.snapshot()), as: UTF8.self))
        XCTAssertEqual(CloudSyncFingerprintStore.contentFingerprint(Self.snapshot()), expected,
                       "Self.snapshot() already pins updatedAt to the epoch")
    }

    func testContentFingerprintIgnoresUpdatedAtButNotContent() {
        var snapshot = Self.snapshot()
        snapshot.updatedAt = Date(timeIntervalSince1970: 0)
        let baseline = CloudSyncFingerprintStore.contentFingerprint(snapshot)

        var restamped = snapshot
        restamped.updatedAt = Date()
        XCTAssertEqual(CloudSyncFingerprintStore.contentFingerprint(restamped), baseline,
                       "only updatedAt changed — the write must be skipped")

        restamped.todayTokens += 1
        XCTAssertNotEqual(CloudSyncFingerprintStore.contentFingerprint(restamped), baseline,
                          "a content change must push")
    }

    private static func snapshot() -> DashboardSnapshot {
        var snapshot = DashboardSnapshot()
        snapshot.updatedAt = Date(timeIntervalSince1970: 0)
        return snapshot
    }
}
