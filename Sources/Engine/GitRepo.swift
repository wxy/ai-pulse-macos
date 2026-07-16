import Foundation
import Clibgit2

/// libgit2-backed Git repository reader.
/// Replaces `Process("git", ...)` calls for sandbox compatibility.
struct GitRepo {
    let path: String

    /// Call once at app startup before any GitRepo operations.
    static func setup() { git_libgit2_init() }
    /// Call once at app termination.
    static func teardown() { git_libgit2_shutdown() }

    /// Find the git repository root containing the given path.
    /// Returns nil if the path is not inside a git repository.
    static func findRoot(containing path: String) -> String? {
        var current = path.hasPrefix("/") ? path : "/\(path)"
        while current != "/" {
            let gitPath = "\(current)/.git"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) {
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Get recent commits with (hash, timestamp, parent count).
    /// - Parameter authorEmail: If non-nil, only commits whose author email
    ///   matches are returned. Used to exclude collaborators' commits.
    ///   When filtering by author, `maxCount` is multiplied by 10 to ensure
    ///   we can walk past collaborator commits to find the user's own.
    nonisolated func log(since lastHash: String?, maxCount: Int = 20,
             authorEmail: String? = nil) -> [(hash: String, ts: Int, parentCount: Int)] {
        let effectiveMax = authorEmail != nil ? maxCount * 10 : maxCount
        var repoPtr: OpaquePointer?
        guard git_repository_open(&repoPtr, path) == 0, let repo = repoPtr else { return [] }
        defer { git_repository_free(repo) }

        var walker: OpaquePointer?
        guard git_revwalk_new(&walker, repo) == 0, let walk = walker else { return [] }
        defer { git_revwalk_free(walk) }

        git_revwalk_push_head(walk)
        if let lastHash {
            var oid = git_oid()
            git_oid_fromstr(&oid, lastHash)
            git_revwalk_hide(walk, &oid)
        }

        var results: [(String, Int, Int)] = []
        var oid = git_oid()
        while git_revwalk_next(&oid, walk) == 0, results.count < effectiveMax {
            var commitPtr: OpaquePointer?
            guard git_commit_lookup(&commitPtr, repo, &oid) == 0, let commit = commitPtr else { continue }
            defer { git_commit_free(commit) }

            // Filter by author email when specified (exclude collaborators)
            if let authorEmail {
                guard let sig = git_commit_author(commit) else { continue }
                let email = String(cString: sig.pointee.email)
                if email != authorEmail { continue }
            }

            let hash = String(cString: git_oid_tostr_s(git_commit_id(commit)))
            let ts = Int(git_commit_time(commit))
            let parentCount = Int(git_commit_parentcount(commit))
            results.append((hash, ts, parentCount))
            // Stop early when we have enough matching commits
            if results.count >= maxCount { break }
        }
        return results
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

        // Get parent tree (first parent, not merge parents)
        var parentTree: OpaquePointer? = nil
        if git_commit_parentcount(commit) > 0 {
            var parentPtr: OpaquePointer?
            if git_commit_parent(&parentPtr, commit, 0) == 0, let parent = parentPtr {
                var ptPtr: OpaquePointer?
                git_commit_tree(&ptPtr, parent)
                parentTree = ptPtr
                git_commit_free(parent)
            }
        }

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
            guard let delta = rawDelta else { continue }
            let file = String(cString: delta.pointee.new_file.path)
            if Self.isExcluded(file: file) { continue }

            // Get per-file patch to count lines
            var patchPtr: OpaquePointer?
            guard git_patch_from_diff(&patchPtr, diff, i) == 0, let patch = patchPtr else { continue }
            defer { git_patch_free(patch) }

            var fileAdded: Int = 0
            var fileDeleted: Int = 0
            git_patch_line_stats(&fileAdded, &fileDeleted, nil, patch)
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
