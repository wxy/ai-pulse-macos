import Foundation

/// aider log parsing.
/// Data source: `<repo>/.aider.llm.history` in watched repos.
/// Not a CostSource itself — log entries are attributed to apiKey CostSources.
struct AiderIntegration: Detectable {
    let id = "aider"
    let displayName = "aider"
    var costSources: [CostSource] { [] }

    func detect() -> DetectionResult {
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
            summary: count > 0
                ? String(format: I18n.t("detect.aider_found"), count)
                : I18n.t("detect.aider_not_found")
        )
    }
}
