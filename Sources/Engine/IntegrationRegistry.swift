import Foundation

/// Compile-time registry of all integrations.
/// Each integration registers itself via `allIntegrations`.
enum IntegrationRegistry {
    /// All known integrations — add new ones here.
    static nonisolated(unsafe) let all: [any Detectable] = [
        ClaudeCodeIntegration(),
        AiderIntegration(),
        DeepSeekIntegration(),
        OpenAI_Integration(),
        KimiIntegration(),
        ZhipuIntegration(),
        CursorIntegration(),
        CopilotIntegration(),
        WindsurfIntegration(),
    ]

    /// Integrations that are both detected AND enabled.
    static func enabledIntegrations() -> [any Detectable] {
        all.filter { config(for: $0.id).enabled }
    }

    /// A-grade integrations that are detected AND enabled.
    static func enabledAGrade() -> [any Detectable & Collectable] {
        all.compactMap { i in
            guard i.grade == .A, config(for: i.id).enabled,
                  let c = i as? (any Detectable & Collectable) else { return nil }
            return c
        }
    }

    /// B-grade integrations that are detected AND enabled.
    static func enabledBGrade() -> [any Detectable & Collectable] {
        all.compactMap { i in
            guard i.grade == .B, config(for: i.id).enabled,
                  let c = i as? (any Detectable & Collectable) else { return nil }
            return c
        }
    }

    /// C-grade integrations that are detected AND enabled.
    static func enabledCGrade() -> [any Detectable] {
        all.filter { i in i.grade == .C && config(for: i.id).enabled && i.detect().found }
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

    /// Stop all running Collectable integrations.
    static func stopAll() {
        for i in all {
            guard let c = i as? Collectable else { continue }
            c.stop()
        }
    }
}
