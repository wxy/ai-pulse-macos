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
    var todayCalls: Int = 0
    var todayTokens: Int = 0

    var providerBreakdown: [ProviderItem] = []
    var toolBreakdown: [NameCostItem] = []
    var topRepos: [RepoItem] = []
    var prediction: PredictionItem?

    var dailyStats: [TrendPoint] = []
    var codeChanges: [TrendPoint] = []
    var balanceDaily: [TrendPoint] = []

    var updatedAt: Date = Date()
}

struct ProviderItem: Codable {
    var providerId: String
    var name: String
    var cost: Double
    var added: Int
    var deleted: Int
}

struct NameCostItem: Codable {
    var name: String
    var cost: Double
    var added: Int
    var deleted: Int
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
    var ts: Double    // Date.timeIntervalSince1970
    var value: Double
    var calls: Int
    var tokens: Int
    var netLines: Int
}
