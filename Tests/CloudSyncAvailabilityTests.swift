import XCTest
@testable import AIPulse

final class CloudSyncAvailabilityTests: XCTestCase {
    @MainActor
    func testDebugNeverCreatesAnICloudWriteToCheckStatus() async {
        #if DEBUG
        await CloudSyncService.shared.refreshAccount()
        XCTAssertEqual(CloudSyncService.shared.result, .disabled)
        await CloudSyncService.shared.syncFromCache()
        XCTAssertEqual(CloudSyncService.shared.result, .disabled)
        #endif
    }
}
