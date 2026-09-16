import Foundation
import GRDB

/// Shared hourly-consumption aggregation and baseline math.
///
/// Single source of truth for "how spending behaves per hour" — consumed by
/// `AnomalyDetector` (legacy spend alerts) and compatibility burn calculations
/// so the two can never drift into different baselines (设计文档 WI-1 决策 5).
///
/// The `<synthetic>` exclusion matches the repo-wide convention (F6): synthetic
/// rows (subscription amortization etc.) never count as consumption — fixed
/// cost does not burn.
enum HourlyBaseline {

    struct HourlySpend {
        let hour: Int64      // epoch-hour index: ts / 3600000 (AnomalyDetector convention)
        let cost: Double
        let tokens: Int64    // input + output; cache is already a subset of input
    }

    /// SQL shared by both entry points. Kept verbatim from the original
    /// AnomalyDetector query so its regression behavior is byte-identical.
    private static let sql = """
        SELECT (ts / 3600000) AS hr,
               COALESCE(SUM(cost_usd), 0) AS c,
               COALESCE(SUM(\(TokenAccounting.observedTotalSQL)), 0) AS t
        FROM usage_event
        WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')
        GROUP BY hr ORDER BY hr DESC
        """

    /// Fetch per-hour sums from the live app database, newest hour first.
    static func fetchHourly(sinceMs: Int64) async throws -> [HourlySpend] {
        try await AppDatabase.shared.read { db in
            try fetchHourly(in: db, sinceMs: sinceMs)
        }
    }

    /// Synchronous variant for injected databases (in-memory tests).
    static func fetchHourly(in db: Database, sinceMs: Int64) throws -> [HourlySpend] {
        try Row.fetchAll(db, sql: sql, arguments: [sinceMs]).map { row in
            HourlySpend(hour: row["hr"] as Int64? ?? 0,
                        cost: row["c"] as Double? ?? 0,
                        tokens: row["t"] as Int64? ?? 0)
        }
    }

    /// Mean hourly cost over all hours EXCEPT the most recent (partial) one.
    /// Returns 0 when there are fewer than `minSamples` hourly buckets —
    /// identical to the original AnomalyDetector formula
    /// `(total - latest) / (count - 1)`.
    static func baselineExcludingLatest(_ hours: [HourlySpend], minSamples: Int = 2) -> Double {
        guard hours.count >= minSamples else { return 0 }
        let rest = hours.dropFirst()
        let total = rest.reduce(0.0) { $0 + $1.cost }
        return total / Double(rest.count)
    }
}
