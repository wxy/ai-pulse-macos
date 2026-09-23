import Foundation
import GRDB

/// Net decreases between two samples, not itemized invoices or exact spend.
enum BalanceObservation {
    struct Delta: Sendable {
        let providerId: String
        let startMs: Int64
        let ts: Int64
        let nativeAmount: Double
        let currency: String
    }

    static func fetchBalanceDeltas(in db: Database, sinceMs: Int64,
                                  beforeMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) throws -> [Delta] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, provider_id, ts, balance, currency FROM balance_snapshot
            WHERE ts >= ? AND ts <= ?
            UNION ALL
            SELECT b.id, b.provider_id, b.ts, b.balance, b.currency
            FROM (SELECT DISTINCT provider_id FROM balance_snapshot) providers
            JOIN balance_snapshot b ON b.id = (
              SELECT p.id FROM balance_snapshot p
              WHERE p.provider_id = providers.provider_id AND p.ts < ?
              ORDER BY p.ts DESC, p.id DESC LIMIT 1
            )
            ORDER BY provider_id, ts, id
            """, arguments: [sinceMs, beforeMs, sinceMs])
        var previous: (provider: String, ts: Int64, balance: Double, currency: String)?
        var deltas: [Delta] = []
        for row in rows {
            guard let provider: String = row["provider_id"], !provider.isEmpty,
                  let ts: Int64 = row["ts"], let balance: Double = row["balance"], balance.isFinite,
                  let rawCurrency: String = row["currency"], !rawCurrency.isEmpty else {
                previous = nil
                continue
            }
            let currency = rawCurrency.uppercased()
            if let previous, previous.provider == provider, previous.currency == currency,
               ts > previous.ts, ts >= sinceMs, ts <= beforeMs, balance < previous.balance {
                let amount = previous.balance - balance
                if amount.isFinite {
                    deltas.append(Delta(providerId: provider, startMs: previous.ts, ts: ts,
                                        nativeAmount: amount, currency: currency))
                }
            }
            previous = (provider, ts, balance, currency)
        }
        return deltas
    }
}
