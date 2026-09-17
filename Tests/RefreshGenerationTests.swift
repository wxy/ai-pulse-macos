import XCTest
@testable import AIPulse

final class RefreshGenerationTests: XCTestCase {
    @MainActor
    func testOlderSuspendedRefreshCannotPublishAfterNewerRequest() async {
        let generation = RefreshGeneration()
        let first = generation.begin()
        var resume: CheckedContinuation<Void, Never>?
        var published = ""
        let oldTask = Task { @MainActor in
            await withCheckedContinuation { resume = $0 }
            if generation.isCurrent(first) { published = "old" }
        }
        while resume == nil { await Task.yield() }
        let second = generation.begin()
        if generation.isCurrent(second) { published = "new" }
        resume?.resume()
        await oldTask.value
        XCTAssertEqual(published, "new")
        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
    }
}
