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
        private var reachableRoots: [String]?

        /// Explicit init: the memberwise one would inherit `private` access
        /// from the private stored properties, which newer compilers tolerate
        /// but older ones reject outside this file.
        init(roots: [String]) {
            self.roots = roots
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
                    if reachableRoots == nil { reachableRoots = RepositoryScope.reachableRepositoryRoots(in: roots) }
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
            .map(canonicalPath)
            .filter { !$0.isEmpty }
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

    private static func isCanonicallyInside(_ candidate: String, roots: [String]) -> Bool {
        roots.contains { rawRoot in
            let root = canonicalPath(rawRoot)
            return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// Recomputed for each independent read, so removed/retargeted links stop
    /// authorizing their old targets. Callers handling a batch reuse one lookup.
    static func reachableRepositoryRoots(in roots: [String]) -> [String] {
        var repositories: Set<String> = []
        for root in roots {
            GitRepoScanner.enumerate(in: URL(fileURLWithPath: canonicalPath(root))) {
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
