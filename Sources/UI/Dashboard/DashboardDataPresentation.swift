import Foundation
import AIPulseShared

/// Totals cover the full eligible list, independently of visible folded rows.
struct RepositoryTableTotals {
    let added: Int64
    let deleted: Int64
    let commits: Int64
    let tokens: Int64?

    init(repositories: [RepoItem]) {
        func sum(_ values: [Int64]) -> Int64 {
            values.reduce(0) { total, value in
                let result = total.addingReportingOverflow(max(0, value))
                return result.overflow ? Int64.max : result.partialValue
            }
        }
        added = sum(repositories.map { Int64($0.added) })
        deleted = sum(repositories.map { Int64($0.deleted) })
        commits = sum(repositories.map { Int64($0.commits) })
        tokens = repositories.allSatisfy { $0.tokens != nil }
            ? sum(repositories.compactMap(\.tokens)) : nil
    }
}

/// View-only decoration. nil slots are context placeholders, not zero activity.
enum DashboardDataPresentation {
    static func rhythmSlots(values: [Double], count: Int, surroundingWeeks: Bool) -> [Double?] {
        let count = max(0, count)
        let activity: [Double?] = (0..<count).map { index in
            guard index < values.count else { return 0 }
            let value = values[index]
            return value.isFinite ? max(0, value) : 0
        }
        guard surroundingWeeks else { return activity }
        return Array(repeating: nil, count: 7) + activity + Array(repeating: nil, count: 7)
    }

    /// Reserve visible nose categories, then distribute the remaining width by data.
    static func noseFractions(values: [Double]) -> [Double] {
        let values = values.map { $0.isFinite ? max(0, $0) : 0 }
        guard !values.isEmpty else { return [] }
        let total = values.reduce(0, +)
        guard total > 0 else { return Array(repeating: 1 / Double(values.count), count: values.count) }
        let floor = min(0.15, 1 / Double(values.count))
        let remainder = 1 - floor * Double(values.count)
        return values.map { floor + remainder * $0 / total }
    }

    /// Linear scale, without a minimum visible width or logarithmic exaggeration.
    static func barFraction(value: Double?, maximum: Double) -> Double? {
        guard let value, value.isFinite, value >= 0, maximum.isFinite, maximum > 0 else { return nil }
        return min(1, value / maximum)
    }
}
