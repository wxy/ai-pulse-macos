import Foundation

struct CodeChange: Codable {
    let commitHash: String
    let ts: Int        // epoch ms
    let repoPath: String
    let added: Int
    let deleted: Int
    let isMerge: Bool
}

/// Monitors git repositories for new commits and extracts net line changes
final class GitMonitor {
    static let shared = GitMonitor()
    private var watchedRepos: Set<String> = []
    private var lastSeenCommit: [String: String] = [:] // repo -> last processed commit hash

    /// Exclusion patterns for non-code files (glob-style)
    static let excludedSuffixes: Set<String> = [
        ".lock", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
        ".pb.go", ".generated.swift", ".generated.ts", ".graphql",
        ".min.js", ".min.css", ".map"
    ]
    private static let excludedDirs: Set<String> = [
        "node_modules", "dist", "build", ".next", "vendor", "__pycache__"
    ]

    /// Start watching a git repo for new commits
    func watch(repoPath: String) {
        guard !watchedRepos.contains(repoPath) else { return }
        watchedRepos.insert(repoPath)
        // Scan existing commits
        scanRecentCommits(repo: repoPath)
    }

    /// Poll watched repos - called periodically or after log ingestion
    func poll() {
        for repo in watchedRepos {
            scanRecentCommits(repo: repo)
        }
    }

    // MARK: - Private

    private func scanRecentCommits(repo: String) {
        let lastHash = lastSeenCommit[repo]
        let gitRepo = GitRepo(path: repo)
        let commits = gitRepo.log(since: lastHash)

        for commit in commits {
            guard let stats = gitRepo.diffTree(hash: commit.hash) else { continue }
            let isMerge = commit.parentCount >= 2

            if stats.added > 0 || stats.deleted > 0 {
                insertChange(CodeChange(
                    commitHash: commit.hash, ts: commit.ts * 1000,
                    repoPath: repo, added: stats.added, deleted: stats.deleted,
                    isMerge: isMerge
                ))
            }

            lastSeenCommit[repo] = commit.hash
        }
    }

    /// Check whether a file path matches exclusion patterns (lockfiles,
    /// generated code, vendor dirs, etc.).
    func isExcluded(file: String) -> Bool {
        for suffix in Self.excludedSuffixes where file.hasSuffix(suffix) { return true }
        for dir in Self.excludedDirs where file.contains("/\(dir)/") || file.hasPrefix("\(dir)/") { return true }
        return false
    }

    private func insertChange(_ change: CodeChange) {
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO code_change (commit_hash, ts, repo_path, added, deleted, is_merge)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [change.commitHash, change.ts, change.repoPath, change.added, change.deleted, change.isMerge])
                }
            } catch {
                print("Failed to insert code change: \(error)")
            }
        }
    }
}
