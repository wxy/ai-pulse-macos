import Foundation
import StoreKit

/// Compile-time registry of all integrations.
/// Each integration registers itself via `all`.
enum IntegrationRegistry {
    /// All known integrations — add new ones here.
    static nonisolated(unsafe) let all: [any Detectable] = [
        ClaudeCodeIntegration(),
        AiderIntegration(),
        CodexIntegration(),
        QwenCodeIntegration(),
        OpenCodeIntegration(),
        DeepSeekHarnessIntegration(),
        ApiKeyIntegration(
            id: "deepseek", displayName: "DeepSeek", providerId: "deepseek",
            usesClaudeModels: false, limitationKey: "limitation.assume_programming",
            confidence: .exact
        ),
        ApiKeyIntegration(
            id: "openai", displayName: "OpenAI", providerId: "openai",
            usesClaudeModels: false, limitationKey: "limitation.assume_programming",
            confidence: .exact
        ),
        ApiKeyIntegration(
            id: "moonshot", displayName: "Kimi", providerId: "moonshot",
            usesClaudeModels: false, limitationKey: "limitation.assume_programming",
            confidence: .exact
        ),
        ApiKeyIntegration(
            id: "zhipu", displayName: "ChatGLM", providerId: "zhipu",
            usesClaudeModels: false, limitationKey: "limitation.assume_programming",
            confidence: .exact
        ),
        // Anthropic has no balance API — cost estimated from token pricing.
        ApiKeyIntegration(
            id: "anthropic", displayName: "Anthropic", providerId: "anthropic",
            usesClaudeModels: true, limitationKey: "limitation.no_balance_api",
            confidence: .estimated
        ),
        CursorIntegration(),
        CopilotIntegration(),
        WindsurfIntegration(),
    ]

    /// Integrations visible in Settings. Filters out OpenAI/Anthropic in mainland
    /// China to comply with regional restrictions.
    static var visible: [any Detectable] {
        all.filter { !isRestrictedInChina($0.id) }
    }

    // MARK: - Region gating

    /// App Store storefront country code (ISO 3166-1 alpha-3, e.g. "CHN"),
    /// cached after the first read. `nonisolated(unsafe)` matches the registry's
    /// existing concurrency pattern; a stale value is harmless (worst case the
    /// gating applies one launch late).
    private static nonisolated(unsafe) var storefrontCountryCode: String?

    /// Cache the App Store storefront region once at launch.
    /// Per docs/superpowers/specs/2026-07-17-region-based-feature-gating.md,
    /// prefer `Storefront.current` over `Locale.current` — the storefront is the
    /// user's App Store region, not the system language/region.
    static func refreshStorefrontRegion() async {
        storefrontCountryCode = await Storefront.current?.countryCode
    }

    /// Provider IDs restricted in mainland China (regulatory compliance).
    /// Includes OpenAI-family tools: Codex CLI is OpenAI's coding agent.
    private static let chinaRestrictedIds: Set<String> = ["openai", "anthropic", "codex"]

    private static func isRestrictedInChina(_ integrationId: String) -> Bool {
        guard chinaRestrictedIds.contains(integrationId) else { return false }
        #if DEBUG
        // Dev/test builds mirror production gating based on the selected
        // language: Simplified Chinese hides China-restricted providers. This
        // keeps the full feature set visible in other languages during
        // development and lets us capture screenshots of both states.
        return I18n.resolvedLang() == "zh-Hans"
        #else
        // Gate only when the App Store storefront itself is mainland China.
        // No fallback to the system locale: without a storefront (non-App Store
        // builds, storefront unavailable) nothing is hidden.
        return storefrontCountryCode == "CHN"   // Storefront uses ISO 3166-1 alpha-3
        #endif
    }

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
            let integId = editorMappingToIntegrationId(m)
            guard config(for: integId).enabled else { continue }
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
                    limitations: [I18n.t("limitation.auto_detected")]
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

    // MARK: - Helpers

    private static func editorMappingToIntegrationId(_ m: EditorDetector.Mapping) -> String {
        switch m.toolName {
        case "Cursor":           return "cursor"
        case "GitHub Copilot":   return "copilot"
        case "Windsurf":         return "windsurf"
        default:                 return m.toolName.lowercased().replacingOccurrences(of: " ", with: "-")
        }
    }

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

    /// Centralized tool display name for the given integration ID.
    /// Used by Dashboard, MenuBar, Settings — single source of truth.
    static func toolDisplayName(for integrationId: String) -> String {
        switch integrationId {
        case "claude-code": return "Claude Code"
        case "deepseek-harness": return "DeepSeek Harness"
        case "aider":       return "aider"
        case "codex":       return "ChatGPT"
        case "qwen-code":   return "Qwen Code"
        case "opencode":    return "OpenCode"
        case "cursor":      return "Cursor"
        case "copilot":     return "GitHub Copilot"
        case "windsurf":    return "Windsurf"
        default:            return integrationId
        }
    }
}
