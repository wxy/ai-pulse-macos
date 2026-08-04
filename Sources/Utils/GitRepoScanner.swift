import Foundation

enum GitRepoScanner {
    /// System/installer directories skipped during recursive scans — prevents
    /// accidental access to media folders (permission dialogs) and system data.
    static let skippedDirNames: Set<String> = [
        "Music", "Pictures", "Movies", "Library", ".Trash",
    ]

    /// Heavy dependency/build directories never contain repos we want to track.
    /// Descending into them is what made scans slow (node_modules = tens of
    /// thousands of files). Skipped wholesale.
    static let heavyDirNames: Set<String> = [
        "node_modules", "Pods", "DerivedData", ".venv", "venv", "__pycache__",
        "build", "dist", ".next", "target", ".gradle", "Carthage", ".build",
        "Packages", "vendor", ".cache",
    ]

    /// Don't descend deeper than this. Repos are conventionally at depth 1-3
    /// (e.g. ~/dev, ~/dev/work). Bounding the walk keeps huge trees fast.
    static let maxDepth = 4

    /// Enumerate git repositories under `dir`, calling `handler` for each.
    /// Skips descendant traversal inside system/heavy dirs and once a repo is
    /// found (shallow-first: nested repos are not reported separately).
    /// Honors `deadline` (soft scan budget): when exceeded, stops early and
    /// returns `true` (truncated result). `FileManager.enumerator` yields
    /// immediate children at level 1, so `maxDepth` bounds repos to 4 levels.
    @discardableResult
    static func enumerate(in dir: URL, deadline: Date? = nil,
                          _ handler: (URL) -> Void) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }

        var truncated = false
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skippedDirNames.contains(name) || heavyDirNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if enumerator.level >= maxDepth {
                enumerator.skipDescendants()
            }
            let gitDir = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: gitDir.path,
                                                 isDirectory: &isDir),
                  isDir.boolValue else { continue }
            if let deadline, Date() >= deadline {
                truncated = true
                break
            }
            handler(url)
            enumerator.skipDescendants()
        }
        return truncated
    }
}
