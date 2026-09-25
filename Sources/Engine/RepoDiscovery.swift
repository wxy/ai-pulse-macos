import Foundation

/// Scans configured directories for git repositories that are not yet
/// watched by GitMonitor, and registers them automatically.
enum RepoDiscovery {

    /// Scan `repo_search_dirs` for new git repos.
    /// - Returns: Number of newly discovered (and registered) repos.
    @discardableResult
    static func scan() -> Int {
        let dirs = RepositoryScope.configuredRoots()
        GitMonitor.shared.pruneWatchedRepos(outside: dirs)
        let known = GitMonitor.shared.watchedRepoPaths
        var found = 0

        for dir in dirs {
            guard FileManager.default.fileExists(atPath: dir) else { continue }
            found += scanDirectory(URL(fileURLWithPath: dir), known: known)
        }
        return found
    }

    // MARK: - Private

    private static func scanDirectory(_ dir: URL, known: Set<String>) -> Int {
        var count = 0
        GitRepoScanner.enumerate(in: dir) { url in
            // `known` holds canonical paths (GitMonitor.watch canonicalizes
            // before inserting); comparing raw paths let already-watched
            // repos re-register and inflate the discovery count.
            let canonical = RepositoryScope.canonicalPath(url.path)
            if !known.contains(canonical) {
                GitMonitor.shared.watch(repoPath: url.path)
                Logger.info("RepoDiscovery: new repo → \(url.path)")
                count += 1
            }
        }
        return count
    }
}
