import Foundation

/// The single repository-attribution boundary used by ingestion, monitoring,
/// and dashboard queries. A working directory is only attributable when it
/// resolves to a real Git root inside one of the user-selected development
/// directories.
enum RepositoryScope {
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
        return roots.contains { rawRoot in
            let root = canonicalPath(rawRoot)
            return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
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
