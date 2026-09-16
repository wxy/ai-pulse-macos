import XCTest
@testable import AIPulse

final class RepositoryScopeTests: XCTestCase {
    func testOnlyResolvesGitRootInsideConfiguredDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let allowed = base.appendingPathComponent("develop")
        let repo = allowed.appendingPathComponent("project")
        let nested = repo.appendingPathComponent("Sources/Feature")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertEqual(
            RepositoryScope.authorizedGitRoot(for: nested.path, roots: [allowed.path]),
            RepositoryScope.canonicalPath(repo.path))
        XCTAssertNil(RepositoryScope.authorizedGitRoot(for: nested.path, roots: [base.appendingPathComponent("other").path]))
    }

    func testNonGitDirectoryIsNeverAttributed() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertNil(RepositoryScope.authorizedGitRoot(for: base.path, roots: [base.path]))
    }

    func testRootContainmentIsComponentSafe() {
        XCTAssertTrue(RepositoryScope.isInsideConfiguredRoots("/tmp/develop/app", roots: ["/tmp/develop"]))
        XCTAssertFalse(RepositoryScope.isInsideConfiguredRoots("/tmp/development/app", roots: ["/tmp/develop"]))
    }
}
