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
            GitRepoScanner.enumerate(in: URL(fileURLWithPath: expanded)) { url in
                // aider v0.75+: Markdown format
                let chatMD = url.appendingPathComponent(".aider.chat.history.md")
                // aider pre-0.75: JSONL format
                let llmJSONL = url.appendingPathComponent(".aider.llm.history")
                if FileManager.default.fileExists(atPath: chatMD.path) ||
                   FileManager.default.fileExists(atPath: llmJSONL.path) { count += 1 }
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
