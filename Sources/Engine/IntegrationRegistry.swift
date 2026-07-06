import Foundation

/// Compile-time registry of all integrations.
/// Each integration registers itself via `all`.
enum IntegrationRegistry {
    /// All known integrations — add new ones here.
    static nonisolated(unsafe) let all: [any Detectable] = [
        ClaudeCodeIntegration(),
        AiderIntegration(),
        DeepSeekIntegration(),
        OpenAI_Integration(),
        KimiIntegration(),
        ZhipuIntegration(),
        AnthropicIntegration(),
        CursorIntegration(),
        CopilotIntegration(),
        WindsurfIntegration(),
    ]

    /// Integrations that are both detected AND enabled.
    static func enabledIntegrations() -> [any Detectable] {
        all.filter { config(for: $0.id).enabled }
    }

    // MARK: - CostSource aggregation

    /// All active CostSources across all enabled integrations.
    /// This is the single source of truth for the arbitration engine.
    static func activeCostSources(
        editorMappings: [EditorDetector.Mapping] = []
    ) -> [CostSource] {
        var sources: [CostSource] = []

        // Collect from each enabled integration's costSources property
        for integration in all {
            guard config(for: integration.id).enabled else { continue }
            sources.append(contentsOf: integration.costSources)
        }

        // Add editor-detected subscription sources that aren't yet explicitly
        // configured by the user (serves as potential attributions for arbitration)
        let configuredToolIds = Set(
            sources.compactMap { cs -> String? in
                if case .subscription(let toolId, _, _) = cs.kind { return toolId }
                return nil
            }
        )
        for m in editorMappings where m.dailySubscriptionCost > 0 {
            let toolId = toolIdForEditorMapping(m)
            let sourceId = "sub:\(toolId):editor-detected"
            if !configuredToolIds.contains(toolId)
                && !sources.contains(where: { $0.id == sourceId }) {
                let models = PricingManager.shared.modelsForTool(toolId)
                sources.append(CostSource(
                    id: sourceId,
                    label: "\(m.toolName) (detected)",
                    kind: .subscription(
                        toolId: toolId, tierLabel: "detected",
                        monthlyFee: m.dailySubscriptionCost * 30),
                    coveredModels: models,
                    confidence: .uncertain,
                    limitations: ["自动检测到，请在设置中配置订阅方案以精确计算"]
                ))
            }
        }

        return sources
    }

    /// CostSources that are apiKey type and have active balance tracking.
    static func balanceTrackedCostSources() -> [CostSource] {
        activeCostSources().filter { cs in
            if case .apiKey(let pid) = cs.kind,
               ProviderRegistry.byId(pid)?.canFetchBalance == true {
                return true
            }
            return false
        }
    }

    // MARK: - Config persistence

    static func config(for id: String) -> IntegrationConfig {
        let key = "integration_\(id)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let cfg = try? JSONDecoder().decode(IntegrationConfig.self, from: data)
        else { return IntegrationConfig() }
        return cfg
    }

    static func setConfig(for id: String, _ cfg: IntegrationConfig) {
        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: "integration_\(id)")
        }
    }

    /// Start all enabled, detected, Collectable integrations.
    static func startAllEnabled() {
        for i in all {
            guard config(for: i.id).enabled, i.detect().found,
                  let c = i as? Collectable else { continue }
            c.start()
        }
    }

    // MARK: - Temporary backward-compat (will be removed when UI is migrated)

    /// Legacy: returns integrations whose costSources are subscription type.
    /// Used by DashboardView/StatsService — migrate to activeCostSources().
    static func enabledCGradeCompat() -> [any Detectable] {
        all.filter { i in
            config(for: i.id).enabled
            && i.costSources.contains { if case .subscription = $0.kind { return true }; return false }
            && i.detect().found
        }
    }

    /// Legacy: returns apiKey integrations that are enabled.
    static func enabledBGradeCompat() -> [any Detectable & Collectable] {
        all.compactMap { i in
            guard config(for: i.id).enabled,
                  i.costSources.contains(where: { if case .apiKey = $0.kind { return true }; return false }),
                  !i.costSources.contains(where: { if case .subscription = $0.kind { return true }; return false }),
                  let c = i as? (any Detectable & Collectable) else { return nil }
            return c
        }
    }

    /// Legacy: returns log-based integrations that are enabled and detected.
    static func enabledAGradeCompat() -> [any Detectable & Collectable] {
        all.compactMap { i in
            guard config(for: i.id).enabled,
                  i.costSources.isEmpty,
                  i is any Collectable,
                  let c = i as? (any Detectable & Collectable) else { return nil }
            return c
        }
    }

    // MARK: - Helpers

    private static func toolIdForEditorMapping(_ m: EditorDetector.Mapping) -> String {
        switch m.toolName {
        case "Cursor":           return "cursor"
        case "GitHub Copilot":   return "copilot"
        case "Windsurf":         return "windsurf"
        default:                 return m.toolName.lowercased().replacingOccurrences(of: " ", with: "-")
        }
    }

    /// Stop all running Collectable integrations.
    static func stopAll() {
        for i in all {
            guard let c = i as? Collectable else { continue }
            c.stop()
        }
    }
}
