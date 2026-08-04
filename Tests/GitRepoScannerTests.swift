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

    func testFortyReposWithNoiseCompletesFast() {
        // A realistic dev dir: 40 git repos + nested plain dirs + a worktree
        // whose `.git` is a FILE (must still be counted as a repo, and its
        // subtree skipped so the walk stays bounded). The scan must complete
        // quickly, find 41 repos (40 + worktree), and not truncate.
        for i in 0..<40 { makeGitRepo("repo-\(i)") }
        for i in 0..<30 { makePlainDir("plain-\(i)/sub/nested") }
        // Worktree-style repo: .git is a file containing "gitdir: ...".
        let w = tempDir.appendingPathComponent("worktree-like")
        try! FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
        try! "gitdir: ../.git/worktrees/x".write(
            to: w.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        var found: [String] = []
        let deadline = Date().addingTimeInterval(5)
        let start = Date()
        let truncated = GitRepoScanner.enumerate(in: tempDir, deadline: deadline) {
            found.append($0.lastPathComponent)
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(truncated)
        XCTAssertEqual(found.count, 41)
        XCTAssertLessThan(elapsed, 3.0, "scan of 41 repos + noise took \(elapsed)s")
    }
}
