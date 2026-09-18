import XCTest
@testable import AIPulse

final class CloudSyncAvailabilityTests: XCTestCase {
    @MainActor
    func testSignedBuildsAllowCloudWritesRegardlessOfDebugConfiguration() {
        XCTAssertTrue(CloudSyncService.allowsCloudWrites(signingEnabled: "YES"))
        XCTAssertFalse(CloudSyncService.allowsCloudWrites(signingEnabled: "NO"))
        XCTAssertFalse(CloudSyncService.allowsCloudWrites(signingEnabled: nil))
        XCTAssertFalse(CloudSyncService.allowsCloudWrites(signingEnabled: "$(CODE_SIGNING_ALLOWED)"))
    }

    @MainActor
    func testUnsignedTestsNeverCreateAnICloudWriteToCheckStatus() async {
        #if DEBUG
        await CloudSyncService.shared.refreshAccount()
        XCTAssertEqual(CloudSyncService.shared.result, .disabled)
        await CloudSyncService.shared.syncFromCache()
        XCTAssertEqual(CloudSyncService.shared.result, .disabled)
        #endif
    }
}
