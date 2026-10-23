import Foundation

/// The single repository-attribution boundary used by ingestion, monitoring,
/// and dashboard queries. A working directory is only attributable when it
/// resolves to a real Git root inside one of the user-selected development
/// directories.
enum RepositoryScope {
    /// Reuse Git-root verification only while building one result. A new read
    /// creates a new lookup, so changed authorization, paths, and worktrees
    /// are checked again rather than being trusted from an earlier snapshot.
    struct AuthorizedRootLookup {
        let roots: [String]
        private var resolved: [String: String] = [:]
        private var unavailable: Set<String> = []
        private var reachableRoots: Set<String>?
        /// Optional generation-shared answer for linked repositories. Called
        /// at most once per lookup, and only when a path actually resolves
        /// outside the configured roots — the common all-inside case never
        /// walks (2026-10-23 review F02).
        private let sharedReachableRoots: (() -> Set<String>)?
        /// Read-scoped diagnostics: repeated rows must not multiply tree walks.
        private(set) var linkedRootScanCount = 0

        /// Explicit init: the memberwise one would inherit `private` access
        /// from the private stored properties, which newer compilers tolerate
        /// but older ones reject outside this file.
        init(roots: [String], sharedReachableRoots: (() -> Set<String>)? = nil) {
            self.roots = roots
            self.sharedReachableRoots = sharedReachableRoots
        }

        mutating func root(
            for path: String,
            resolvingWith resolve: ((String, [String]) -> String?)? = nil
        ) -> String? {
            guard !path.isEmpty else { return nil }
            if let root = resolved[path] { return root }
            if unavailable.contains(path) { return nil }

            let root: String?
            if let resolve {
                root = resolve(path, roots)
            } else if let repo = RepositoryScope.gitRoot(containing: path) {
                if RepositoryScope.isCanonicallyInside(repo, roots: roots) {
                    root = repo
                } else {
                    if reachableRoots == nil {
                        linkedRootScanCount += 1
                        reachableRoots = sharedReachableRoots.map { $0() }
                            ?? Set(RepositoryScope.reachableRepositoryRoots(in: roots))
                    }
                    root = reachableRoots?.contains(repo) == true ? repo : nil
                }
            } else {
                root = nil
            }
            if let root {
                resolved[path] = root
            } else {
                unavailable.insert(path)
            }
            return root
        }
    }

    static func configuredRoots(defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey: "repo_search_dirs") ?? [])
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL.path }
    }

    static func canonicalPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func isInsideConfiguredRoots(_ path: String, roots: [String]) -> Bool {
        let candidate = canonicalPath(path)
        if isCanonicallyInside(candidate, roots: roots) { return true }
        return reachableRepositoryRoots(in: roots).contains { repo in
            candidate == repo || candidate.hasPrefix(repo + "/")
        }
    }

    static func isCanonicallyInside(_ candidate: String, roots: [String]) -> Bool {
        roots.contains { rawRoot in
            let root = canonicalPath(rawRoot)
            return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// One authorization generation for linked repositories (2026-10-23
    /// review F02). A repository reached through a link inside a configured
    /// development root authorizes only via a full tree walk with no
    /// deadline; per-repository, per-batch, and per-poll readers share one
    /// walk for the whole generation lifetime instead. The next generation
    /// re-walks, so a retargeted or removed link stops authorizing its old
    /// target — the revocation semantics of the uncached read are kept, only
    /// delayed to the following independent read.
    private static let generationLock = NSLock()
    private static nonisolated(unsafe) var generation: (
        roots: [String], reachable: Set<String>, expiresAt: Date
    )?

    /// Lifetime of one generation. Half a phase-1 tick: a burst (history
    /// backfill, a poll round, a prune) costs one walk, and revocation lands
    /// on the next tick after the change.
    static let reachableRootsGenerationLifetime: TimeInterval = 15

    static func generationReachableRoots(in roots: [String]) -> Set<String> {
        let now = Date()
        generationLock.lock()
        if let cached = generation, cached.roots == roots, now < cached.expiresAt {
            generationLock.unlock()
            return cached.reachable
        }
        generationLock.unlock()
        // Walk outside the lock: concurrent first readers may both walk, but
        // neither blocks the other, and the tree walk has no internal lock.
        let reachable = Set(reachableRepositoryRoots(in: roots))
        generationLock.lock()
        generation = (roots, reachable, now.addingTimeInterval(reachableRootsGenerationLifetime))
        generationLock.unlock()
        return reachable
    }

    /// Recomputed for each independent read, so removed/retargeted links stop
    /// authorizing their old targets. Callers handling a batch reuse one lookup.
    static func reachableRepositoryRoots(in roots: [String]) -> [String] {
        var repositories: Set<String> = []
        for root in roots {
            GitRepoScanner.enumerate(in: URL(fileURLWithPath: root)) {
                repositories.insert(canonicalPath($0.path))
            }
        }
        return Array(repositories)
    }

    static func gitRoot(containing path: String, fileManager: FileManager = .default) -> String? {
        var url = URL(fileURLWithPath: canonicalPath(path))
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue {
            url.deleteLastPathComponent()
        }
        while url.path != "/" {
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return GitRepo.verifiedWorkingRoot(at: url.path)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func authorizedGitRoot(for path: String?, roots: [String]? = nil) -> String? {
        guard let path, !path.isEmpty,
              let repo = gitRoot(containing: path)
        else { return nil }
        let allowed = roots ?? configuredRoots()
        guard isInsideConfiguredRoots(repo, roots: allowed) else { return nil }
        return repo
    }
}
