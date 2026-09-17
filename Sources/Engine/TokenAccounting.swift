import Foundation

/// Canonical token semantics for every parser and aggregate.
///
/// Claude/DSH/OpenCode store uncached input, cache reads and writes separately.
/// Codex/Qwen report input including cached input. Preserve raw fields and
/// normalize at the accounting boundary, never by rewriting historical input.
enum TokenAccounting {
    static var observedTotalSQL: String { observedTotalSQL(alias: nil) }

    static func inputSQL(alias: String? = nil) -> String {
        let prefix = alias.map { $0 + "." } ?? ""
        func positive(_ column: String) -> String {
            "MAX(COALESCE(\(prefix)\(column), 0), 0)"
        }
        return "(\(positive("in_tokens")) + CASE WHEN \(prefix)source IN ('claude-code', 'deepseek-harness', 'opencode') THEN \(positive("cache_tokens")) + \(positive("cache_creation_tokens")) ELSE 0 END)"
    }

    static func observedTotalSQL(alias: String?) -> String {
        return "(\(inputSQL(alias: alias)) + \(outputSQL(alias: alias)))"
    }

    static func outputSQL(alias: String? = nil) -> String {
        let prefix = alias.map { $0 + "." } ?? ""
        return "(MAX(COALESCE(\(prefix)reported_output_tokens, CASE WHEN \(prefix)source IN ('deepseek-harness', 'codex') THEN 0 ELSE \(prefix)out_tokens END, 0), 0) + CASE WHEN \(prefix)source = 'opencode' THEN MAX(COALESCE(\(prefix)reasoning_tokens, 0), 0) ELSE 0 END)"
    }

    static var missingComponentsSQL: String {
        """
        ((source IN ('claude-code', 'deepseek-harness', 'opencode') AND cache_creation_tokens IS NULL)
          OR (source IN ('deepseek-harness', 'codex') AND reported_output_tokens IS NULL)
          OR (source = 'opencode' AND reasoning_tokens IS NULL))
        """
    }

    static func observedTotal(event: UsageEvent) -> Int {
        let input = observedInput(source: event.source, input: event.inTokens,
                                  cacheRead: event.cacheTokens, cacheCreation: event.cacheCreationTokens)
        // Old DSH output was a derived output+reasoning sum. Without the
        // original counter it is unknown, not a trustworthy observed output.
        var output = max(event.reportedOutputTokens ?? (["deepseek-harness", "codex"].contains(event.source) ? 0 : event.outTokens), 0)
        if event.source == "opencode" {
            output = observedTotal(input: output, output: event.reasoningTokens ?? 0)
        }
        return observedTotal(input: input, output: output)
    }

    static func observedInput(source: String, input: Int, cacheRead: Int, cacheCreation: Int?) -> Int {
        guard ["claude-code", "deepseek-harness", "opencode"].contains(source) else { return max(input, 0) }
        return [input, cacheRead, cacheCreation ?? 0].reduce(0) { total, value in
            let sum = total.addingReportingOverflow(max(value, 0))
            return sum.overflow ? Int.max : sum.partialValue
        }
    }

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
