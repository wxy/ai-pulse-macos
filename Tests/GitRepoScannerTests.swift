import XCTest
@testable import AIPulse

final class GitRepoScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitRepoScannerTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeGitRepo(_ relPath: String) {
        let repo = tempDir.appendingPathComponent(relPath)
        try! FileManager.default.createDirectory(at: repo,
                                                 withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
    }

    private func makePlainDir(_ relPath: String) {
        let dir = tempDir.appendingPathComponent(relPath)
        try! FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
    }

    private func scan() -> [String] {
        var found: [String] = []
        GitRepoScanner.enumerate(in: tempDir) { found.append($0.lastPathComponent) }
        return found.sorted()
    }

    func testFindsTopLevelRepos() {
        makeGitRepo("repo-a")
        makeGitRepo("repo-b")
        makePlainDir("not-a-repo")  // no .git → excluded
        XCTAssertEqual(scan(), ["repo-a", "repo-b"])
    }

    func testNestedRepoNotDoubleReported() {
        // A repo nested inside another repo is not reported separately
        // (skipDescendants after the outer repo is found).
        makeGitRepo("outer/.git")
        makeGitRepo("outer/inner/.git")
        XCTAssertEqual(scan(), ["outer"])
    }

    func testSkipsSystemDirectories() {
        makeGitRepo("Music/repo")    // inside skipped dir
        makeGitRepo("Library/repo")  // inside skipped dir
        makeGitRepo("normal")
        XCTAssertEqual(scan(), ["normal"])
    }

    func testEmptyDirectory() {
        XCTAssertEqual(scan(), [])
    }

    func testSkipsHeavyDirectories() {
        makeGitRepo("node_modules/fake-repo")
        makeGitRepo("Pods/lib/foo")
        makeGitRepo("normal-repo")
        XCTAssertEqual(scan(), ["normal-repo"])
    }

    func testDepthBoundExcludesDeepRepos() {
        // 5 层深（nested=1 … too-deep-repo=5）超出 maxDepth=4，不应被枚举。
        makeGitRepo("shallow-repo")
        makeGitRepo("nested/deep/deeper/deepest/too-deep-repo")
        XCTAssertEqual(scan(), ["shallow-repo"])
    }

    func testDeadlineTruncates() {
        makeGitRepo("repo-a")
        var found: [String] = []
        let truncated = GitRepoScanner.enumerate(in: tempDir, deadline: .distantPast) {
            found.append($0.lastPathComponent)
        }
        XCTAssertTrue(truncated)
        XCTAssertTrue(found.isEmpty)
    }

    func testDeadlineTruncatesSparseTree() {
        // A repo-sparse tree: 200 plain dirs, no .git anywhere. The deadline is
        // checked periodically (every 128 entries), not just at repo boundaries
        // — otherwise this walk would never truncate. `.distantPast` fires at
        // the first periodic check.
        for i in 0..<200 {
            makePlainDir("dir-\(i)")
        }
        var found: [String] = []
        let truncated = GitRepoScanner.enumerate(in: tempDir, deadline: .distantPast) {
            found.append($0.lastPathComponent)
        }
        XCTAssertTrue(truncated)
        XCTAssertTrue(found.isEmpty)
    }
}
