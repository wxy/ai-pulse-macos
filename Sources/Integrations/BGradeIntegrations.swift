import Foundation

// MARK: - DeepSeek (B)

struct DeepSeekIntegration: Detectable, Collectable {
    let id = "deepseek"
    let displayName = "DeepSeek"
    let grade: DataGrade = .B

    func detect() -> DetectionResult {
        let hasKey = ApiPoller.shared.cachedBalance(for: id) != nil
            || ApiKeyManager.shared.get(id) != nil
        return DetectionResult(found: hasKey, summary: hasKey ? "API key configured" : "no API key")
    }

    func start() {}  // ApiPoller handles all B-grade
    func stop()  {}
}

// MARK: - OpenAI (B)

struct OpenAI_Integration: Detectable, Collectable {
    let id = "openai"
    let displayName = "OpenAI"
    let grade: DataGrade = .B

    func detect() -> DetectionResult {
        let hasKey = ApiKeyManager.shared.get(id) != nil
        return DetectionResult(found: hasKey, summary: hasKey ? "API key configured" : "no API key")
    }

    func start() {}
    func stop()  {}
}

// MARK: - Kimi / Moonshot (B)

struct KimiIntegration: Detectable, Collectable {
    let id = "moonshot"
    let displayName = "Kimi"
    let grade: DataGrade = .B

    func detect() -> DetectionResult {
        let hasKey = ApiKeyManager.shared.get(id) != nil
        return DetectionResult(found: hasKey, summary: hasKey ? "API key configured" : "no API key")
    }

    func start() {}
    func stop()  {}
}

// MARK: - Zhipu / ChatGLM (B)

struct ZhipuIntegration: Detectable, Collectable {
    let id = "zhipu"
    let displayName = "ChatGLM"
    let grade: DataGrade = .B

    func detect() -> DetectionResult {
        let hasKey = ApiKeyManager.shared.get(id) != nil
        return DetectionResult(found: hasKey, summary: hasKey ? "API key configured" : "no API key")
    }

    func start() {}
    func stop()  {}
}
