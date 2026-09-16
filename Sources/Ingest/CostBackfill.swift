import Foundation
import GRDB

/// One-time repairs for `usage_event.cost_usd`, each guarded by UserDefaults:
///
/// 1. `repairCacheSubsetPricing` — prior builds treated `cache_tokens` as
///    additive to `in_tokens`, but every parser stores cache as a subset of
///    input, so cached tokens were billed twice. Recomputes "estimated" events.
/// 2. `backfillMissingCosts` — events whose model had NO catalog price at
///    insert time carry NULL cost and are invisible to every money surface.
///    When the catalog gains a price, recompute those rows (v2: Codex family
///    variants gpt-5.6-sol / gpt-6-astra / gpt-5.3-codex-spark /
///    codex-auto-review recorded 2.3k events / 500M+ tokens with NULL cost).
enum CostBackfill {
    private static let doneKey = "cost_backfill_cache_subset_v1"
    private static let missingCostDoneKey = "cost_backfill_missing_costs_v1"

    static func runIfNeeded() async {
        await repairCacheSubsetPricing()
        await backfillMissingCosts()
    }

    private static func backfillMissingCosts() async {
        guard !UserDefaults.standard.bool(forKey: missingCostDoneKey) else { return }
        do {
            let updated = try await AppDatabase.shared.write { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, model, in_tokens, out_tokens, cache_tokens
                    FROM usage_event
                    WHERE cost_usd IS NULL AND model IS NOT NULL
                    """)
                var count = 0
                for row in rows {
                    let id: Int64 = row["id"] ?? 0
                    let model: String? = row["model"]
                    guard let newCost = PricingManager.shared.costUSD(
                        model: model,
                        inTokens: row["in_tokens"] ?? 0,
                        outTokens: row["out_tokens"] ?? 0,
                        cacheTokens: row["cache_tokens"] ?? 0
                    ), newCost > 0 else { continue }
                    try db.execute(
                        sql: "UPDATE usage_event SET cost_usd = ? WHERE id = ?",
                        arguments: [newCost, id])
                    count += 1
                }
                return count
            }
            Logger.info("CostBackfill: backfilled \(updated) NULL-cost rows after catalog update")
        } catch {
            Logger.error("CostBackfill missing-costs: \(error)")
            return // leave the key unset so the next launch retries
        }
        UserDefaults.standard.set(true, forKey: missingCostDoneKey)
    }

    private static func repairCacheSubsetPricing() async {
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
