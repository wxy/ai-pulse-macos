import XCTest
@testable import AIPulse

final class GitMonitorTests: XCTestCase {

    // MARK: - Exclusion rules (file suffixes)

    func testExcludesLockfiles() {
        let monitor = GitMonitor.shared
        XCTAssertTrue(monitor.isExcluded(file: "yarn.lock"))
        XCTAssertTrue(monitor.isExcluded(file: "package-lock.json"))
        XCTAssertTrue(monitor.isExcluded(file: "pnpm-lock.yaml"))
        XCTAssertTrue(monitor.isExcluded(file: "Gemfile.lock"))
        // ".lock" suffix catches Gemfile.lock, poetry.lock, etc.
        XCTAssertTrue(monitor.isExcluded(file: "poetry.lock"))
    }

    func testExcludesGeneratedCode() {
        let monitor = GitMonitor.shared
        XCTAssertTrue(monitor.isExcluded(file: "models.pb.go"))
        XCTAssertTrue(monitor.isExcluded(file: "schema.generated.swift"))
        XCTAssertTrue(monitor.isExcluded(file: "types.generated.ts"))
        XCTAssertTrue(monitor.isExcluded(file: "query.graphql"))
    }

    func testExcludesMinifiedFiles() {
        let monitor = GitMonitor.shared
        XCTAssertTrue(monitor.isExcluded(file: "bundle.min.js"))
        XCTAssertTrue(monitor.isExcluded(file: "styles.min.css"))
        XCTAssertTrue(monitor.isExcluded(file: "bundle.js.map"))
    }

    func testExcludesVendorDirs() {
        let monitor = GitMonitor.shared
        XCTAssertTrue(monitor.isExcluded(file: "node_modules/react/index.js"))
        XCTAssertTrue(monitor.isExcluded(file: "dist/bundle.js"))
        XCTAssertTrue(monitor.isExcluded(file: "build/output.css"))
        XCTAssertTrue(monitor.isExcluded(file: ".next/cache/webpack.js"))
        XCTAssertTrue(monitor.isExcluded(file: "vendor/rails/helper.rb"))
        XCTAssertTrue(monitor.isExcluded(file: "__pycache__/module.pyc"))
    }

    func testExcludesDirAtStartOfPath() {
        let monitor = GitMonitor.shared
        // hasPrefix("dist/") should match
        XCTAssertTrue(monitor.isExcluded(file: "dist/main.js"))
        // hasPrefix("node_modules/") should match
        XCTAssertTrue(monitor.isExcluded(file: "node_modules/pkg/index.js"))
    }

    // MARK: - Exclusion rules (not excluded — normal source files)

    func testIncludesNormalSourceFiles() {
        let monitor = GitMonitor.shared
        XCTAssertFalse(monitor.isExcluded(file: "src/main.swift"))
        XCTAssertFalse(monitor.isExcluded(file: "app/models/user.rb"))
        XCTAssertFalse(monitor.isExcluded(file: "components/Button.tsx"))
        XCTAssertFalse(monitor.isExcluded(file: "tests/test_parser.py"))
        XCTAssertFalse(monitor.isExcluded(file: "pkg/handler.go"))
        XCTAssertFalse(monitor.isExcluded(file: "README.md"))
        XCTAssertFalse(monitor.isExcluded(file: "Makefile"))
        XCTAssertFalse(monitor.isExcluded(file: ".gitignore"))
    }

    func testDoesNotExcludePartialDirMatch() {
        let monitor = GitMonitor.shared
        // "dist" inside a word should NOT be excluded
        XCTAssertFalse(monitor.isExcluded(file: "src/distribute/main.swift"))
    }

    // MARK: - Exclusion rule set completeness

    func testExcludedSuffixesNotEmpty() {
        XCTAssertFalse(GitMonitor.excludedSuffixes.isEmpty)
    }

    func testExcludedSuffixesContainsLockfiles() {
        XCTAssertTrue(GitMonitor.excludedSuffixes.contains(".lock"))
        XCTAssertTrue(GitMonitor.excludedSuffixes.contains("package-lock.json"))
        XCTAssertTrue(GitMonitor.excludedSuffixes.contains("pnpm-lock.yaml"))
        XCTAssertTrue(GitMonitor.excludedSuffixes.contains("yarn.lock"))
    }

    // MARK: - CodeChange model

    func testCodeChangeIsMergeDetection() {
        let merge = CodeChange(
            commitHash: "abc123", ts: 1000, repoPath: "/test",
            added: 100, deleted: 50, isMerge: true
        )
        XCTAssertTrue(merge.isMerge)
        // Merge commits should be excluded from line counting
    }

    func testCodeChangeNetLines() {
        let change = CodeChange(
            commitHash: "def456", ts: 2000, repoPath: "/test",
            added: 200, deleted: 80, isMerge: false
        )
        // Net = added - deleted = 120
        XCTAssertEqual(change.added - change.deleted, 120)
    }
}
