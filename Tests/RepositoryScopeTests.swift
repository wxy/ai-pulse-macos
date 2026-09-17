import XCTest
@testable import AIPulse

final class RepositoryScopeTests: XCTestCase {
    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testOnlyResolvesGitRootInsideConfiguredDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let allowed = base.appendingPathComponent("develop")
        let repo = allowed.appendingPathComponent("project")
        let nested = repo.appendingPathComponent("Sources/Feature")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try git(["init", "--quiet", repo.path])

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

    func testInvalidGitMarkerAndMissingWorkingPathAreNotRepositories() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertNil(RepositoryScope.authorizedGitRoot(for: base.path, roots: [base.path]))
        XCTAssertNil(GitRepo.findRoot(containing: base.path))
        let marker = base.appendingPathComponent(".git")
        try FileManager.default.removeItem(at: marker)
        try Data("gitdir: missing-directory\n".utf8).write(to: marker)
        XCTAssertNil(RepositoryScope.authorizedGitRoot(for: base.path, roots: [base.path]))
        try FileManager.default.removeItem(at: marker)
        try git(["init", "--quiet", base.path])
        XCTAssertNil(RepositoryScope.gitRoot(containing: base.appendingPathComponent("missing/child").path))
    }

    func testRealLinkedWorktreeResolvesToItsOwnWorkingRoot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("main")
        let linked = base.appendingPathComponent("linked")
        try git(["init", "--quiet", main.path])
        try git(["-C", main.path, "-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "--quiet", "--allow-empty", "-m", "fixture"])
        try git(["-C", main.path, "worktree", "add", "--quiet", "--detach", linked.path])
        XCTAssertEqual(RepositoryScope.authorizedGitRoot(for: linked.path, roots: [base.path]), RepositoryScope.canonicalPath(linked.path))
        XCTAssertEqual(GitRepo.findRoot(containing: linked.path), RepositoryScope.canonicalPath(linked.path))
    }
}
