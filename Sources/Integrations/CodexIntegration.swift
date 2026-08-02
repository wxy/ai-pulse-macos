import Foundation

/// OpenAI Codex CLI — log-based integration.
/// Data source: `~/.codex/sessions/**/rollout-*.jsonl`
/// Not a CostSource itself — log entries are attributed to the existing
/// `openai` apiKey CostSource via the Arbitrator.
struct CodexIntegration: Detectable {
    let id = "codex"
    let displayName = "Codex CLI"
    var costSources: [CostSource] { [] }

    func detect() -> DetectionResult {
        let home = FileManager.default.realHomeDirectory
        let dir = home.appendingPathComponent(".codex/sessions")
        let exists = FileManager.default.fileExists(atPath: dir.path)
        // Require at least one session dir (year/) to count as "found".
        let hasSessions = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .contains { Int($0) != nil } ?? false
        return DetectionResult(
            found: exists && hasSessions,
            summary: exists && hasSessions
                ? I18n.t("detect.codex_found")
                : I18n.t("detect.codex_not_found")
        )
    }
}
