import Foundation

/// Gemini CLI (Google) — log-based integration.
/// Data source: `~/.gemini/tmp/<projectHash>/chats/*.jsonl` (format verified
/// against upstream `chatRecordingService`; see `GeminiCLIParser`).
/// Activity does not establish attribution to a configured API account.
struct GeminiCLIIntegration: Detectable {
    let id = "gemini-cli"
    let displayName = "Gemini CLI"
    var costSources: [CostSource] { [] }

    func detect() -> DetectionResult {
        let home = FileManager.default.realHomeDirectory
        let dir = home.appendingPathComponent(".gemini/tmp")
        let exists = FileManager.default.fileExists(atPath: dir.path)
        // Require at least one project hash directory with recorded sessions.
        let hasSessions = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { !$0.hasPrefix(".") }.isEmpty == false
        return DetectionResult(
            found: exists && hasSessions,
            summary: exists && hasSessions
                ? I18n.t("detect.gemini_cli_found")
                : I18n.t("detect.gemini_cli_not_found")
        )
    }
}
