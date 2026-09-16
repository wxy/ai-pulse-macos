import Foundation

/// Canonical token semantics for every parser and aggregate.
///
/// All supported parsers store cached input as a subset of input. Therefore
/// observed total activity is input + output; adding cache again double-counts
/// the cached portion. Cache remains available as an input breakdown.
enum TokenAccounting {
    static let observedTotalSQL = """
        (CASE WHEN in_tokens > 0 THEN in_tokens ELSE 0 END
         + CASE WHEN out_tokens > 0 THEN out_tokens ELSE 0 END)
        """

    static func observedTotal(input: Int, output: Int) -> Int {
        let safeInput = Int64(max(input, 0))
        let safeOutput = Int64(max(output, 0))
        let total = safeInput.addingReportingOverflow(safeOutput)
        return total.overflow ? Int.max : Int(clamping: total.partialValue)
    }

    static func breakdown(input: Int, output: Int, cachedInput: Int)
        -> (nonCachedInput: Int, cachedInput: Int, output: Int, total: Int) {
        let safeInput = max(input, 0)
        let safeOutput = max(output, 0)
        let safeCache = min(max(cachedInput, 0), safeInput)
        return (
            nonCachedInput: safeInput - safeCache,
            cachedInput: safeCache,
            output: safeOutput,
            total: observedTotal(input: safeInput, output: safeOutput)
        )
    }
}
