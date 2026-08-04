import Foundation

/// Resolves each AI usage event to its most likely CostSource.
///
/// The primary disambiguation key is the model name.
/// Priority when multiple CostSources cover the same model:
///   1. apiKey CostSource (balance delta is the most reliable data)
///   2. subscription CostSource (monthly-fee amortization is an estimate)
///   3. unknown (unattributed)
enum Arbitrator {

    /// Resolve a UsageEvent (from log parsing) to a CostSource.
    /// - Parameters:
    ///   - model: Raw model name from the log entry
    ///   - toolId: The tool that produced this event (e.g. "claude-code")
    ///   - costSources: All active CostSources
    /// - Returns: The resolved (costSourceId, confidence)
    static func resolve(
        model: String?,
        source toolId: String,
        costSources: [CostSource]
    ) -> (costSourceId: String, confidence: CostConfidence) {

        guard let model, !model.isEmpty else {
            return (CostSource.unknownId, .incomplete)
        }

        let normalized = PricingManager.normalize(model)

        // Find all CostSources whose coveredModels match this model
        let matching = costSources.filter { cs in
            cs.coveredModels.contains { covered in
                normalized.hasPrefix(covered)
            }
        }

        if matching.isEmpty {
            return (CostSource.unknownId, .incomplete)
        }

        // apiKey sources take priority (balance deltas are exact)
        let apiKeys = matching.filter { if case .apiKey = $0.kind { return true }; return false }
        let subs = matching.filter { if case .subscription = $0.kind { return true }; return false }

        if let first = apiKeys.first { return (first.id, first.confidence) }
        if let first = subs.first    { return (first.id, first.confidence) }

        return (matching[0].id, .uncertain)
    }
}
