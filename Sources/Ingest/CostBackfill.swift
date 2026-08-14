import Foundation
import GRDB

/// One-time repair for `usage_event.cost_usd` after the cache-token pricing
/// fix. Prior builds treated `cache_tokens` as additive to `in_tokens`, but
/// every parser stores cache as a subset of input, so cached tokens were billed
/// twice. Recomputes every "estimated" event and is guarded by UserDefaults.
enum CostBackfill {
    private static let doneKey = "cost_backfill_cache_subset_v1"

    static func runIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        do {
            let updated = try await AppDatabase.shared.write { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, model, in_tokens, out_tokens, cache_tokens, cost_usd
                    FROM usage_event
                    WHERE cost_confidence = 'estimated' AND model IS NOT NULL
                    """)
                var count = 0
                for row in rows {
                    let id: Int64 = row["id"] ?? 0
                    let model: String? = row["model"]
                    let inTokens: Int = row["in_tokens"] ?? 0
                    let outTokens: Int = row["out_tokens"] ?? 0
                    let cacheTokens: Int = row["cache_tokens"] ?? 0
                    guard let newCost = PricingManager.shared.costUSD(
                        model: model,
                        inTokens: inTokens,
                        outTokens: outTokens,
                        cacheTokens: cacheTokens
                    ) else { continue }

                    let oldCost: Double? = row["cost_usd"]
                    guard oldCost == nil || abs((oldCost ?? 0) - newCost) > 1e-9 else {
                        continue
                    }
                    try db.execute(
                        sql: "UPDATE usage_event SET cost_usd = ? WHERE id = ?",
                        arguments: [newCost, id])
                    count += 1
                }
                return count
            }
            Logger.info("CostBackfill: recomputed \(updated) usage_event rows")
        } catch {
            Logger.error("CostBackfill: \(error)")
        }
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
