import Foundation

/// Claude Code — subscription + log parsing.
/// Data source: `~/.claude/projects/<encoded-cwd>/*.jsonl`
struct ClaudeCodeIntegration: Detectable, Collectable {
    let id = "claude-code"
    let displayName = "Claude Code"

    var costSources: [CostSource] {
        var sources: [CostSource] = []
        // Claude Pro subscription (if configured)
        let cfg = IntegrationRegistry.config(for: id)
        if !cfg.subscriptionTier.isEmpty,
           let tool = SubscriptionRegistry.tool(forName: "Claude Code"),
           let tier = tool.tiers.first(where: { $0.label == cfg.subscriptionTier }),
           tier.fee > 0 {
            let days = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
            sources.append(CostSource(
                id: "sub:claude-code:\(tier.label.lowercased())",
                label: "Claude \(tier.label)",
                kind: .subscription(toolId: "claude-code", tierLabel: tier.label, monthlyFee: tier.fee),
                coveredModels: PricingManager.shared.claudeModels(),
                confidence: .amortized,
                limitations: []
            ))
        }
        return sources
    }

    func detect() -> DetectionResult {
        let dir = FileManager.default.realHomeDirectory
            .appendingPathComponent(".claude/projects")
        let exists = FileManager.default.fileExists(atPath: dir.path)
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count ?? 0
        return DetectionResult(
            found: exists && sessions > 0,
            summary: exists
                ? String(format: I18n.t("detect.claude_found"), sessions)
                : I18n.t("detect.claude_not_found")
        )
    }

    func start() { LogWatcher.shared.start() }
    func stop()  { LogWatcher.shared.stop() }
}
