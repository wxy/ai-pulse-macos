import XCTest
@testable import AIPulse

final class RepositoryLabelsTests: XCTestCase {
    func testUniqueNamesHideParentsWithoutChangingLookupKeys() {
        XCTAssertEqual(RepositoryLabels.make(for: ["/dev/one", "/dev/two"]),
                       ["/dev/one": "one", "/dev/two": "two"])
    }

    func testSameNamesUseShortestDistinctParentSuffix() {
        let paths = ["/work/client/app", "/work/server/app", "/other/client/app"]
        let labels = RepositoryLabels.make(for: paths)
        XCTAssertEqual(labels[paths[0]], "app · work/client")
        XCTAssertEqual(labels[paths[1]], "app · server")
        XCTAssertEqual(labels[paths[2]], "app · other/client")
        XCTAssertEqual(labels, RepositoryLabels.make(for: paths.reversed()))
        XCTAssertEqual(labels.count, 3)
    }
}
