import Foundation

struct ModelPricing: Codable {
    let provider: String
    let name: String
    let inPricePerMtok: Double
    let outPricePerMtok: Double
    let cachePricePerMtok: Double
    let currency: String

    enum CodingKeys: String, CodingKey {
        case provider, name, currency
        case inPricePerMtok = "in_price_per_mtok"
        case outPricePerMtok = "out_price_per_mtok"
        case cachePricePerMtok = "cache_price_per_mtok"
    }
}

struct PricingCatalog: Codable {
    let version: String
    let updated: String
    let models: [String: ModelPricing]
}

final class PricingManager {
    static let shared = PricingManager()
    private var catalog: PricingCatalog?

    private init() {
        load()
    }

    private func load() {
        // Try multiple paths: bundle resource, relative to package root, relative to cwd
        let searchPaths = [
            Bundle.main.path(forResource: "pricing-catalog", ofType: "json"),
            "../shared/pricing-catalog.json",    // from mac-app/ (swift run cwd)
            "../../shared/pricing-catalog.json", // from .build/debug/ (actual binary)
            "./shared/pricing-catalog.json",
        ]
        for path in searchPaths {
            guard let p = path else { continue }
            let url = URL(fileURLWithPath: p)
            guard let data = try? Data(contentsOf: url),
                  let catalog = try? JSONDecoder().decode(PricingCatalog.self, from: data)
            else {
                print("PricingCatalog: failed to load from \(p)")
                continue
            }
            self.catalog = catalog
            print("PricingCatalog: loaded \(catalog.models.count) models from \(p)")
            return
        }
        print("PricingCatalog: WARNING — no catalog found, cost data will be missing")
    }

    func pricing(for model: String?) -> ModelPricing? {
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
        return pricing(for: model)?.provider
    }

    func costUSD(model: String?, inTokens: Int, outTokens: Int, cacheTokens: Int) -> Double? {
        guard let p = pricing(for: model) else { return nil }
        let inCost = Double(inTokens) / 1_000_000 * p.inPricePerMtok
        let outCost = Double(outTokens) / 1_000_000 * p.outPricePerMtok
        let cacheCost = Double(cacheTokens) / 1_000_000 * p.cachePricePerMtok
        return inCost + outCost + cacheCost
    }
}
