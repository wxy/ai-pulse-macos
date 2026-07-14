import Foundation

// MARK: - DeepSeek (apiKey)

struct DeepSeekIntegration: Detectable, Collectable {
    let id = "deepseek"
    let displayName = "DeepSeek"

    var costSources: [CostSource] {
        guard ApiKeyManager.shared.get(id) != nil else { return [] }
        return [CostSource(
            id: "api-key:deepseek",
            label: "DeepSeek API",
            kind: .apiKey(providerId: "deepseek"),
            coveredModels: PricingManager.shared.modelsForProvider("deepseek"),
            confidence: .exact,
            limitations: [I18n.t("limitation.assume_programming")]
        )]
    }

    func detect() -> DetectionResult {
        let hasKey = ApiKeyManager.shared.get(id) != nil
        return DetectionResult(found: hasKey, summary: I18n.t(hasKey ? "detect.key_configured" : "detect.key_missing"))
    }

    func start() {}
    func stop()  {}
}

// MARK: - OpenAI (apiKey)

struct OpenAI_Integration: Detectable, Collectable {
    let id = "openai"
    let displayName = "OpenAI"

    var costSources: [CostSource] {
        guard ApiKeyManager.shared.get(id) != nil else { return [] }
        return [CostSource(
            id: "api-key:openai",
            label: "OpenAI API",
            kind: .apiKey(providerId: "openai"),
            coveredModels: PricingManager.shared.modelsForProvider("openai"),
            confidence: .exact,
            limitations: [I18n.t("limitation.assume_programming")]
        )]
    }

    func detect() -> DetectionResult {
        let hasKey = ApiKeyManager.shared.get(id) != nil
        return DetectionResult(found: hasKey, summary: I18n.t(hasKey ? "detect.key_configured" : "detect.key_missing"))
    }

    func start() {}
    func stop()  {}
}

// MARK: - Kimi / Moonshot (apiKey)

struct KimiIntegration: Detectable, Collectable {
    let id = "moonshot"
    let displayName = "Kimi"

    var costSources: [CostSource] {
        guard ApiKeyManager.shared.get(id) != nil else { return [] }
        return [CostSource(
            id: "api-key:moonshot",
            label: "Kimi API",
            kind: .apiKey(providerId: "moonshot"),
            coveredModels: PricingManager.shared.modelsForProvider("moonshot"),
            confidence: .exact,
            limitations: [I18n.t("limitation.assume_programming")]
        )]
    }

    func detect() -> DetectionResult {
        let hasKey = ApiKeyManager.shared.get(id) != nil
        return DetectionResult(found: hasKey, summary: I18n.t(hasKey ? "detect.key_configured" : "detect.key_missing"))
    }

    func start() {}
    func stop()  {}
}

// MARK: - Zhipu / ChatGLM (apiKey)

struct ZhipuIntegration: Detectable, Collectable {
    let id = "zhipu"
    let displayName = "ChatGLM"

    var costSources: [CostSource] {
        guard ApiKeyManager.shared.get(id) != nil else { return [] }
        return [CostSource(
            id: "api-key:zhipu",
            label: "ChatGLM API",
            kind: .apiKey(providerId: "zhipu"),
            coveredModels: PricingManager.shared.modelsForProvider("zhipu"),
            confidence: .exact,
            limitations: [I18n.t("limitation.assume_programming")]
        )]
    }

    func detect() -> DetectionResult {
        let hasKey = ApiKeyManager.shared.get(id) != nil
        return DetectionResult(found: hasKey, summary: I18n.t(hasKey ? "detect.key_configured" : "detect.key_missing"))
    }

    func start() {}
    func stop()  {}
}

// MARK: - Anthropic (apiKey, no balance API)

struct AnthropicIntegration: Detectable, Collectable {
    let id = "anthropic"
    let displayName = "Anthropic"

    var costSources: [CostSource] {
        guard ApiKeyManager.shared.get(id) != nil else { return [] }
        return [CostSource(
            id: "api-key:anthropic",
            label: "Anthropic API",
            kind: .apiKey(providerId: "anthropic"),
            coveredModels: PricingManager.shared.claudeModels(),
            confidence: .estimated,
            limitations: [I18n.t("limitation.no_balance_api")]
        )]
    }

    func detect() -> DetectionResult {
        let hasKey = ApiKeyManager.shared.get(id) != nil
        return DetectionResult(found: hasKey, summary: I18n.t(hasKey ? "detect.key_configured" : "detect.key_missing"))
    }

    func start() {}
    func stop()  {}
}
