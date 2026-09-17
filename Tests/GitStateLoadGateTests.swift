import XCTest
@testable import AIPulse

final class GitStateLoadGateTests: XCTestCase {
    private actor Probe {
        var calls = 0
        func load(succeeds: Bool) async -> Bool {
            calls += 1
            await Task.yield()
            return succeeds
        }
    }

    func testFailedInitializationIsRetriedAndOnlySuccessIsCached() async {
        let gate = GitStateLoadGate()
        let probe = Probe()
        let failed = await gate.ensureLoaded { await probe.load(succeeds: false) }
        XCTAssertFalse(failed)
        let retried = await gate.ensureLoaded { await probe.load(succeeds: true) }
        XCTAssertTrue(retried)
        let cached = await gate.ensureLoaded { await probe.load(succeeds: false) }
        XCTAssertTrue(cached)
        let calls = await probe.calls
        XCTAssertEqual(calls, 2)
    }

    func testConcurrentPollsShareInitialization() async {
        let gate = GitStateLoadGate()
        let probe = Probe()
        async let first = gate.ensureLoaded { await probe.load(succeeds: true) }
        async let second = gate.ensureLoaded { await probe.load(succeeds: true) }
        let results = await (first, second)
        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }
}
