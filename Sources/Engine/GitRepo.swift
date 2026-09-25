import Foundation
import Clibgit2

struct GitCommitSummary: Sendable {
    let hash: String
    let ts: Int
    let parentCount: Int
    let message: String
    let authorEmail: String
}

struct GitLogBatch: Sendable {
    let headHash: String?
    let commits: [GitCommitSummary]
}

enum GitReadError: Error {
    case operation(String, Int32)
}

/// libgit2-backed Git repository reader.
/// Replaces `Process("git", ...)` calls for sandbox compatibility.
struct GitRepo {
    let path: String

    /// Call once at app startup before any GitRepo operations.
    static func setup() { git_libgit2_init() }
    /// Call once at app termination.
    static func teardown() { git_libgit2_shutdown() }

    /// Thread-safe lazy one-time init for entry points that may run before
    /// `setup()` (or in tests). Unlike `verifiedWorkingRoot`'s former
    /// init/shutdown pair, this never tears the global libgit2 state back
    /// down, so repeated validation calls no longer churn the global lock.
    private static let ensureInitialized: Void = { git_libgit2_init() }()

    /// Find the git repository root containing the given path.
    /// Returns nil if the path is not inside a git repository.
    static func findRoot(containing path: String) -> String? {
        RepositoryScope.gitRoot(containing: path)
    }

    /// Validate a candidate working tree, including linked worktrees. Opening
    /// is read-only and does not rely on a subprocess or a marker's existence.
    static func verifiedWorkingRoot(at path: String) -> String? {
        _ = ensureInitialized
        var pointer: OpaquePointer?
        guard git_repository_open(&pointer, path) == 0, let repository = pointer else { return nil }
        defer { git_repository_free(repository) }
        guard let workdir = git_repository_workdir(repository) else { return nil }
        let root = RepositoryScope.canonicalPath(String(cString: workdir))
        return root == RepositoryScope.canonicalPath(path) ? root : nil
    }

    /// Walk the captured HEAD completely; no fixed 20-commit cap. A failed
    /// read throws so the monitor cannot advance its cursor past missing data.
    nonisolated func log(since lastHash: String?, sinceTimestamp: Int? = nil,
                        authorEmail: String? = nil) throws -> GitLogBatch {
        var repoPtr: OpaquePointer?
        let opened = git_repository_open(&repoPtr, path)
        guard opened == 0, let repo = repoPtr else { throw GitReadError.operation("open", opened) }
        defer { git_repository_free(repo) }
        var reference: OpaquePointer?
        let headStatus = git_repository_head(&reference, repo)
        if headStatus == GIT_EUNBORNBRANCH.rawValue || headStatus == GIT_ENOTFOUND.rawValue {
            return GitLogBatch(headHash: nil, commits: [])
        }
        guard headStatus == 0, let head = reference else { throw GitReadError.operation("HEAD", headStatus) }
        defer { git_reference_free(head) }
        guard let target = git_reference_target(head) else { throw GitReadError.operation("HEAD target", -1) }
        let headHash = String(cString: git_oid_tostr_s(target))
        var walker: OpaquePointer?
        let created = git_revwalk_new(&walker, repo)
        guard created == 0, let walk = walker else { throw GitReadError.operation("revwalk", created) }
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
        let pushed = git_revwalk_push(walk, target)
        guard pushed == 0 else { throw GitReadError.operation("push", pushed) }
        if let lastHash {
            var previous = git_oid()
            if git_oid_fromstr(&previous, lastHash) == 0 {
                // A removed/unavailable cursor causes an idempotent rescan.
                _ = git_revwalk_hide(walk, &previous)
            }
        } else if let sinceTimestamp {
            // Full rescan (nil cursor): hide the oldest first-parent ancestor
            // that falls inside the coverage window so the walk cannot run
            // past the window on long-lived repositories. Hiding an oid prunes
            // its entire ancestry; recently-merged side branches above the
            // anchor are still covered by the per-commit timestamp filter.
            if var anchor = boundaryAnchor(oid: target, repo: repo, sinceTimestamp: sinceTimestamp) {
                _ = git_revwalk_hide(walk, &anchor)
            }
        }
        var results: [GitCommitSummary] = []
        var oid = git_oid()
        var status = git_revwalk_next(&oid, walk)
        while status == 0 {
            var commitPtr: OpaquePointer?
            let lookedUp = git_commit_lookup(&commitPtr, repo, &oid)
            guard lookedUp == 0, let commit = commitPtr else { throw GitReadError.operation("commit", lookedUp) }
            defer { git_commit_free(commit) }
            let timestamp = Int(git_commit_time(commit))
            let email = git_commit_author(commit).flatMap { $0.pointee.email }.map { String(cString: $0) } ?? ""
            if (sinceTimestamp == nil || timestamp >= sinceTimestamp!) &&
                (authorEmail == nil || email.caseInsensitiveCompare(authorEmail!) == .orderedSame) {
                results.append(GitCommitSummary(
                    hash: String(cString: git_oid_tostr_s(git_commit_id(commit))),
                    ts: timestamp, parentCount: Int(git_commit_parentcount(commit)),
                    message: git_commit_message(commit).map { String(cString: $0) } ?? "",
                    authorEmail: email))
            }
            status = git_revwalk_next(&oid, walk)
        }
        guard status == GIT_ITEROVER.rawValue else { throw GitReadError.operation("walk", status) }
        return GitLogBatch(headHash: headHash, commits: results)
    }

    /// Walk HEAD's first-parent chain just far enough to find the oldest commit
    /// at or newer than `sinceTimestamp`, then return its first out-of-window
    /// parent as the hide anchor. Cheap: one commit lookup per first-parent
    /// link inside the window, no diffs. Returns nil when the whole history is
    /// inside the window or the chain cannot be followed (the walk then simply
    /// falls back to per-commit filtering).
    private nonisolated func boundaryAnchor(oid start: UnsafePointer<git_oid>,
                                            repo: OpaquePointer,
                                            sinceTimestamp: Int) -> git_oid? {
        var cursor = start.pointee
        var anchor: git_oid?
        while anchor == nil {
            var commitPtr: OpaquePointer?
            guard git_commit_lookup(&commitPtr, repo, &cursor) == 0, let commit = commitPtr else { break }
            defer { git_commit_free(commit) }
            guard Int(git_commit_time(commit)) >= sinceTimestamp else { break }
            guard git_commit_parentcount(commit) > 0 else { break }
            guard let parentId = git_commit_parent_id(commit, 0) else { break }
            var parent = parentId.pointee
            var parentPtr: OpaquePointer?
            guard git_commit_lookup(&parentPtr, repo, &parent) == 0, let parentCommit = parentPtr else { break }
            defer { git_commit_free(parentCommit) }
            if Int(git_commit_time(parentCommit)) < sinceTimestamp {
                anchor = parent
                break
            }
            cursor = parent
        }
        return anchor
    }

    /// Read the git `user.email` for this repository.
    /// Checks repo-local config first, then global `~/.gitconfig`.
    nonisolated func userEmail() -> String? {
        var repoPtr: OpaquePointer?
        guard git_repository_open(&repoPtr, path) == 0, let repo = repoPtr else { return nil }
        defer { git_repository_free(repo) }

        // Use config snapshot: merges local + global + system levels
        var cfgPtr: OpaquePointer?
        guard git_repository_config_snapshot(&cfgPtr, repo) == 0, let cfg = cfgPtr else { return nil }
        defer { git_config_free(cfg) }

        var cValue: UnsafePointer<CChar>?
        guard git_config_get_string(&cValue, cfg, "user.email") == 0, let ptr = cValue else {
            return nil
        }
        return String(cString: ptr)
    }

    /// Get per-file added/deleted lines for a commit, excluding generated/lock files.
    nonisolated func diffTree(hash: String) -> (added: Int, deleted: Int)? {
        var repoPtr: OpaquePointer?
        guard git_repository_open(&repoPtr, path) == 0, let repo = repoPtr else { return nil }
        defer { git_repository_free(repo) }

        var oid = git_oid()
        guard git_oid_fromstr(&oid, hash) == 0 else { return nil }

        var commitPtr: OpaquePointer?
        guard git_commit_lookup(&commitPtr, repo, &oid) == 0, let commit = commitPtr else { return nil }
        defer { git_commit_free(commit) }

        // Get commit tree
        var treePtr: OpaquePointer?
        guard git_commit_tree(&treePtr, commit) == 0, let tree = treePtr else { return nil }
        defer { git_tree_free(tree) }

        // Get parent tree (first parent, not merge parents)
        var parentTree: OpaquePointer? = nil
        if git_commit_parentcount(commit) > 0 {
            var parentPtr: OpaquePointer?
            guard git_commit_parent(&parentPtr, commit, 0) == 0, let parent = parentPtr else { return nil }
            defer { git_commit_free(parent) }
            var ptPtr: OpaquePointer?
            guard git_commit_tree(&ptPtr, parent) == 0, let pt = ptPtr else { return nil }
            parentTree = pt
        }
        defer { if let pt = parentTree { git_tree_free(pt) } }

        // Diff commit tree against parent tree
        var diffPtr: OpaquePointer?
        guard git_diff_tree_to_tree(&diffPtr, repo, parentTree, tree, nil) == 0,
              let diff = diffPtr else { return nil }
        defer { git_diff_free(diff) }

        var added: Int = 0
        var deleted: Int = 0

        let deltas = git_diff_num_deltas(diff)
        for i in 0..<deltas {
            let rawDelta = git_diff_get_delta(diff, i)
            guard let delta = rawDelta else { return nil }
            let file = String(cString: delta.pointee.new_file.path)
            if Self.isExcluded(file: file) { continue }

            // Get per-file patch to count lines
            var patchPtr: OpaquePointer?
            guard git_patch_from_diff(&patchPtr, diff, i) == 0 else { return nil }
            // Binary changes legitimately have no text patch or line counts.
            guard let patch = patchPtr else { continue }
            defer { git_patch_free(patch) }

            var fileAdded: Int = 0
            var fileDeleted: Int = 0
            guard git_patch_line_stats(&fileAdded, &fileDeleted, nil, patch) == 0 else { return nil }
            added += fileAdded
            deleted += fileDeleted
        }
        return (added, deleted)
    }

    // MARK: - Exclusion filter (mirrors GitMonitor)

    private static nonisolated let excludedSuffixes: Set<String> = [
        ".lock", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
        ".pb.go", ".generated.swift", ".generated.ts", ".graphql",
        ".min.js", ".min.css", ".map"
    ]
    private static nonisolated let excludedDirs: Set<String> = [
        "node_modules", "dist", "build", ".next", "vendor", "__pycache__"
    ]

    static nonisolated func isExcluded(file: String) -> Bool {
        for suffix in excludedSuffixes where file.hasSuffix(suffix) { return true }
        for dir in excludedDirs where file.contains("/\(dir)/") || file.hasPrefix("\(dir)/") { return true }
        return false
    }
}
