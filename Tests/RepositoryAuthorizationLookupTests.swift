import XCTest
@testable import AIPulse

final class RepositoryAuthorizationLookupTests: XCTestCase {
    func testRepeatedAllowedAndDeniedPathsResolveOnceWithinOneLookup() {
        var lookup = RepositoryScope.AuthorizedRootLookup(roots: ["/allowed"])
        var calls: [String: Int] = [:]
        let paths = ["/allowed/repo", "/missing", "/allowed/repo", "", "/missing"]
        let results = paths.map { path in
            lookup.root(for: path) { candidate, roots in
                XCTAssertEqual(roots, ["/allowed"])
                calls[candidate, default: 0] += 1
                return candidate == "/allowed/repo" ? "/allowed/repo" : nil
            }
        }

        XCTAssertEqual(results, ["/allowed/repo", nil, "/allowed/repo", nil, nil])
        XCTAssertEqual(calls, ["/allowed/repo": 1, "/missing": 1])
    }

    func testNewLookupRechecksAuthorizationAndRepositoryState() {
        var first = RepositoryScope.AuthorizedRootLookup(roots: ["/allowed"])
        XCTAssertEqual(first.root(for: "/repo") { _, _ in "/allowed/repo" }, "/allowed/repo")

        var calls = 0
        var afterRevocation = RepositoryScope.AuthorizedRootLookup(roots: ["/other"])
        XCTAssertNil(afterRevocation.root(for: "/repo") { _, roots in
            calls += 1
            XCTAssertEqual(roots, ["/other"])
            return nil
        })
        XCTAssertNil(afterRevocation.root(for: "/repo") { _, _ in
            XCTFail("A denied result should also be cached within one lookup")
            return nil
        })

        var afterRestore = RepositoryScope.AuthorizedRootLookup(roots: ["/allowed"])
        XCTAssertEqual(afterRestore.root(for: "/repo") { _, _ in
            calls += 1
            return "/allowed/repo"
        }, "/allowed/repo")
        XCTAssertEqual(calls, 2)
    }

    func testDistinctPathsDoNotShareAuthorization() {
        var lookup = RepositoryScope.AuthorizedRootLookup(roots: ["/allowed"])
        var calls: [String] = []
        let resolve: (String, [String]) -> String? = { path, _ in
            calls.append(path)
            return path == "/allowed/project" ? path : nil
        }

        XCTAssertEqual(lookup.root(for: "/allowed/project", resolvingWith: resolve), "/allowed/project")
        XCTAssertNil(lookup.root(for: "/allowed/project-link", resolvingWith: resolve))
        XCTAssertEqual(calls, ["/allowed/project", "/allowed/project-link"])
    }
}
