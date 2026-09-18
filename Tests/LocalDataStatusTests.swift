import XCTest
@testable import AIPulse

final class LocalDataStatusTests: XCTestCase {
    func testMissingAccessDoesNotBecomeZeroActivityWhenScanCompletes() {
        let value = LocalDataStatus.resolve(homeAccess: .missing, hasReadableLogs: false, scan: .available,
            hasActivity: false, rootsConfigured: false, rootsAccessible: true, rootsExist: true)
        XCTAssertEqual(value.activity, .needsAccess)
        XCTAssertFalse(value.canReportCurrentActivity)
        XCTAssertEqual(value.repositories, .notConfigured)
    }
    func testHomeOnlyCanReportActivityAndRepositoryOnlyDoesNotInventTokens() {
        let home = LocalDataStatus.resolve(homeAccess: .granted, hasReadableLogs: true, scan: .available,
            hasActivity: true, rootsConfigured: false, rootsAccessible: true, rootsExist: true)
        XCTAssertEqual(home.activity, .ready)
        XCTAssertEqual(home.repositories, .notConfigured)
        let repo = LocalDataStatus.resolve(homeAccess: .missing, hasReadableLogs: false, scan: .available,
            hasActivity: false, rootsConfigured: true, rootsAccessible: true, rootsExist: true)
        XCTAssertEqual(repo.activity, .needsAccess)
        XCTAssertEqual(repo.repositories, .ready)
    }
    func testNoSourcesIsNotQuietAndFailureCannotReuseHistory() {
        let noLogs = LocalDataStatus.resolve(homeAccess: .granted, hasReadableLogs: false, scan: .available,
            hasActivity: false, rootsConfigured: false, rootsAccessible: true, rootsExist: true)
        XCTAssertEqual(noLogs.activity, .noSources)
        let failed = LocalDataStatus.resolve(homeAccess: .granted, hasReadableLogs: true, scan: .failed,
            hasActivity: true, rootsConfigured: true, rootsAccessible: true, rootsExist: true)
        XCTAssertEqual(failed.activity, .failed)
        XCTAssertFalse(failed.canReportCurrentActivity)
    }
    func testRenewalAndReadableSubsetRestoreSourcesIndependently() {
        let expired = LocalDataStatus.resolve(homeAccess: .expired, hasReadableLogs: false, scan: .available,
            hasActivity: true, rootsConfigured: true, rootsAccessible: false, rootsExist: true)
        XCTAssertEqual(expired.activity, .accessExpired)
        XCTAssertEqual(expired.repositories, .needsAccess)
        let subset = LocalDataStatus.resolve(homeAccess: .missing, hasReadableLogs: true, scan: .available,
            hasActivity: false, rootsConfigured: true, rootsAccessible: true, rootsExist: true)
        XCTAssertEqual(subset.activity, .noActivity)
        XCTAssertTrue(subset.canReportCurrentActivity)
    }
    func testUnqueriedActivityIsNotReportedAsZeroAndPeriodicScanKeepsRecentResult() {
        let unknown = LocalDataStatus.resolve(homeAccess: .granted, hasReadableLogs: true, scan: .available,
            hasActivity: nil, rootsConfigured: false, rootsAccessible: true, rootsExist: true)
        XCTAssertEqual(unknown.activity, .ready)
        let periodic = LocalDataStatus.resolve(homeAccess: .granted, hasReadableLogs: true, scan: .scanning,
            hasActivity: true, rootsConfigured: true, rootsAccessible: true, rootsExist: true, priorReadUsable: true)
        XCTAssertEqual(periodic.activity, .ready)
        let first = LocalDataStatus.resolve(homeAccess: .granted, hasReadableLogs: true, scan: .scanning,
            hasActivity: nil, rootsConfigured: true, rootsAccessible: true, rootsExist: true)
        XCTAssertEqual(first.activity, .scanning)
    }
    func testStaleHistoryAndMissingRepositoryDoNotPretendToBeCurrent() {
        let state = LocalDataStatus.resolve(homeAccess: .granted, hasReadableLogs: true, scan: .stale,
            hasActivity: true, rootsConfigured: true, rootsAccessible: true, rootsExist: false)
        XCTAssertEqual(state.activity, .stale)
        XCTAssertEqual(state.repositories, .missing)
        XCTAssertFalse(state.canReportCurrentActivity)
    }

}
