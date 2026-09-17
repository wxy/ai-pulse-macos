import Foundation
import AppKit

/// Codex session-log integration; not a general ChatGPT conversation importer.
/// Data source: `~/.codex/sessions/**/rollout-*.jsonl`
/// Log activity and declared subscription fees are independent observations.
/// A model name does not establish which account or plan paid for a session.
struct CodexIntegration: Detectable {
    let id = "codex"
    let displayName = "Codex"

    var costSources: [CostSource] {
        var sources: [CostSource] = []
        // ChatGPT subscription (if configured) — mirrors Claude Code.
        let cfg = IntegrationRegistry.config(for: id)
        if !cfg.subscriptionTier.isEmpty,
           let tool = SubscriptionRegistry.tool(forName: "ChatGPT"),
           let tier = tool.tiers.first(where: { $0.label == cfg.subscriptionTier }),
           tier.fee > 0 {
            sources.append(CostSource(
                id: "sub:codex:\(tier.label.lowercased())",
                label: "ChatGPT \(tier.label)",
                kind: .subscription(toolId: "codex", tierLabel: tier.label, monthlyFee: tier.fee),
                coveredModels: ModelCatalogManager.shared.modelsForTool("codex"),
                confidence: .declared,
                limitations: []
            ))
        }
        return sources
    }

    func detect() -> DetectionResult {
        let home = FileManager.default.realHomeDirectory
        let sessionsDir = home.appendingPathComponent(".codex/sessions")
        // Require at least one session dir (year/) to count as "found".
        let hasSessions = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path))?
            .contains { Int($0) != nil } ?? false
        let sessionCount = sessionCount(in: sessionsDir)

        // Local Codex state can help detection; it is not a usage ledger.
        let desktopDb = home.appendingPathComponent(".codex/state_5.sqlite")
        let hasDesktopData = FileManager.default.fileExists(atPath: desktopDb.path)
        let appInstalled = Self.codexAppInstalled()

        let found = hasSessions || hasDesktopData
        return DetectionResult(
            found: found,
            summary: found
                ? appInstalled && hasSessions
                    ? String(format: I18n.t("detect.codex_desktop_found"), sessionCount)
                    : I18n.t("detect.codex_found")
                : I18n.t("detect.codex_not_found")
        )
    }

    /// Number of rollout JSONL files, not directories or account conversations.
    private func sessionCount(in sessionsDir: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator
        where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            count += 1
        }
        return count
    }

    /// Detection hint only; usage still comes from rollout files.
    private static func codexAppInstalled() -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") != nil {
            return true
        }
        // Fallback for sandboxed LaunchServices misses: the app bundle path.
        return FileManager.default.fileExists(atPath: "/Applications/Codex.app")
    }
}
