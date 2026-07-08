import Foundation
import GRDB

// MARK: - CostSource（计费来源）

/// 一个 CostSource 回答 "谁在付钱"。
/// 一条 UsageRecord 最终只归属到一个 CostSource，防止重复计数。
struct CostSource: Identifiable, Equatable, Hashable, Codable {
    let id: String                     // "api-key:deepseek", "sub:cursor:pro"
    let label: String                  // "DeepSeek API Key"
    let kind: CostSourceKind
    let coveredModels: Set<String>     // normalized model names this source covers
    let confidence: CostConfidence     // default confidence for this source
    let limitations: [String]          // ["超量费用暂不支持", "假设仅用于编程"]

    static let unknownId = "unattributed"
}

// MARK: - CostSourceKind

enum CostSourceKind: Equatable, Hashable, Codable {
    case apiKey(providerId: String)
    case subscription(toolId: String, tierLabel: String, monthlyFee: Double)
    case unknown
}

// MARK: - CostConfidence（可信度）

enum CostConfidence: String, Codable, Comparable {
    case exact       // 余额差值 — 精确实数
    case estimated   // token × 定价表 — 估算
    case amortized   // 订阅月费摊销
    case uncertain   // 归属有歧义，最佳猜测
    case incomplete  // 已知缺失（如 Copilot overage）

    static func < (lhs: CostConfidence, rhs: CostConfidence) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ c: CostConfidence) -> Int {
        switch c {
        case .exact:       return 0
        case .estimated:   return 1
        case .amortized:   return 2
        case .uncertain:   return 3
        case .incomplete:  return 4
        }
    }
}

// MARK: - Database sync

extension CostSource {
    /// Persist active cost sources to the `cost_source` table for SQL queries.
    static func syncToDatabase(_ sources: [CostSource]) {
        // Pre-compute row data outside the db.write closure to avoid
        // an ownership/lifetime compiler crash on enum destructuring
        // (switch_enum on CostSourceKind.associated-value) in optimized builds.
        let rows: [(id: String, label: String, kind: String, confidence: String, monthlyFee: Double?)] =
            sources.map { s in
                let fee: Double? = {
                    if case .subscription(_, _, let fee) = s.kind { return fee }
                    return nil
                }()
                return (s.id, s.label, kindString(s.kind), s.confidence.rawValue, fee)
            }
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(sql: "DELETE FROM cost_source")
                    for row in rows {
                        try db.execute(sql: """
                            INSERT INTO cost_source (id, label, kind, confidence, monthly_fee)
                            VALUES (?, ?, ?, ?, ?)
                            """, arguments: [
                                row.id, row.label, row.kind, row.confidence, row.monthlyFee,
                            ])
                    }
                }
            } catch {
                Logger.error("CostSource.syncToDatabase failed: \(error)")
            }
        }
    }

    private static func kindString(_ kind: CostSourceKind) -> String {
        switch kind {
        case .apiKey:        return "apiKey"
        case .subscription:  return "subscription"
        case .unknown:       return "unknown"
        }
    }
}
