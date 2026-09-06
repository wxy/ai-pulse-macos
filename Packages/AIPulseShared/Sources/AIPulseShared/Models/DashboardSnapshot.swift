import Foundation

/// Full dashboard snapshot — computed by macOS and synced via iCloud.
/// iOS/watchOS read this structure to render their dashboards.
public struct DashboardSnapshot: Codable, Sendable {
    public var version: Int = 2

    public var todayCost: Double = 0
    public var weekCost: Double = 0
    public var monthCost: Double = 0
    public var yesterdaySpend: Double = 0
    public var previousPeriodSpend: Double = 0
    public var subDaily: Double = 0
    public var todayCalls: Int64 = 0
    public var todayTokens: Int64 = 0

    public var providerBreakdown: [ProviderItem] = []
    public var toolBreakdown: [NameCostItem] = []
    public var topRepos: [RepoItem] = []
    public var prediction: PredictionItem?

    public var dailyStats: [TrendPoint] = []
    public var codeChanges: [TrendPoint] = []
    public var balanceDaily: [TrendPoint] = []
    public var remainingBalances: [RemainingBalanceItem] = []
    public var quotaStatus: [QuotaStatusItem] = []
    /// Per-model usage/cost attribution (BYOK mixes live here). Optional so
    /// older macOS writers can produce snapshots without this block.
    public var modelBreakdown: [ModelCostItem] = []
    /// Effective-price series for tools/models with attributable balance
    /// sources (exclusive provider ownership). Empty when nothing is
    /// attributable — clients show an explanatory placeholder instead.
    public var rateSeries: [RateSeriesItem] = []
    /// User-entered subscription cycle anchor. nil until configured.
    public var subscriptionStart: Date?
    /// Subscription cycle length in days (30/90/365). nil until configured.
    public var subscriptionPeriodDays: Int?

    /// Per-tool conclusion summary + session list. Optional/empty when
    /// produced by an older macOS app; old clients ignore this field.
    public var toolDetails: [ToolDetailItem] = []

    /// Sync metadata written by macOS:
    /// `payloadVersion` = JSON payload format version; `writerAppVersion` = the
    /// macOS app version that produced this snapshot. Optional so legacy
    /// records (pre-versioning) still decode structurally.
    public var payloadVersion: String?
    public var writerAppVersion: String?

    public var updatedAt: Date = Date()

    public init(
        version: Int = 2,
        todayCost: Double = 0,
        weekCost: Double = 0,
        monthCost: Double = 0,
        yesterdaySpend: Double = 0,
        previousPeriodSpend: Double = 0,
        subDaily: Double = 0,
        todayCalls: Int64 = 0,
        todayTokens: Int64 = 0,
        providerBreakdown: [ProviderItem] = [],
        toolBreakdown: [NameCostItem] = [],
        topRepos: [RepoItem] = [],
        prediction: PredictionItem? = nil,
        dailyStats: [TrendPoint] = [],
        codeChanges: [TrendPoint] = [],
        balanceDaily: [TrendPoint] = [],
        remainingBalances: [RemainingBalanceItem] = [],
        quotaStatus: [QuotaStatusItem] = [],
        modelBreakdown: [ModelCostItem] = [],
        rateSeries: [RateSeriesItem] = [],
        subscriptionStart: Date? = nil,
        subscriptionPeriodDays: Int? = nil,
        toolDetails: [ToolDetailItem] = [],
        payloadVersion: String? = nil,
        writerAppVersion: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.todayCost = todayCost
        self.weekCost = weekCost
        self.monthCost = monthCost
        self.yesterdaySpend = yesterdaySpend
        self.previousPeriodSpend = previousPeriodSpend
        self.subDaily = subDaily
        self.todayCalls = todayCalls
        self.todayTokens = todayTokens
        self.providerBreakdown = providerBreakdown
        self.toolBreakdown = toolBreakdown
        self.topRepos = topRepos
        self.prediction = prediction
        self.dailyStats = dailyStats
        self.codeChanges = codeChanges
        self.balanceDaily = balanceDaily
        self.remainingBalances = remainingBalances
        self.quotaStatus = quotaStatus
        self.modelBreakdown = modelBreakdown
        self.rateSeries = rateSeries
        self.subscriptionStart = subscriptionStart
        self.subscriptionPeriodDays = subscriptionPeriodDays
        self.toolDetails = toolDetails
        self.payloadVersion = payloadVersion
        self.writerAppVersion = writerAppVersion
        self.updatedAt = updatedAt
    }

    public func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Coerces every numeric field into a finite, non-negative value.
    ///
    /// Charts and SwiftUI layout can trap on NaN/Inf (and macOS Charts can
    /// recurse on degenerate zero-angle geometry), and negative spend/counts
    /// render as inverted bars. Call this at every trust boundary: after
    /// decoding from CloudKit/cache, before persisting a snapshot, and before
    /// feeding values into SwiftUI state. Delta percentages keep their sign;
    /// only non-finite values become zero.
    public func sanitized() -> DashboardSnapshot {
        var clean = self
        clean.todayCost = Self.safeNonNegative(todayCost)
        clean.weekCost = Self.safeNonNegative(weekCost)
        clean.monthCost = Self.safeNonNegative(monthCost)
        clean.yesterdaySpend = Self.safeNonNegative(yesterdaySpend)
        clean.previousPeriodSpend = Self.safeNonNegative(previousPeriodSpend)
        clean.subDaily = Self.safeNonNegative(subDaily)
        clean.todayCalls = Self.safeNonNegative(todayCalls)
        clean.todayTokens = Self.safeNonNegative(todayTokens)

        clean.providerBreakdown = providerBreakdown.map {
            ProviderItem(
                providerId: $0.providerId,
                name: $0.name,
                cost: Self.safeNonNegative($0.cost),
                sourceKind: $0.sourceKind)
        }
        clean.toolBreakdown = toolBreakdown.map {
            NameCostItem(
                name: $0.name,
                cost: Self.safeNonNegative($0.cost),
                tokens: $0.tokens.map(Self.safeNonNegative),
                calls: $0.calls.map(Self.safeNonNegative))
        }
        clean.topRepos = topRepos.map {
            RepoItem(
                name: $0.name,
                cost: Self.safeNonNegative($0.cost),
                added: Self.safeNonNegative($0.added),
                deleted: Self.safeNonNegative($0.deleted),
                cpl: Self.safeNonNegative($0.cpl),
                tokens: $0.tokens.map(Self.safeNonNegative))
        }
        clean.prediction = prediction.map {
            PredictionItem(
                monthProjected: Self.safeNonNegative($0.monthProjected),
                dailyRate: Self.safeNonNegative($0.dailyRate),
                daysRemaining: Self.safeNonNegative($0.daysRemaining),
                monthSoFar: Self.safeNonNegative($0.monthSoFar))
        }
        clean.dailyStats = dailyStats.map(Self.sanitizedTrendPoint)
        clean.codeChanges = codeChanges.map(Self.sanitizedTrendPoint)
        clean.balanceDaily = balanceDaily.map(Self.sanitizedTrendPoint)
        clean.remainingBalances = remainingBalances.map {
            RemainingBalanceItem(
                providerId: $0.providerId,
                displayName: $0.displayName,
                balance: Self.safeNonNegative($0.balance),
                currency: $0.currency)
        }
        clean.quotaStatus = quotaStatus.map {
            QuotaStatusItem(
                toolId: $0.toolId,
                utilization: Self.safeNonNegative($0.utilization),
                limitStatus: $0.limitStatus,
                resetAt: Self.safeNonNegative($0.resetAt),
                windowSeconds: Self.safeNonNegative($0.windowSeconds))
        }
        clean.modelBreakdown = modelBreakdown.map {
            ModelCostItem(
                model: $0.model,
                providerId: $0.providerId,
                toolId: $0.toolId,
                tokens: Self.safeNonNegative($0.tokens),
                calls: Self.safeNonNegative($0.calls),
                cost: $0.cost.map { $0.isFinite && $0 >= 0 ? $0 : 0 },
                costIsEstimate: $0.costIsEstimate)
        }
        clean.rateSeries = rateSeries.map { series in
            RateSeriesItem(
                toolId: series.toolId,
                label: series.label,
                points: series.points.map {
                    RatePoint(
                        ts: $0.ts.isFinite ? $0.ts : 0,
                        tokens: Self.safeNonNegative($0.tokens),
                        cost: Self.safeNonNegative($0.cost))
                })
        }
        clean.subscriptionPeriodDays = subscriptionPeriodDays.flatMap {
            $0 > 0 ? $0 : 30
        }
        clean.toolDetails = toolDetails.map { detail in
            let c = detail.conclusion
            let cleanConclusion = ToolConclusionItem(
                spend: Self.safeNonNegative(c.spend),
                previousSpend: Self.safeNonNegative(c.previousSpend),
                deltaPct: c.deltaPct.isFinite ? c.deltaPct : 0,
                projectedMonth: Self.safeNonNegative(c.projectedMonth),
                sessionCount: Self.safeNonNegative(c.sessionCount),
                commitCount: Self.safeNonNegative(c.commitCount),
                addedLines: Self.safeNonNegative(c.addedLines),
                deletedLines: Self.safeNonNegative(c.deletedLines),
                avgCostPerSession: Self.safeNonNegative(c.avgCostPerSession),
                cpl: Self.safeNonNegative(c.cpl),
                crossToolDeltaPct: c.crossToolDeltaPct.map { $0.isFinite ? $0 : 0 })
            let cleanSessions = detail.sessions.map { s in
                ToolSessionItem(
                    sessionId: s.sessionId,
                    title: s.title,
                    repo: s.repo,
                    firstTs: Self.safeNonNegative(s.firstTs),
                    lastTs: Self.safeNonNegative(s.lastTs),
                    cost: Self.safeNonNegative(s.cost),
                    windowTokens: s.windowTokens.map(Self.safeNonNegative),
                    lastInput: Self.safeNonNegative(s.lastInput),
                    turnCount: Self.safeNonNegative(s.turnCount),
                    avgOccupancy: s.avgOccupancy.map { $0.isFinite ? $0 : 0 },
                    avgCacheRatio: s.avgCacheRatio.map { $0.isFinite ? $0 : 0 },
                    compactionCount: Self.safeNonNegative(s.compactionCount))
            }
            return ToolDetailItem(source: detail.source, conclusion: cleanConclusion, sessions: cleanSessions)
        }
        return clean
    }

    private static func sanitizedTrendPoint(_ p: TrendPoint) -> TrendPoint {
        TrendPoint(
            ts: p.ts.isFinite ? p.ts : 0,
            value: Self.safeNonNegative(p.value),
            calls: Self.safeNonNegative(p.calls),
            tokens: Self.safeNonNegative(p.tokens),
            netLines: Self.safeNonNegative(p.netLines),
            added: Self.safeNonNegative(p.added),
            deleted: Self.safeNonNegative(p.deleted))
    }

    private static func safeNonNegative(_ v: Double) -> Double {
        v.isFinite && v >= 0 ? v : 0
    }

    private static func safeNonNegative(_ v: Int64) -> Int64 {
        v >= 0 ? v : 0
    }

    private static func safeNonNegative(_ v: Int) -> Int {
        v >= 0 ? v : 0
    }
}

public struct ProviderItem: Codable, Sendable {
    public var providerId: String
    public var name: String
    public var cost: Double
    /// `balance` (balance-API delta), `usage` (usage-type, no spend amount),
    /// or `estimated` (token-price estimate). nil for legacy snapshots.
    public var sourceKind: String?

    public init(providerId: String, name: String, cost: Double, sourceKind: String? = nil) {
        self.providerId = providerId
        self.name = name
        self.cost = cost
        self.sourceKind = sourceKind
    }
}

public struct NameCostItem: Codable, Sendable {
    public var name: String
    public var cost: Double
    /// Token usage attributed to this tool (JSONL fact). nil for legacy.
    public var tokens: Int64?
    /// Call count attributed to this tool (JSONL fact). nil for legacy.
    public var calls: Int?

    public init(name: String, cost: Double, tokens: Int64? = nil, calls: Int? = nil) {
        self.name = name
        self.cost = cost
        self.tokens = tokens
        self.calls = calls
    }
}

public struct RepoItem: Codable, Sendable {
    public var name: String
    public var cost: Double
    public var added: Int
    public var deleted: Int
    public var cpl: Double
    /// Token usage attributed to this repo (JSONL fact). nil for legacy.
    public var tokens: Int64?

    public init(name: String, cost: Double, added: Int, deleted: Int, cpl: Double, tokens: Int64? = nil) {
        self.name = name
        self.cost = cost
        self.added = added
        self.deleted = deleted
        self.cpl = cpl
        self.tokens = tokens
    }
}

/// Per-model usage/cost attribution, primarily for BYOK mixes where a tool
/// runs third-party models (e.g. Claude Code on a DeepSeek key).
public struct ModelCostItem: Codable, Sendable {
    public var model: String
    public var providerId: String
    /// Tool that produced this model's events (BYOK mixes live here).
    public var toolId: String?
    public var tokens: Int64
    public var calls: Int
    /// Spend attributable to this model; nil when the balance source is
    /// shared/not attributable.
    public var cost: Double?
    /// True when `cost` is an estimate (token-price fallback) — UI shows "?".
    public var costIsEstimate: Bool?

    public init(
        model: String,
        providerId: String,
        toolId: String? = nil,
        tokens: Int64,
        calls: Int,
        cost: Double? = nil,
        costIsEstimate: Bool? = nil
    ) {
        self.model = model
        self.providerId = providerId
        self.toolId = toolId
        self.tokens = tokens
        self.calls = calls
        self.cost = cost
        self.costIsEstimate = costIsEstimate
    }
}

/// One tool's effective-price series: daily balance delta ÷ daily tokens.
/// Only populated for tools whose balance source is exclusively theirs, so
/// both coordinates are facts.
public struct RateSeriesItem: Codable, Sendable {
    public var toolId: String
    public var label: String
    public var points: [RatePoint]

    public init(toolId: String, label: String, points: [RatePoint]) {
        self.toolId = toolId
        self.label = label
        self.points = points
    }
}

public struct RatePoint: Codable, Sendable {
    /// Day start (unix seconds).
    public var ts: Double
    /// Tokens logged that day (fact).
    public var tokens: Int64
    /// Balance delta that day (fact, attributable series only).
    public var cost: Double

    public init(ts: Double, tokens: Int64, cost: Double) {
        self.ts = ts
        self.tokens = tokens
        self.cost = cost
    }
}

public struct PredictionItem: Codable, Sendable {
    public var monthProjected: Double
    public var dailyRate: Double
    public var daysRemaining: Int
    public var monthSoFar: Double

    public init(monthProjected: Double, dailyRate: Double, daysRemaining: Int, monthSoFar: Double) {
        self.monthProjected = monthProjected
        self.dailyRate = dailyRate
        self.daysRemaining = daysRemaining
        self.monthSoFar = monthSoFar
    }
}

public struct TrendPoint: Codable, Sendable {
    public var ts: Double
    public var value: Double
    public var calls: Int64
    public var tokens: Int64
    public var netLines: Int
    public var added: Int = 0
    public var deleted: Int = 0

    public init(
        ts: Double,
        value: Double,
        calls: Int64,
        tokens: Int64,
        netLines: Int,
        added: Int = 0,
        deleted: Int = 0
    ) {
        self.ts = ts
        self.value = value
        self.calls = calls
        self.tokens = tokens
        self.netLines = netLines
        self.added = added
        self.deleted = deleted
    }
}

public struct RemainingBalanceItem: Codable, Sendable {
    public var providerId: String
    public var displayName: String
    public var balance: Double
    public var currency: String

    public init(providerId: String, displayName: String, balance: Double, currency: String) {
        self.providerId = providerId
        self.displayName = displayName
        self.balance = balance
        self.currency = currency
    }
}

/// Subscription quota state (Claude / Copilot window utilization + reset).
/// Mirrors the macOS model so iCloud-synced snapshots decode identically.
public struct QuotaStatusItem: Codable, Sendable {
    public var toolId: String
    public var utilization: Double
    public var limitStatus: String
    public var resetAt: Double
    public var windowSeconds: Double

    public init(toolId: String, utilization: Double, limitStatus: String, resetAt: Double, windowSeconds: Double) {
        self.toolId = toolId
        self.utilization = utilization
        self.limitStatus = limitStatus
        self.resetAt = resetAt
        self.windowSeconds = windowSeconds
    }
}

public struct ToolDetailItem: Codable, Sendable {
    public var source: String
    public var conclusion: ToolConclusionItem
    public var sessions: [ToolSessionItem]

    public init(source: String, conclusion: ToolConclusionItem, sessions: [ToolSessionItem]) {
        self.source = source
        self.conclusion = conclusion
        self.sessions = sessions
    }
}

extension ToolDetailItem: Identifiable {
    public var id: String { source }
}

public struct ToolConclusionItem: Codable, Sendable {
    public var spend: Double = 0
    public var previousSpend: Double = 0
    public var deltaPct: Double = 0
    public var projectedMonth: Double = 0
    public var sessionCount: Int = 0
    public var commitCount: Int = 0
    public var addedLines: Int = 0
    public var deletedLines: Int = 0
    public var avgCostPerSession: Double = 0
    public var cpl: Double = 0
    public var crossToolDeltaPct: Double? = nil

    public init(
        spend: Double = 0,
        previousSpend: Double = 0,
        deltaPct: Double = 0,
        projectedMonth: Double = 0,
        sessionCount: Int = 0,
        commitCount: Int = 0,
        addedLines: Int = 0,
        deletedLines: Int = 0,
        avgCostPerSession: Double = 0,
        cpl: Double = 0,
        crossToolDeltaPct: Double? = nil
    ) {
        self.spend = spend
        self.previousSpend = previousSpend
        self.deltaPct = deltaPct
        self.projectedMonth = projectedMonth
        self.sessionCount = sessionCount
        self.commitCount = commitCount
        self.addedLines = addedLines
        self.deletedLines = deletedLines
        self.avgCostPerSession = avgCostPerSession
        self.cpl = cpl
        self.crossToolDeltaPct = crossToolDeltaPct
    }
}

public struct ToolSessionItem: Codable, Sendable {
    public var sessionId: String?
    public var title: String?
    public var repo: String?
    public var firstTs: Int64
    public var lastTs: Int64
    public var cost: Double
    public var windowTokens: Int?
    public var lastInput: Int
    public var turnCount: Int
    public var avgOccupancy: Double?
    public var avgCacheRatio: Double?
    public var compactionCount: Int

    public init(
        sessionId: String?,
        title: String?,
        repo: String?,
        firstTs: Int64,
        lastTs: Int64,
        cost: Double,
        windowTokens: Int?,
        lastInput: Int,
        turnCount: Int,
        avgOccupancy: Double?,
        avgCacheRatio: Double?,
        compactionCount: Int
    ) {
        self.sessionId = sessionId
        self.title = title
        self.repo = repo
        self.firstTs = firstTs
        self.lastTs = lastTs
        self.cost = cost
        self.windowTokens = windowTokens
        self.lastInput = lastInput
        self.turnCount = turnCount
        self.avgOccupancy = avgOccupancy
        self.avgCacheRatio = avgCacheRatio
        self.compactionCount = compactionCount
    }
}
