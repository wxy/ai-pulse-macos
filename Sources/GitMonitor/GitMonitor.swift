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
final class GitMonitor: @unchecked Sendable {
    static let shared = GitMonitor()
    /// Guards `watchedRepos` and `lastSeenCommit`. `watch()` can be invoked from
    /// multiple background contexts (initial scan, FSEvent handlers), so the
    /// shared state must be synchronized to avoid data races.
    private let lock = NSLock()
    private var watchedRepos: Set<String> = []
    private var lastSeenCommit: [String: String] = [:] // repo -> last processed commit hash
    /// Concurrent queue for running libgit2 operations with a timeout,
    /// so a hung repo never blocks the serial notifyQueue indefinitely.
    private let gitOpQueue = DispatchQueue(label: "com.wxy.aipulse.git.op",
                                           qos: .utility, attributes: .concurrent)

    /// Read-only snapshot of currently watched repo paths.
    /// Used by RepoDiscovery to diff against the filesystem.
    var watchedRepoPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return watchedRepos
    }

    private static let watchedReposKey = "gitmonitor_watched_repos"
    private static let lastSeenKey = "gitmonitor_last_seen"

    /// Ensures DB state is loaded before the first poll() runs.
    private let loadGroup = DispatchGroup()

    private init() {
        loadGroup.enter()
        Task { await loadFromDB(); loadGroup.leave() }
    }

    private func loadFromDB() async {
        do {
            let rows = try await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT repo_path, last_commit FROM gitmonitor_state")
            }
            var seen = [String: String]()
            var watched = Set<String>()
            for r in rows {
                if let path: String = r["repo_path"] {
                    watched.insert(path)
                    if let hash: String = r["last_commit"] { seen[path] = hash }
                }
            }
            lock.withLock {
                if !watched.isEmpty { watchedRepos = watched }
                if !seen.isEmpty { lastSeenCommit = seen }
                // Fall back to UserDefaults if DB returned empty (e.g. fresh migration)
                if watchedRepos.isEmpty, let saved = UserDefaults.standard.stringArray(forKey: Self.watchedReposKey) {
                    watchedRepos = Set(saved)
                }
                if lastSeenCommit.isEmpty, let saved = UserDefaults.standard.dictionary(forKey: Self.lastSeenKey) as? [String: String] {
                    lastSeenCommit = saved
                }
            }
        } catch {
            // DB not ready; fall back to UserDefaults
            lock.withLock {
                if let saved = UserDefaults.standard.stringArray(forKey: Self.watchedReposKey) {
                    watchedRepos = Set(saved)
                }
                if let saved = UserDefaults.standard.dictionary(forKey: Self.lastSeenKey) as? [String: String] {
                    lastSeenCommit = saved
                }
            }
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
        if loadGroup.wait(timeout: .now() + 5.0) == .timedOut {
            Logger.warning("GitMonitor: DB state load timed out after 5s, falling back to in-memory state")
        }
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
        let repoName = URL(fileURLWithPath: repo).lastPathComponent

        gitOpQueue.async { [self] in
            let gitRepo = GitRepo(path: repo)
            let authorEmail = gitRepo.userEmail()
            let commits = gitRepo.log(since: lastHash, authorEmail: authorEmail)

            var changes: [CodeChange] = []
            var newHash: String?
            for commit in commits {
                guard let stats = gitRepo.diffTree(hash: commit.hash) else { continue }
                if stats.added > 0 || stats.deleted > 0 {
                    changes.append(CodeChange(
                        commitHash: commit.hash, ts: commit.ts * 1000,
                        repoPath: repo, added: stats.added, deleted: stats.deleted,
                        isMerge: commit.parentCount >= 2
                    ))
                }
                newHash = commit.hash
            }

            Task { @MainActor [self, changes, newHash, repo, repoName] in
                for change in changes { insertChange(change) }
                if let h = newHash { lastSeenCommit[repo] = h }
                persistLastSeen()
                AppHealthMonitor.shared.clearAPIError(providerId: "git-\(repoName)")
            }
        }
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
        // Write watched repos to DB (best-effort)
        lock.lock()
        let arr = Array(watchedRepos)
        lock.unlock()
        UserDefaults.standard.set(arr, forKey: Self.watchedReposKey)  // keep as fallback
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    for repo in arr {
                        try db.execute(sql: """
                            INSERT OR IGNORE INTO gitmonitor_state (repo_path) VALUES (?)
                            """, arguments: [repo])
                    }
                }
            } catch { Logger.error("GitMonitor: persist watched repos failed: \(error)") }
        }
    }

    private func persistLastSeen() {
        lock.lock()
        let dict = lastSeenCommit
        lock.unlock()
        UserDefaults.standard.set(dict, forKey: Self.lastSeenKey)  // keep as fallback
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    for (repo, hash) in dict {
                        try db.execute(sql: """
                            INSERT OR REPLACE INTO gitmonitor_state (repo_path, last_commit) VALUES (?, ?)
                            """, arguments: [repo, hash])
                    }
                }
            } catch { Logger.error("GitMonitor: persist watched repos failed: \(error)") }
        }
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
                DataRefreshCoordinator.shared.notifyPhaseGitScan()
            } catch {
                Logger.error("Failed to insert code_change: \(error)")
            }
        }
    }
}
