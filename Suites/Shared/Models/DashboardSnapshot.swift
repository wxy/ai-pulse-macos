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

    // Tool detail: per-tool conclusion summary + session list. Optional/empty
    // when produced by an older macOS app; old iOS clients ignore this field.
    var toolDetails: [ToolDetailItem] = []

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

struct ToolDetailItem: Codable {
    var source: String
    var conclusion: ToolConclusionItem
    var sessions: [ToolSessionItem]
}

struct ToolConclusionItem: Codable {
    var spend: Double = 0
    var previousSpend: Double = 0
    var deltaPct: Double = 0
    var projectedMonth: Double = 0
    var sessionCount: Int = 0
    var commitCount: Int = 0
    var addedLines: Int = 0
    var deletedLines: Int = 0
    var avgCostPerSession: Double = 0
    var cpl: Double = 0
    var crossToolDeltaPct: Double? = nil
}

struct ToolSessionItem: Codable {
    var sessionId: String?
    var title: String?
    var repo: String?
    var firstTs: Int64
    var lastTs: Int64
    var cost: Double
    var windowTokens: Int?
    var lastInput: Int
    var turnCount: Int
    var avgOccupancy: Double?
    var avgCacheRatio: Double?
    var compactionCount: Int
}

extension ToolDetailItem: Identifiable {
    var id: String { source }
}
