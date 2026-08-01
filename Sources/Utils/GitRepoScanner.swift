import Foundation

/// Shared recursive git-repository enumeration.
/// Replaces three near-identical walkers that used to live in
/// RepoDiscovery, LogWatcher, and AiderIntegration.
enum GitRepoScanner {
    /// Directories to skip during recursive scans — prevents accidental access
    /// to system media folders (Music, Pictures, Movies) which trigger
    /// permission dialogs, plus Library (system data) and Trash.
    static let skippedDirNames: Set<String> = [
        "Music", "Pictures", "Movies", "Library", ".Trash",
    ]

    /// Enumerate all git repositories under `dir` recursively, calling
    /// `handler` for each. Skips descendant traversal once a repo is found
    /// (shallow-first: nested repos are not reported separately).
    static func enumerate(in dir: URL, _ handler: (URL) -> Void) {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        for case let url as URL in enumerator {
            if skippedDirNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let gitDir = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: gitDir.path,
                                                 isDirectory: &isDir),
                  isDir.boolValue
            else { continue }
            handler(url)
            enumerator.skipDescendants()
        }
    }
}
