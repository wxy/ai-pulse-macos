import Foundation

/// DeepSeek Harness — log-based integration.
/// Data source: `~/.dsh/sessions/**/session.jsonl.zstd`.
/// Journals contain concatenated zstd frames and are attributed to the
/// configured DeepSeek apiKey CostSource via model/provider arbitration.
struct DeepSeekHarnessIntegration: Detectable {
    let id = "deepseek-harness"
    let displayName = "DeepSeek Harness"
    var costSources: [CostSource] { [] }

    func detect() -> DetectionResult {
        let home = FileManager.default.realHomeDirectory
        let sessionsDir = home.appendingPathComponent(".dsh/sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return DetectionResult(
                found: false,
                summary: I18n.t("detect.dsh_not_found")
            )
        }

        let count = journalCount(in: sessionsDir)
        return DetectionResult(
            found: count > 0,
            summary: count > 0
                ? String(format: I18n.t("detect.dsh_found"), count)
                : I18n.t("detect.dsh_not_found")
        )
    }

    private func journalCount(in sessionsDir: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator
        where url.lastPathComponent == "session.jsonl.zstd" {
            count += 1
        }
        return count
    }
}
