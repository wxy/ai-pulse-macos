import Foundation
import AIPulseShared

/// Provider is part of model identity; missing attribution remains visible.
/// Unknown models with actual token usage remain visible; zero-only unknown
/// groups add no information to a token matrix and are omitted.
struct ActivityMatrix {
    static let collapsedRowLimit = 5
    struct ModelKey: Hashable {
        let provider: String
        let model: String
    }
    struct Cell: Hashable {
        let model: ModelKey
        let tool: String
    }
    let models: [ModelKey]
    let tools: [String]
    private let values: [Cell: Int64]
    let grandTotal: Int64

    init(_ rows: [ModelActivityItem]) {
        let unknownsWithTokens = Set(rows.filter {
            $0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.tokens > 0
        }.map { ModelKey(provider: $0.providerId, model: $0.model) })
        var values: [Cell: Int64] = [:]
        var modelTotals: [ModelKey: Int64] = [:]
        var toolTotals: [String: Int64] = [:]
        var total: Int64 = 0
        for row in rows {
            let model = ModelKey(provider: row.providerId, model: row.model)
            guard !row.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || unknownsWithTokens.contains(model) else { continue }
            let tool = row.toolId ?? ""
            let tokens = max(0, row.tokens)
            values[Cell(model: model, tool: tool), default: 0] += tokens
            modelTotals[model, default: 0] += tokens
            toolTotals[tool, default: 0] += tokens
            total += tokens
        }
        self.values = values
        models = modelTotals.keys.sorted {
            let a = modelTotals[$0]!, b = modelTotals[$1]!
            if a != b { return a > b }
            if $0.provider != $1.provider { return $0.provider < $1.provider }
            return $0.model < $1.model
        }
        tools = toolTotals.keys.sorted {
            let a = toolTotals[$0]!, b = toolTotals[$1]!
            return a == b ? $0 < $1 : a > b
        }
        grandTotal = total
    }

    func tokens(model: ModelKey, tool: String) -> Int64 {
        values[Cell(model: model, tool: tool)] ?? 0
    }

    func visibleModels(expanded: Bool) -> [ModelKey] {
        expanded ? models : Array(models.prefix(Self.collapsedRowLimit))
    }
    func tokens(model: ModelKey) -> Int64 {
        tools.reduce(0) { $0 + tokens(model: model, tool: $1) }
    }
    func tokens(tool: String) -> Int64 {
        models.reduce(0) { $0 + tokens(model: $1, tool: tool) }
    }
}
