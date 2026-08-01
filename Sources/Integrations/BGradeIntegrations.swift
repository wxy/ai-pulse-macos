import Foundation

// MARK: - Parameterized apiKey integration

/// A provider that exposes an API key for balance/usage polling.
/// All five apiKey-only integrations (DeepSeek, OpenAI, Kimi, Zhipu,
/// Anthropic) are instances of this single struct — they differ only in
/// identity, model catalog, and limitations.
struct ApiKeyIntegration: Detectable, Collectable {
    let id: String
    let displayName: String

    /// Provider registry id used for balance polling / model lookup.
    /// For apiKey-only integrations this equals `id`.
    let providerId: String

    /// Whether to use the Claude model catalog instead of provider-specific.
    let usesClaudeModels: Bool

    /// I18n key for the limitation note shown on this integration's cost source.
    let limitationKey: String

    let confidence: CostConfidence

    var costSources: [CostSource] {
        guard ApiKeyManager.shared.get(id) != nil else { return [] }
        let models = usesClaudeModels
            ? PricingManager.shared.claudeModels()
            : PricingManager.shared.modelsForProvider(providerId)
        return [CostSource(
            id: "api-key:\(id)",
            label: "\(displayName) API",
            kind: .apiKey(providerId: providerId),
            coveredModels: models,
            confidence: confidence,
            limitations: [I18n.t(limitationKey)]
        )]
    }

    func detect() -> DetectionResult {
        let hasKey = ApiKeyManager.shared.get(id) != nil
        return DetectionResult(found: hasKey, summary: I18n.t(hasKey ? "detect.key_configured" : "detect.key_missing"))
    }

    func start() {}
    func stop()  {}
}
