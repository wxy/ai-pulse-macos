import Foundation
import GRDB

/// Cached dashboard snapshot — computed in load() and persisted to GRDB.
/// Each time range (today/week/30d) gets its own row.
/// Uses raw SQL to avoid GRDB protocol conformance actor-isolation issues.
struct DashboardCache {
    var timeRange: String
    var json: String
    var updatedAt: Date

    static func write(timeRange: String, json: String) async {
        do {
            try await AppDatabase.shared.write { db in
                try db.execute(sql: """
                    INSERT OR REPLACE INTO dashboard_cache (time_range, json, updated_at)
                    VALUES (?, ?, ?)
                    """, arguments: [timeRange, json, Date()])
            }
        } catch {
            Logger.warning("Dashboard: cache write failed — \(error.localizedDescription)")
        }
    }

    static func read(timeRange: String, maxAge: TimeInterval = 30) async -> DashboardSnapshot? {
        do {
            let row = try await AppDatabase.shared.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT json, updated_at FROM dashboard_cache WHERE time_range = ?
                    """, arguments: [timeRange])
            }
            guard let row,
                  let updatedAt: Date = row["updated_at"],
                  -updatedAt.timeIntervalSinceNow < maxAge,
                  let json: String = row["json"],
                  let data = json.data(using: .utf8),
                  let snap = try? JSONDecoder().decode(DashboardSnapshot.self, from: data)
            else { return nil }
            return snap
        } catch {
            return nil
        }
    }
}

/// The full snapshot stored as JSON in dashboard_cache and synced to iCloud.
/// All platforms (macOS, iOS, watchOS) use this single data structure.
struct DashboardSnapshot: Codable {
    var version: Int = 1

    // Totals
    var todayCost: Double = 0
    var weekCost: Double = 0
    var monthCost: Double = 0
    var yesterdaySpend: Double = 0
    var previousPeriodSpend: Double = 0

    // Subscription
    var subDaily: Double = 0

    // Stats
    var todayCalls: Int64 = 0
    var todayTokens: Int64 = 0

    // Charts & Breakdowns
    var providerBreakdown: [ProviderItem] = []
    var toolBreakdown: [NameCostItem] = []
    var topRepos: [RepoItem] = []
    var prediction: PredictionItem?

    // Trend data (arrays for charts)
    var dailyStats: [TrendPoint] = []
    var codeChanges: [TrendPoint] = []
    var balanceDaily: [TrendPoint] = []  // API-only spend per day
    var remainingBalances: [RemainingBalanceItem] = []
    var quotaStatus: [QuotaStatusItem] = []  // subscription quota (Claude/Copilot)

    // Tool detail: per-tool conclusion summary + session list, added in 1.2.5
    // as a backward-compatible increment (old clients ignore this field).
    var toolDetails: [ToolDetailItem] = []

    // Sync metadata (written by macOS, read by iOS/watchOS):
    // `payloadVersion` is the JSON payload format version (bumped only when the
    // structure changes); `writerAppVersion` is the macOS app version that
    // produced this snapshot.
    var payloadVersion: String?
    var writerAppVersion: String?

    var updatedAt: Date = Date()

    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

struct ProviderItem: Codable {
    var providerId: String
    var name: String
    var cost: Double
}

struct NameCostItem: Codable {
    var name: String
    var cost: Double
}

struct RepoItem: Codable {
    var name: String
    var cost: Double
    var added: Int
    var deleted: Int
    var cpl: Double
}

struct PredictionItem: Codable {
    var monthProjected: Double
    var dailyRate: Double
    var daysRemaining: Int
    var monthSoFar: Double
}

struct TrendPoint: Codable {
    var ts: Double    // Date.timeIntervalSince1970 — avoids timezone issues
    var value: Double
    var calls: Int
    var tokens: Int
    var netLines: Int
    var added: Int = 0
    var deleted: Int = 0
}

struct ToolDetailItem: Codable {
    var source: String
    var conclusion: ToolConclusionItem
    var sessions: [ToolSessionItem]
}

struct ToolConclusionItem: Codable {
    var spend: Double
    var previousSpend: Double
    var deltaPct: Double
    var projectedMonth: Double
    var sessionCount: Int
    var commitCount: Int
    var addedLines: Int
    var deletedLines: Int
    var avgCostPerSession: Double
    var cpl: Double
    var crossToolDeltaPct: Double?
}

struct ToolSessionItem: Codable {
    var sessionId: String?
    var title: String?
    var repo: String?
    var firstTs: Int
    var lastTs: Int
    var cost: Double
    var windowTokens: Int?
    var lastInput: Int
    var turnCount: Int
    var avgOccupancy: Double?
    var avgCacheRatio: Double?
    var compactionCount: Int
}

struct RemainingBalanceItem: Codable {
    var providerId: String
    var displayName: String
    var balance: Double
    var currency: String
}

/// Subscription quota state (Claude / Copilot window utilization + reset).
struct QuotaStatusItem: Codable {
    var toolId: String        // "claude-code" / "copilot"
    var utilization: Double   // 0-100
    var limitStatus: String
    var resetAt: Double       // Unix timestamp of next reset (0 if unknown)
    var windowSeconds: Double // quota window length (for last-reset math)
}
