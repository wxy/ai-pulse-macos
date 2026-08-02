import Foundation

/// OpenCode CLI (anomaly.co) — log-based integration.
/// Data source: `~/.local/share/opencode/storage/message/**/msg_*.json`.
/// Not a CostSource itself — log entries are attributed to the configured
/// apiKey CostSource (openai / deepseek / etc.) via the Arbitrator.
struct OpenCodeIntegration: Detectable {
    let id = "opencode"
    let displayName = "OpenCode"
    var costSources: [CostSource] { [] }

    func detect() -> DetectionResult {
        let home = FileManager.default.realHomeDirectory
        let dir = home.appendingPathComponent(".local/share/opencode/storage/message")
        let exists = FileManager.default.fileExists(atPath: dir.path)
        let hasMessages = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .contains { !$0.hasPrefix(".") } ?? false
        return DetectionResult(
            found: exists && hasMessages,
            summary: exists && hasMessages
                ? I18n.t("detect.opencode_found")
                : I18n.t("detect.opencode_not_found")
        )
    }
}
