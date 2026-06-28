import Foundation

/// A-grade: aider log parsing.
/// Data source: `<repo>/.aider.llm.history` in watched repos.
struct AiderIntegration: Detectable {
    let id = "aider"
    let displayName = "aider"
    let grade: DataGrade = .A

    func detect() -> DetectionResult {
        // aider is detected if any watched repo has .aider.llm.history
        let dirs = UserDefaults.standard.stringArray(forKey: "repo_search_dirs")
            ?? ["~/dev", "~/projects", "~/code"]
        var count = 0
        for d in dirs {
            let expanded = NSString(string: d).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { continue }
            guard let e = FileManager.default.enumerator(
                at: URL(fileURLWithPath: expanded),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in e {
                let git = url.appendingPathComponent(".git")
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir), isDir.boolValue {
                    let llm = url.appendingPathComponent(".aider.llm.history")
                    if FileManager.default.fileExists(atPath: llm.path) { count += 1 }
                    e.skipDescendants()
                }
            }
        }
        return DetectionResult(
            found: count > 0,
            summary: count > 0 ? "\(count) repos with .aider.llm.history" : "no aider logs found"
        )
    }

    // Collectable is handled by LogWatcher (shared with ClaudeCode)
}
