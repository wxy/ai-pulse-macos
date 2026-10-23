import Foundation
import GRDB

struct CodeChange: Codable {
    let commitHash: String
    let ts: Int        // epoch ms
    let repoPath: String
    let added: Int
    let deleted: Int
    let isMerge: Bool
    /// Recognized tool declared in the commit trailer, not proven authorship.
    var attributedTool: String?
    /// Observation provenance. "trailer" is still not line-level authorship.
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
    private var scanningRepos: Set<String> = []
    /// Concurrent queue for libgit2 operations. Slots cap how many native
    /// reads run at once (2026-10-23 review F04): without a bound, every
    /// repository's full log/diff ran simultaneously and stacked CPU, disk,
    /// and native object memory pressure. Synchronous C calls cannot be
    /// aborted mid-flight, so the per-read deadline is enforced at the Swift
    /// loop boundaries (before/inside the per-commit diff loop) instead of
    /// claiming to time out each libgit2 call.
    private let gitOpQueue = DispatchQueue(label: "com.wxy.aipulse.git.op",
                                           qos: .utility, attributes: .concurrent)
    /// Each worker owns its read and persistence. A slow database therefore
    /// applies backpressure instead of accumulating unbounded result batches.
    private let gitReadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "xingyu.wang.aipulse.git.read"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    /// Wall-clock budget for one repository's remaining diff work. A pass that runs out
    /// stops diffing with `complete = false`: facts collected so far persist,
    /// the cursor stays at the previous head, and the next poll retries.
    private static let scanPassBudgetSeconds: TimeInterval = 60
    /// Upper bound for `pollAndWait`, so an explicit refresh cannot hang
    /// forever behind a pathologically slow repository read.
    private static let explicitRefreshWaitLimit: TimeInterval = 120

    /// Read-only snapshot of currently watched repo paths.
    /// Used by RepoDiscovery to diff against the filesystem.
    var watchedRepoPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return watchedRepos
    }

    private static let watchedReposKey = "gitmonitor_watched_repos"

    private let stateLoadGate = GitStateLoadGate()
    private let statePersistenceQueue = DispatchQueue(label: "xingyu.wang.aipulse.git.state", qos: .utility)

    private init() {
        Task { _ = await stateLoadGate.ensureLoaded { await self.loadFromDB() } }
    }

    private func loadFromDB() async -> Bool {
        do {
            let (seen, watched) = try await AppDatabase.shared.read { db -> (seen: [String: String], watched: Set<String>) in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT s.repo_path, c.head_hash AS last_commit FROM gitmonitor_state s
                    LEFT JOIN git_commit_scan c ON c.repo_path = s.repo_path
                    """)
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
            var authorization = RepositoryScope.AuthorizedRootLookup(roots: RepositoryScope.configuredRoots())
            let restored = watched.filter { authorization.root(for: $0) != nil }
            let saved = UserDefaults.standard.stringArray(forKey: Self.watchedReposKey) ?? []
            let restoredFallback = saved.filter { authorization.root(for: $0) != nil }
            lock.withLock {
                // Loading may complete after watch/scan has already added live
                // state. Never replace it with the older database snapshot.
                watchedRepos.formUnion(restored)
                lastSeenCommit.merge(seen) { live, _ in live }
                // Fall back to UserDefaults if DB returned empty (e.g. fresh migration)
                if watchedRepos.isEmpty { watchedRepos.formUnion(restoredFallback) }
            }
            AppHealthMonitor.shared.clearIngestError(source: "Git.state.load")
            return true
        } catch {
            AppHealthMonitor.shared.reportIngestError(error.localizedDescription, source: "Git.state.load")
            // DB not ready; fall back to UserDefaults.
            var authorization = RepositoryScope.AuthorizedRootLookup(roots: RepositoryScope.configuredRoots())
            let saved = UserDefaults.standard.stringArray(forKey: Self.watchedReposKey) ?? []
            let restored = saved.filter { authorization.root(for: $0) != nil }
            lock.withLock { watchedRepos.formUnion(restored) }
            return false
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

    /// Authorization for monitor-internal decisions (watch, scan, prune).
    /// Repositories canonically inside a configured root resolve cheaply; a
    /// linked repository falls back to the generation-cached reachable-roots
    /// answer instead of re-walking the whole development tree per watch, per
    /// poll, or per batch (2026-10-23 review F02).
    private func authorizedRoot(for path: String) -> String? {
        guard let repo = RepositoryScope.gitRoot(containing: path) else { return nil }
        let roots = RepositoryScope.configuredRoots()
        if RepositoryScope.isCanonicallyInside(repo, roots: roots) { return repo }
        return RepositoryScope.generationReachableRoots(in: roots).contains(repo) ? repo : nil
    }

    /// Start watching a git repo for new commits
    func watch(repoPath: String) {
        let canonical = RepositoryScope.canonicalPath(repoPath)
        // Existing watches are revalidated by pruning and every commit scan.
        // Repeated log discovery must not rewalk the tree for each file.
        if lock.withLock({ watchedRepos.contains(canonical) }) { return }
        guard authorizedRoot(for: canonical) == canonical else { return }
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
    ///
    /// Callers on the UI thread must use `pruneWatchedReposInBackground` —
    /// authorizing a linked repository can walk the development tree, and
    /// that walk has no deadline (2026-10-23 review F02).
    func pruneWatchedRepos(outside roots: [String]) {
        // One generation answer serves every watched repository in this call;
        // the lookup consults it lazily, so all-inside setups never walk.
        var lookup = RepositoryScope.AuthorizedRootLookup(
            roots: roots,
            sharedReachableRoots: { RepositoryScope.generationReachableRoots(in: roots) })
        let candidates = watchedRepoPaths
        let removed = candidates.filter { lookup.root(for: $0) == nil }
        lock.lock()
        watchedRepos.subtract(removed)
        for path in removed { lastSeenCommit.removeValue(forKey: path) }
        lock.unlock()
        guard !removed.isEmpty else { return }
        for path in removed {
            AppHealthMonitor.shared.clearIngestError(source: "Git.scan.\(path)")
        }
        persistWatchedRepos()
    }

    /// Off-main-thread prune for UI-thread callers. The walk still happens
    /// (a linked repository must revalidate against the real tree), but the
    /// main thread only awaits it (F02).
    func pruneWatchedReposInBackground(outside roots: [String]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async { [self] in
                pruneWatchedRepos(outside: roots)
                continuation.resume()
            }
        }
    }

    /// Poll watched repos - called periodically or after log ingestion
    func poll() {
        // Wait asynchronously; never stall the UI/coordinator thread.
        Task { [self] in
            guard await stateLoadGate.ensureLoaded({ await self.loadFromDB() }) else { return }
            // Re-persist only when a previous write failed, not every tick.
            let needsRetry = lock.withLock { lastWatchPersistFailed }
            if needsRetry { persistWatchedRepos() } // retry any previous watch-list write failure
            gitOpQueue.async { [self] in pollLoadedState() }
        }
    }

    /// Completes one repository poll — the reads AND their database
    /// persistence — before returning, so an explicit refresh rebuilds
    /// dashboard snapshots from the latest committed changes (F06). Dispatch
    /// alone is not completion: each read continues into a database Task, and
    /// an already-in-flight scan is deduplicated rather than restarted.
    func pollAndWait() async {
        guard await stateLoadGate.ensureLoaded({ await self.loadFromDB() }) else { return }
        let claimed: Set<String> = await withCheckedContinuation { continuation in
            gitOpQueue.async { [self] in
                continuation.resume(returning: pollLoadedState())
            }
        }
        // `scanningRepos` releases only after a repo's read and its
        // persistence Task finish, so waiting for the round's repos (plus any
        // already in flight when the round was captured) to drain waits for
        // exactly the facts this refresh must include.
        var pending = claimed.union(lock.withLock { scanningRepos })
        let deadline = Date().addingTimeInterval(Self.explicitRefreshWaitLimit)
        while !pending.isEmpty {
            guard Date() < deadline else {
                Logger.warning("GitMonitor: explicit refresh proceeded with \(pending.count) scan(s) unfinished")
                break
            }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return } // Cancellation stops waiting; owned scans still finish.
            pending = pending.intersection(lock.withLock { scanningRepos })
        }
    }

    /// Dispatches one read per watched repo. Returns the repositories claimed
    /// this round (dedup may skip repos already scanning).
    @discardableResult
    private func pollLoadedState() -> Set<String> {
        lock.lock()
        let repos = watchedRepos
        lock.unlock()
        var claimed: Set<String> = []
        for repo in repos {
            if scanRecentCommits(repo: repo) { claimed.insert(repo) }
        }
        return claimed
    }

    // MARK: - Private

    /// Claims and dispatches one bounded read pass for `repo`. Returns false
    /// when the repo was unauthorized or already queued/scanning. Every other
    /// repository is queued, including when both native readers are occupied.
    @discardableResult
    private func scanRecentCommits(repo: String) -> Bool {
        guard authorizedRoot(for: repo) != nil else { return false }
        let state = lock.withLock { () -> (Bool, String?) in
            guard !scanningRepos.contains(repo) else { return (false, nil) }
            scanningRepos.insert(repo)
            return (true, lastSeenCommit[repo])
        }
        guard state.0 else { return false }
        let lastHash = state.1
        let repoName = URL(fileURLWithPath: repo).lastPathComponent
        let activity = LocalDataProcessing.shared.begin(.reading)
        gitReadQueue.addOperation { [self] in
            defer {
                activity.finish()
                lock.withLock { _ = scanningRepos.remove(repo) }
            }
            // Authorization can change while an operation waits in the queue.
            guard authorizedRoot(for: repo) != nil else {
                return
            }
            do {
                let gitRepo = GitRepo(path: repo)
                let authorEmail = gitRepo.userEmail()
                let calendar = Calendar.current
                let coverageStart = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: Date()))!
                let coverageSince = Int(coverageStart.timeIntervalSince1970 * 1000)
                let batch = try gitRepo.log(since: lastHash, sinceTimestamp: coverageSince / 1000, authorEmail: authorEmail)
                guard let head = batch.headHash else {
                    return
                }
                var changes: [CodeChange] = []
                let completedDiffs = try AppDatabase.shared.readSynchronously { db in
                    Set(try String.fetchAll(db, sql: """
                        SELECT commit_hash FROM git_commit
                        WHERE repo_path = ? AND ts >= ? AND diff_scanned = 1
                        """, arguments: [repo, coverageSince]))
                }
                var newlyCompletedDiffs: [String] = []
                var complete = true
                let passDeadline = Date().addingTimeInterval(Self.scanPassBudgetSeconds)
                for commit in batch.commits {
                    // A prior partial pass committed these results atomically
                    // with their progress markers, including zero-line diffs.
                    if completedDiffs.contains(commit.hash) { continue }
                    if Date() >= passDeadline {
                        complete = false
                        Logger.info("GitMonitor: scan pass deadline reached for \(repoName); will retry")
                        break
                    }
                    guard let stats = gitRepo.diffTree(hash: commit.hash) else { complete = false; continue }
                    newlyCompletedDiffs.append(commit.hash)
                    if stats.added > 0 || stats.deleted > 0 {
                        let tool = Self.attributedToolFromTrailer(commit.message)
                        changes.append(CodeChange(commitHash: commit.hash, ts: commit.ts * 1000,
                            repoPath: repo, added: stats.added, deleted: stats.deleted,
                            isMerge: commit.parentCount >= 2, attributedTool: tool,
                            attribution: tool == nil ? nil : "trailer"))
                    }
                }
                let readyChanges = changes
                let readyDiffs = newlyCompletedDiffs
                let readComplete = complete
                // Keep the bounded worker until persistence commits, so the
                // waiter and the queue share the same completion boundary.
                activity.update(.preparing)
                guard authorizedRoot(for: repo) != nil else { return }
                do {
                    let changed = try AppDatabase.shared.writeSynchronously { db in
                        try Self.persistBatch(in: db, repo: repo, commits: batch.commits,
                            changes: readyChanges, headHash: readComplete ? head : lastHash,
                            coverageSince: coverageSince, authorEmail: authorEmail,
                            complete: readComplete, completedDiffHashes: readyDiffs)
                    }
                    if readComplete { lock.withLock { lastSeenCommit[repo] = head } }
                    if changed { DataRefreshCoordinator.shared.notifyPhaseGitScan() }
                    if readComplete {
                        AppHealthMonitor.shared.clearIngestError(source: "Git.scan.\(repo)")
                    } else {
                        AppHealthMonitor.shared.reportIngestError(
                            "Some commit diffs could not be read; scan will retry.", source: "Git.scan.\(repo)")
                    }
                } catch {
                    Logger.error("Git batch persistence failed: \(error)")
                    AppHealthMonitor.shared.reportIngestError(error.localizedDescription, source: "Git.scan.\(repo)")
                }
            } catch {
                Logger.error("Git scan failed for \(repoName): \(error.localizedDescription)")
                if let gitError = error as? GitReadError, gitError.isPermissionFailure {
                    let roots = UserDefaults.standard.stringArray(forKey: "repo_search_dirs") ?? []
                    let logical = roots.first { DirectoryAccess.contains(repo, in: RepositoryScope.canonicalPath($0)) } ?? repo
                    DirectoryAccess.shared.record(CocoaError(.fileReadNoPermission), at: URL(fileURLWithPath: logical))
                    AppHealthMonitor.shared.clearIngestError(source: "Git.scan.\(repo)")
                } else {
                    AppHealthMonitor.shared.reportIngestError(error.localizedDescription, source: "Git.scan.\(repo)")
                }
            }
        }
        return true
    }

    /// Called within one database transaction. Commit identity is independent
    /// of line counts, and the cursor is committed only with the captured facts.
    static func persistBatch(in db: Database, repo: String, commits: [GitCommitSummary],
                             changes: [CodeChange], headHash: String?, coverageSince: Int,
                             authorEmail: String?, complete: Bool,
                             completedDiffHashes: [String] = []) throws -> Bool {
        var changed = false
        for commit in commits {
            try db.execute(sql: """
                INSERT OR IGNORE INTO git_commit
                  (repo_path, commit_hash, ts, parent_count, author_email, attributed_tool)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [repo, commit.hash, commit.ts * 1000, commit.parentCount,
                                 commit.authorEmail, attributedToolFromTrailer(commit.message)])
            changed = changed || db.changesCount > 0
        }
        for change in changes {
            try db.execute(sql: """
                INSERT OR IGNORE INTO code_change
                  (commit_hash, ts, repo_path, added, deleted, is_merge, attributed_tool, attribution)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [change.commitHash, change.ts, change.repoPath, change.added, change.deleted,
                                 change.isMerge, change.attributedTool, change.attribution])
            changed = changed || db.changesCount > 0
        }
        for hash in completedDiffHashes {
            try db.execute(sql: """
                UPDATE git_commit SET diff_scanned = 1 WHERE repo_path = ? AND commit_hash = ?
                """, arguments: [repo, hash])
        }
        try db.execute(sql: """
            INSERT INTO git_commit_scan (repo_path, head_hash, updated_at, coverage_since, author_email, status)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(repo_path) DO UPDATE SET head_hash = excluded.head_hash,
              updated_at = excluded.updated_at, coverage_since = excluded.coverage_since,
              author_email = excluded.author_email, status = excluded.status
            """, arguments: [repo, headHash, Int(Date().timeIntervalSince1970 * 1000), coverageSince,
                             authorEmail, complete ? "complete" : "partial"])
        return changed
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
                if Self.canonicalAttributedTool(tool) != nil { return tool }
            } else if lower.hasPrefix("generated-with:") {
                let tool = line.dropFirst("generated-with:".count).trimmingCharacters(in: .whitespaces)
                if Self.canonicalAttributedTool(tool) != nil { return tool }
            }
        }
        return nil
    }

    static func canonicalAttributedTool(_ text: String) -> String? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude", "claude code", "claude-code": return "claude-code"
        case "codex", "openai codex": return "codex"
        case "cursor", "cursor agent": return "cursor"
        case "copilot", "github copilot": return "copilot"
        case "windsurf", "windsurf cascade", "cascade": return "windsurf"
        case "aider": return "aider"
        case "opencode", "open code": return "opencode"
        case "qwen code", "qwen-code", "qwencode": return "qwencode"
        case "gemini cli", "gemini-cli": return "gemini-cli"
        case "deepseek harness", "deepseek-harness": return "deepseek-harness"
        default: return nil
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

    /// Guarded by `lock`; set on the persistence queue, read from poll().
    private var lastWatchPersistFailed = false

    private func persistWatchedRepos() {
        statePersistenceQueue.async { [self] in
            // Capture at execution time, not when an older watch/prune request
            // was enqueued. No detached database tasks can overtake this write.
            let current = lock.withLock { watchedRepos }
            UserDefaults.standard.set(Array(current), forKey: Self.watchedReposKey)
            do {
                try AppDatabase.shared.writeSynchronously { db in
                    try GitWatchStore.synchronize(in: db, repositories: current)
                }
                lock.withLock { lastWatchPersistFailed = false }
                AppHealthMonitor.shared.clearIngestError(source: "Git.state.persist")
            } catch {
                lock.withLock { lastWatchPersistFailed = true }
                Logger.error("GitMonitor: persist watched repos failed: \(error)")
                AppHealthMonitor.shared.reportIngestError(error.localizedDescription, source: "Git.state.persist")
            }
        }
    }

}
