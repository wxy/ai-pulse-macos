import Foundation

/// Qwen Code CLI (Alibaba) — log-based integration.
/// Data source: `~/.qwen/projects/**/chats/*.jsonl` (Gemini CLI format fork).
/// Activity does not establish attribution to a configured API account.
struct QwenCodeIntegration: Detectable {
    let id = "qwen-code"
    let displayName = "Qwen Code"
    var costSources: [CostSource] { [] }

    func detect() -> DetectionResult {
        let home = FileManager.default.realHomeDirectory
        let dir = home.appendingPathComponent(".qwen/projects")
        let exists = FileManager.default.fileExists(atPath: dir.path)
        // Require at least one project subdirectory.
        let hasProjects = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { !$0.hasPrefix(".") }.isEmpty == false
        return DetectionResult(
            found: exists && hasProjects,
            summary: exists && hasProjects
                ? I18n.t("detect.qwen_code_found")
                : I18n.t("detect.qwen_code_not_found")
        )
    }
}
