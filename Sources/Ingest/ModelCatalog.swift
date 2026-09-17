import Foundation

struct ModelDescriptor: Codable {
    let provider: String
    let name: String
}

struct ModelCatalog: Codable {
    let version: String
    let updated: String
    let models: [String: ModelDescriptor]
}

final class ModelCatalogManager: @unchecked Sendable {
    static let shared = ModelCatalogManager()
    private var catalog: ModelCatalog?

    private init() {
        load()
    }

    private func load() {
        // Try multiple paths: bundle resource, relative to package root, relative to cwd
        let searchPaths = [
            Bundle.main.path(forResource: "model-catalog", ofType: "json"),
            "Resources/model-catalog.json",      // from package root (swift test)
            "../Resources/model-catalog.json",   // from .build/debug/ (swift run)
            "../../Resources/model-catalog.json", // from .build/release/
        ]
        for path in searchPaths {
            guard let p = path else { continue }
            let url = URL(fileURLWithPath: p)
            guard let data = try? Data(contentsOf: url),
                  let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data)
            else {
                Logger.warning("ModelCatalog: failed to load from \(p)")
                continue
            }
            self.catalog = catalog
            Logger.info("ModelCatalog: loaded \(catalog.models.count) models from \(p)")
            return
        }
        Logger.warning("ModelCatalog: no catalog found, model attribution will be limited")
    }

    func descriptor(for model: String?) -> ModelDescriptor? {
        guard let model, let cat = catalog else { return nil }
        // 1. Exact match
        if let exact = cat.models[model] { return exact }
        // 2. Normalize (drop provider prefix + trailing date/version) and retry
        let normalized = Self.normalize(model)
        if let m = cat.models[normalized] { return m }
        // 3. Longest catalog key that the normalized id starts with / contains.
        //    Real logs append a date stamp (e.g. "claude-sonnet-4-20250514"),
        //    so an exact dictionary lookup never matches the bare catalog key.
        let candidates = cat.models.keys.filter { normalized.hasPrefix($0) || normalized.contains($0) }
        if let best = candidates.max(by: { $0.count < $1.count }) {
            return cat.models[best]
        }
        return nil
    }

    /// Strip provider prefix and trailing date/version suffix from a model id.
    /// e.g. "anthropic/claude-sonnet-4-20250514" -> "claude-sonnet-4"
    static func normalize(_ model: String) -> String {
        var m = model.lowercased()
        if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
        m = m.replacingOccurrences(of: #"-\d{6,8}$"#, with: "", options: .regularExpression)
        m = m.replacingOccurrences(of: #"-v\d+$"#, with: "", options: .regularExpression)
        return m
    }

    func providerId(for model: String?) -> String? {
        if let provider = descriptor(for: model)?.provider {
            return provider
        }

        // Unknown model names remain unpriced; vendor prefixes only identify the provider.
        let normalized = Self.normalize(model ?? "")
        if normalized.hasPrefix("glm-") || normalized == "glm" { return "zhipu" }
        if normalized.hasPrefix("deepseek-") { return "deepseek" }
        if normalized.hasPrefix("qwen") { return "qwen" }
        return nil
    }

    /// All model keys in the catalog belonging to a given provider.
    func modelsForProvider(_ providerId: String) -> Set<String> {
        guard let cat = catalog else { return [] }
        return Set(cat.models.filter { $0.value.provider == providerId }.keys)
    }

    /// Known model families associated with a tool; not evidence of payment.
    func modelsForTool(_ toolId: String) -> Set<String> {
        switch toolId {
        case "claude-code":
            return claudeModels()
        case "codex":
            return modelsForProvider("openai")
        case "cursor":
            return claudeModels().union(modelsForProvider("openai"))
        case "copilot":
            return modelsForProvider("openai")
        case "windsurf":
            return claudeModels()
        default:
            return []
        }
    }

    /// Claude-family model names (provider == "anthropic").
    func claudeModels() -> Set<String> {
        return modelsForProvider("anthropic")
    }
}
