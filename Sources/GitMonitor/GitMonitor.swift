import Foundation
import GRDB

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
    /// Guards `watchedRepos` and `lastSeenCommit`. `watch()` can be invoked from
    /// multiple background contexts (initial scan, FSEvent handlers), so the
    /// shared state must be synchronized to avoid data races.
    private let lock = NSLock()
    private var watchedRepos: Set<String> = []
    private var lastSeenCommit: [String: String] = [:] // repo -> last processed commit hash

    private static let watchedReposKey = "gitmonitor_watched_repos"
    private static let lastSeenKey = "gitmonitor_last_seen"

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.watchedReposKey) {
            watchedRepos = Set(saved)
        }
        if let saved = UserDefaults.standard.dictionary(forKey: Self.lastSeenKey) as? [String: String] {
            lastSeenCommit = saved
        }
    }

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
        lock.lock()
        let inserted = watchedRepos.insert(repoPath).inserted
        lock.unlock()
        guard inserted else { return }
        persistWatchedRepos()
        // Scan existing commits
        scanRecentCommits(repo: repoPath)
    }

    /// Poll watched repos - called periodically or after log ingestion
    func poll() {
        lock.lock()
        let repos = watchedRepos
        lock.unlock()
        for repo in repos {
            scanRecentCommits(repo: repo)
        }
    }

    // MARK: - Private

    private func scanRecentCommits(repo: String) {
        lock.lock()
        let lastHash = lastSeenCommit[repo]
        lock.unlock()
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

            lock.lock()
            lastSeenCommit[repo] = commit.hash
            lock.unlock()
        }
        persistLastSeen()
    }

    /// Check whether a file path matches exclusion patterns (lockfiles,
    /// generated code, vendor dirs, etc.).
    func isExcluded(file: String) -> Bool {
        for suffix in Self.excludedSuffixes where file.hasSuffix(suffix) { return true }
        for dir in Self.excludedDirs where file.contains("/\(dir)/") || file.hasPrefix("\(dir)/") { return true }
        return false
    }

    // MARK: - Persistence

    private func persistWatchedRepos() {
        lock.lock()
        let arr = Array(watchedRepos)
        lock.unlock()
        UserDefaults.standard.set(arr, forKey: Self.watchedReposKey)
    }

    private func persistLastSeen() {
        lock.lock()
        let dict = lastSeenCommit
        lock.unlock()
        UserDefaults.standard.set(dict, forKey: Self.lastSeenKey)
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
