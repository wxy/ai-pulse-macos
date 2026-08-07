import Foundation

/// Full dashboard snapshot — computed by macOS and synced via iCloud.
/// iOS/watchOS read this structure to render their dashboards.
struct DashboardSnapshot: Codable {
    var version: Int = 1

    var todayCost: Double = 0
    var weekCost: Double = 0
    var monthCost: Double = 0
    var yesterdaySpend: Double = 0
    var previousPeriodSpend: Double = 0
    var subDaily: Double = 0
    var todayCalls: Int64 = 0
    var todayTokens: Int64 = 0

    var providerBreakdown: [ProviderItem] = []
    var toolBreakdown: [NameCostItem] = []
    var topRepos: [RepoItem] = []
    var prediction: PredictionItem?

    var dailyStats: [TrendPoint] = []
    var codeChanges: [TrendPoint] = []
    var balanceDaily: [TrendPoint] = []
    var remainingBalances: [RemainingBalanceItem] = []
    var quotaStatus: [QuotaStatusItem] = []

    // Sync metadata written by macOS:
    // `payloadVersion` = JSON payload format version; `writerAppVersion` = the
    // macOS app version that produced this snapshot. Optional so legacy
    // records (pre-versioning) still decode structurally.
    var payloadVersion: String?
    var writerAppVersion: String?

    var updatedAt: Date = Date()
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
    var ts: Double
    var value: Double
    var calls: Int64
    var tokens: Int64
    var netLines: Int
    var added: Int = 0
    var deleted: Int = 0
}

struct RemainingBalanceItem: Codable {
    var providerId: String
    var displayName: String
    var balance: Double
    var currency: String
}

/// Subscription quota state (Claude / Copilot window utilization + reset).
/// Mirrors the macOS model so iCloud-synced snapshots decode identically.
struct QuotaStatusItem: Codable {
    var toolId: String
    var utilization: Double
    var limitStatus: String
    var resetAt: Double
    var windowSeconds: Double
}
