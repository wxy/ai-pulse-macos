import Foundation

/// Scans configured directories for git repositories that are not yet
/// watched by GitMonitor, and registers them automatically.
enum RepoDiscovery {

    /// Scan `repo_search_dirs` for new git repos.
    /// - Returns: Number of newly discovered (and registered) repos.
    @discardableResult
    static func scan() -> Int {
        let dirs = UserDefaults.standard.stringArray(forKey: "repo_search_dirs")
            ?? ["~/dev", "~/projects", "~/code"]
        let known = GitMonitor.shared.watchedRepoPaths
        var found = 0

        for dir in dirs {
            let expanded = NSString(string: dir).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { continue }
            found += scanDirectory(URL(fileURLWithPath: expanded), known: known)
        }
        return found
    }

    // MARK: - Private

    /// Directories to skip during recursive scans — prevents accidental access
    /// to system media folders (Music, Pictures, Movies) which trigger
    /// unnecessary permission dialogs on macOS 26.
    private static let skippedDirNames: Set<String> = ["Music", "Pictures", "Movies"]

    private static func scanDirectory(_ dir: URL, known: Set<String>) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            if skippedDirNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let gitDir = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: gitDir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }

            if !known.contains(url.path) {
                GitMonitor.shared.watch(repoPath: url.path)
                Logger.info("RepoDiscovery: new repo → \(url.path)")
                count += 1
            }
            enumerator.skipDescendants()
        }
        return count
    }
}
