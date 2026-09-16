import Foundation
import GRDB

struct CodeChange: Codable {
    let commitHash: String
    let ts: Int        // epoch ms
    let repoPath: String
    let added: Int
    let deleted: Int
    let isMerge: Bool
    /// AI tool that produced this change (v2 WI-5). nil = unattributed →
    /// the row stays对照-only and never counts as consumption (§4.6 铁律).
    var attributedTool: String?
    /// "uncertain" for every attribution signal: a trailer or editor session
    /// cannot prove line-level authorship.
    var attribution: String?
}

/// Monitors git repositories for new commits and extracts net line changes
nonisolated final class GitMonitor: @unchecked Sendable {
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
            let (seen, watched) = try await AppDatabase.shared.read { db -> (seen: [String: String], watched: Set<String>) in
                let rows = try Row.fetchAll(db, sql: "SELECT repo_path, last_commit FROM gitmonitor_state")
                var seen = [String: String]()
                var watched = Set<String>()
                for r in rows {
                    if let path: String = r["repo_path"] {
                        watched.insert(path)
                        if let hash: String = r["last_commit"] { seen[path] = hash }
                    }
                }
                return (seen, watched)
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
        let canonical = RepositoryScope.canonicalPath(repoPath)
        guard RepositoryScope.authorizedGitRoot(for: canonical) == canonical else { return }
        lock.lock()
        let inserted = watchedRepos.insert(canonical).inserted
        lock.unlock()
        guard inserted else { return }
        persistWatchedRepos()
        // Scan existing commits
        scanRecentCommits(repo: canonical)
    }

    /// Stops polling repositories that are no longer under a configured
    /// development root. Historical usage and code-change facts are untouched.
    func pruneWatchedRepos(outside roots: [String]) {
        lock.lock()
        let removed = watchedRepos.filter { !RepositoryScope.isInsideConfiguredRoots($0, roots: roots) }
        watchedRepos.subtract(removed)
        for path in removed { lastSeenCommit.removeValue(forKey: path) }
        let remainingRepos = Array(watchedRepos)
        let remainingSeen = lastSeenCommit
        lock.unlock()
        guard !removed.isEmpty else { return }
        UserDefaults.standard.set(remainingRepos, forKey: Self.watchedReposKey)
        UserDefaults.standard.set(remainingSeen, forKey: Self.lastSeenKey)
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    for path in removed {
                        try db.execute(sql: "DELETE FROM gitmonitor_state WHERE repo_path = ?", arguments: [path])
                    }
                }
            } catch {
                Logger.error("GitMonitor: prune watched repos failed: \(error)")
            }
        }
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
                    // Signal 1 (强): git trailer self-attribution — tools that
                    // commit themselves sign their work (e.g. Co-Authored-By: Claude).
                    let trailerTool = Self.attributedToolFromTrailer(commit.message)
                    changes.append(CodeChange(
                        commitHash: commit.hash, ts: commit.ts * 1000,
                        repoPath: repo, added: stats.added, deleted: stats.deleted,
                        isMerge: commit.parentCount >= 2,
                        attributedTool: trailerTool,
                        attribution: trailerTool != nil ? "uncertain" : nil
                    ))
                }
                newHash = commit.hash
            }

            // Dispatch to the main queue instead of `Task { @MainActor }` — creating
            // a MainActor-isolated Task from this GCD block (gitOpQueue) trips
            // Swift's isolation check and crashes on quit.
            DispatchQueue.main.async { [self, changes, newHash, repo, repoName] in
                MainActor.assumeIsolated {
                    // Signal 2 (中, uncertain): editor-session × timing — a change
                    // landing while an AI editor has this repo open attributes to it.
                    var sessionMappings: [EditorDetector.Mapping] = []
                    if changes.contains(where: { $0.attributedTool == nil }) {
                        sessionMappings = EditorDetector.detect()
                    }
                    let attributed = changes.map { change -> CodeChange in
                        var c = change
                        if c.attributedTool == nil,
                           let m = sessionMappings.first(where: { $0.repoPath == repo }) {
                            c.attributedTool = m.toolName
                            c.attribution = "uncertain"
                        }
                        return c
                    }
                    for change in attributed { insertChange(change) }
                    if let h = newHash { lock.withLock { lastSeenCommit[repo] = h } }
                    persistLastSeen()
                    AppHealthMonitor.shared.clearAPIError(providerId: "git-\(repoName)")
                }
            }
        }
    }

    /// git trailer self-attribution (WI-5 信号一): scan the message from the
    /// bottom for tool-authored trailers. Returns the raw tool name, or nil.
    static func attributedToolFromTrailer(_ message: String) -> String? {
        for rawLine in message.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("co-authored-by:") {
                let value = line.dropFirst("co-authored-by:".count).trimmingCharacters(in: .whitespaces)
                // "Claude <noreply@anthropic.com>" → "Claude"
                let tool = value.split(separator: "<").first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? value
                if !tool.isEmpty { return tool }
            } else if lower.hasPrefix("generated-with:") {
                let tool = line.dropFirst("generated-with:".count).trimmingCharacters(in: .whitespaces)
                if !tool.isEmpty { return tool }
            }
        }
        return nil
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
                        INSERT OR IGNORE INTO code_change (commit_hash, ts, repo_path, added, deleted, is_merge, attributed_tool, attribution)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [change.commitHash, change.ts, change.repoPath, change.added, change.deleted, change.isMerge, change.attributedTool, change.attribution])
                }
                DataRefreshCoordinator.shared.notifyPhaseGitScan()
            } catch {
                Logger.error("Failed to insert code_change: \(error)")
            }
        }
    }
}
