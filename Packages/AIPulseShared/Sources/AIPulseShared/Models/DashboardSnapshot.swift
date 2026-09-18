import Foundation

/// Current token activity, not a bill, quota gauge or attribution claim.
public enum PulseTier: String, Codable, Sendable, Equatable, CaseIterable {
    case resting
    case active
    case elevated
    case intense
}

public enum PulseSignalKind: String, Codable, Sendable, Equatable, CaseIterable {
    case activity
    case observedSpend
    case quota
    case attributedOutput
}

public enum PulseFreshness: String, Codable, Sendable, Equatable {
    case fresh
    case aging
    case stale
    case unavailable
}

public enum PulseCompleteness: String, Codable, Sendable, Equatable {
    case complete
    case intervalNet
    case providerWindow
    case partial
    case unknown
}

public struct PulseSignal: Codable, Sendable, Equatable {
    public var kind: PulseSignalKind
    public var rawValue: Double?
    public var unit: String
    public var baseline: Double?
    public var normalized: Double
    public var freshness: PulseFreshness
    public var completeness: PulseCompleteness
    public var observedAt: Date?
    public var reason: String

    public init(kind: PulseSignalKind, rawValue: Double?, unit: String,
                baseline: Double?, normalized: Double,
                freshness: PulseFreshness, completeness: PulseCompleteness,
                observedAt: Date?, reason: String) {
        self.kind = kind
        self.rawValue = rawValue
        self.unit = unit
        self.baseline = baseline
        self.normalized = normalized
        self.freshness = freshness
        self.completeness = completeness
        self.observedAt = observedAt
        self.reason = reason
    }
}

public struct PulseActivityFacts: Codable, Sendable, Equatable {
    /// Exact observed totals, never the exponentially weighted intensity.
    public var recentTokens: Int64
    public var todayTokens: Int64
    public var windowSeconds: Int
    public var isPartial: Bool

    public init(recentTokens: Int64, todayTokens: Int64, windowSeconds: Int = 600,
                isPartial: Bool = false) {
        self.recentTokens = recentTokens
        self.todayTokens = todayTokens
        self.windowSeconds = windowSeconds
        self.isPartial = isPartial
    }
}

public struct PulseSnapshot: Codable, Sendable, Equatable {
    public var tier: PulseTier
    public var primarySignal: PulseSignalKind?
    public var reason: String
    public var signals: [PulseSignal]
    public var activityFacts: PulseActivityFacts?
    public var asOf: Date
    /// A current-state observation is not a historical period summary.
    public var validUntil: Date

    public init(tier: PulseTier, primarySignal: PulseSignalKind?, reason: String,
                signals: [PulseSignal], asOf: Date, validUntil: Date? = nil,
                activityFacts: PulseActivityFacts? = nil) {
        self.tier = tier
        self.primarySignal = primarySignal
        self.reason = reason
        self.signals = signals
        self.activityFacts = activityFacts
        self.asOf = asOf
        self.validUntil = validUntil ?? asOf.addingTimeInterval(60)
    }

    public func isCurrent(asOf now: Date = Date()) -> Bool {
        guard asOf.timeIntervalSince1970.isFinite, validUntil.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite else { return false }
        return asOf <= now && now < validUntil && validUntil > asOf
    }

    public func sanitized() -> PulseSnapshot {
        func safe(_ value: Double) -> Double { value.isFinite && value >= 0 ? value : 0 }
        var clean = self
        clean.signals = signals.map { signal in
            var result = signal
            result.rawValue = signal.rawValue.map(safe)
            result.baseline = signal.baseline.map(safe)
            result.normalized = safe(signal.normalized)
            return result
        }
        if let facts = activityFacts,
           facts.recentTokens < 0 || facts.todayTokens < 0 || facts.windowSeconds != 600 {
            clean.activityFacts = nil // Invalid facts are unavailable, not fabricated zeros.
        }
        return clean
    }

    public var activity: PulseSignal? { signals.first { $0.kind == .activity } }
    public var observedSpend: PulseSignal? { signals.first { $0.kind == .observedSpend } }
    public var quota: PulseSignal? { signals.first { $0.kind == .quota } }
    public var attributedOutput: PulseSignal? { signals.first { $0.kind == .attributedOutput } }
}

/// Full dashboard snapshot — computed by macOS and synced via iCloud.
/// iOS/watchOS read this structure to render their dashboards.
/// Completeness of captured components, not coverage of an entire AI account.
/// nil counters indicate a failed/unavailable observation query, not zero use.
public struct ActivityCoverage: Codable, Sendable, Equatable {
    public var observedEvents: Int64?
    public var incompleteEvents: Int64?

    public init(observedEvents: Int64? = nil, incompleteEvents: Int64? = nil) {
        self.observedEvents = observedEvents
        self.incompleteEvents = incompleteEvents
    }

    public var isPartial: Bool? {
        guard let observedEvents, observedEvents >= 0,
              let incompleteEvents, incompleteEvents >= 0, incompleteEvents <= observedEvents else { return nil }
        return incompleteEvents > 0
    }
}

public struct DashboardSnapshot: Codable, Sendable {
    /// Unavailable queries, not confirmed zeros. Required in decoded payloads.
    public var readFailures: [String] = []
    public var version: Int = 2
    public var period: DashboardPeriod = DashboardPeriod(kind: .today)

    public var todayCalls: Int64 = 0
    public var todayTokens: Int64 = 0
    /// Distinct nonempty sessions by (source, session_id).
    public var periodSessions: Int64 = 0
    public var activityCoverage: ActivityCoverage = ActivityCoverage()
    /// Balance/usage API interval net spend in original currencies. nil for legacy.
    public var observedSpend: [ObservedSpendItem]?
    /// Converted sum of `observedSpend`; conversion is not a native-currency fact.
    public var convertedObservedSpendUSD: Double?
    /// User-entered or catalog-prefilled fixed monthly context. nil for legacy.
    public var declaredMonthlyCostUSD: Double?

    public var providerBreakdown: [ProviderItem] = []
    public var toolBreakdown: [ToolActivityItem] = []
    public var topRepos: [RepoItem] = []

    public var dailyStats: [TrendPoint] = []
    public var codeChanges: [TrendPoint] = []
    public var balanceDaily: [TrendPoint] = []
    public var remainingBalances: [RemainingBalanceItem] = []
    public var quotaStatus: [QuotaStatusItem] = []
    /// Per-model usage/cost attribution (BYOK mixes live here). Optional so
    /// older macOS writers can produce snapshots without this block.
    public var modelBreakdown: [ModelActivityItem] = []
    /// Sync metadata written by macOS:
    /// `payloadVersion` = JSON payload format version; `writerAppVersion` = the
    /// macOS app version that produced this snapshot. Optional so legacy
    /// records (pre-versioning) still decode structurally.
    public var payloadVersion: String?
    public var writerAppVersion: String?

    public var updatedAt: Date = Date()

    public init(
        version: Int = 2,
        todayCalls: Int64 = 0,
        todayTokens: Int64 = 0,
        activityCoverage: ActivityCoverage = ActivityCoverage(),
        observedSpend: [ObservedSpendItem]? = nil,
        convertedObservedSpendUSD: Double? = nil,
        declaredMonthlyCostUSD: Double? = nil,
        providerBreakdown: [ProviderItem] = [],
        toolBreakdown: [ToolActivityItem] = [],
        topRepos: [RepoItem] = [],
        dailyStats: [TrendPoint] = [],
        codeChanges: [TrendPoint] = [],
        balanceDaily: [TrendPoint] = [],
        remainingBalances: [RemainingBalanceItem] = [],
        quotaStatus: [QuotaStatusItem] = [],
        modelBreakdown: [ModelActivityItem] = [],
        payloadVersion: String? = nil,
        writerAppVersion: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.todayCalls = todayCalls
        self.todayTokens = todayTokens
        self.activityCoverage = activityCoverage
        self.observedSpend = observedSpend
        self.convertedObservedSpendUSD = convertedObservedSpendUSD
        self.declaredMonthlyCostUSD = declaredMonthlyCostUSD
        self.providerBreakdown = providerBreakdown
        self.toolBreakdown = toolBreakdown
        self.topRepos = topRepos
        self.dailyStats = dailyStats
        self.codeChanges = codeChanges
        self.balanceDaily = balanceDaily
        self.remainingBalances = remainingBalances
        self.quotaStatus = quotaStatus
        self.modelBreakdown = modelBreakdown
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
        clean.todayCalls = Self.safeNonNegative(todayCalls)
        clean.todayTokens = Self.safeNonNegative(todayTokens)
        clean.observedSpend = observedSpend?.map {
            ObservedSpendItem(
                providerId: $0.providerId,
                amount: Self.safeNonNegative($0.amount),
                currency: $0.currency,
                convertedUSD: $0.convertedUSD.map(Self.safeNonNegative),
                conversionRateToUSD: $0.conversionRateToUSD.map(Self.safeNonNegative),
                conversionSource: $0.conversionSource,
                observedAt: Self.safeNonNegative($0.observedAt),
                intervalStart: $0.intervalStart.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                intervalEnd: $0.intervalEnd.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        }
        clean.convertedObservedSpendUSD = convertedObservedSpendUSD.map(Self.safeNonNegative)
        clean.declaredMonthlyCostUSD = declaredMonthlyCostUSD.map(Self.safeNonNegative)

        clean.providerBreakdown = providerBreakdown.map {
            ProviderItem(
                providerId: $0.providerId,
                name: $0.name,
                cost: Self.safeNonNegative($0.cost),
                sourceKind: $0.sourceKind)
        }
        clean.toolBreakdown = toolBreakdown.map {
            ToolActivityItem(
                toolId: $0.toolId,
                name: $0.name,
                tokens: $0.tokens.map(Self.safeNonNegative),
                calls: $0.calls.map(Self.safeNonNegative))
        }
        clean.topRepos = topRepos.map {
            RepoItem(
                repoPath: $0.repoPath,
                name: $0.name,
                added: Self.safeNonNegative($0.added),
                deleted: Self.safeNonNegative($0.deleted),
                tokens: $0.tokens.map(Self.safeNonNegative),
                commits: Self.safeNonNegative($0.commits))
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
                windowId: $0.windowId,
                utilization: Self.safeNonNegative($0.utilization),
                limitStatus: $0.limitStatus,
                resetAt: Self.safeNonNegative($0.resetAt),
                windowSeconds: Self.safeNonNegative($0.windowSeconds),
                updatedAt: $0.updatedAt.map(Self.safeNonNegative))
        }
        clean.modelBreakdown = modelBreakdown.map {
            ModelActivityItem(
                model: $0.model,
                providerId: $0.providerId,
                toolId: $0.toolId,
                tokens: Self.safeNonNegative($0.tokens),
                calls: Self.safeNonNegative($0.calls))
        }
        clean.periodSessions = Self.safeNonNegative(periodSessions)
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
            deleted: Self.safeNonNegative(p.deleted),
            commits: Self.safeNonNegative(p.commits))
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

public struct ToolActivityItem: Codable, Sendable {
    public var toolId: String
    public var name: String
    public var tokens: Int64?
    public var calls: Int?
    public init(toolId: String, name: String, tokens: Int64? = nil, calls: Int? = nil) {
        self.toolId = toolId; self.name = name; self.tokens = tokens; self.calls = calls
    }
}

public struct RepoItem: Codable, Sendable, Identifiable {
    public var id: String { repoPath }
    /// Canonical Git root; basename is only a display label.
    public var repoPath: String
    public var name: String
    public var added: Int
    public var deleted: Int
    public var commits: Int
    public var tokens: Int64?
    public var totalChanges: Int { added + deleted }
    public init(repoPath: String, name: String, added: Int, deleted: Int, tokens: Int64? = nil, commits: Int = 0) {
        self.repoPath = repoPath; self.name = name; self.added = added
        self.deleted = deleted; self.tokens = tokens; self.commits = commits
    }
}

/// Per-model usage/cost attribution, primarily for BYOK mixes where a tool
/// runs third-party models (e.g. Claude Code on a DeepSeek key).
public struct ModelActivityItem: Codable, Sendable {
    public var model: String
    public var providerId: String
    public var toolId: String?
    public var tokens: Int64
    public var calls: Int
    public init(model: String, providerId: String, toolId: String? = nil, tokens: Int64, calls: Int) {
        self.model = model; self.providerId = providerId; self.toolId = toolId
        self.tokens = tokens; self.calls = calls
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
    public var commits: Int = 0

    public init(
        ts: Double,
        value: Double,
        calls: Int64,
        tokens: Int64,
        netLines: Int,
        added: Int = 0,
        deleted: Int = 0,
        commits: Int = 0
    ) {
        self.ts = ts
        self.value = value
        self.calls = calls
        self.tokens = tokens
        self.netLines = netLines
        self.added = added
        self.deleted = deleted
        self.commits = commits
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

/// Provider-reported balance/usage movement aggregated over one snapshot range.
/// `amount` preserves the original currency; `convertedUSD` is a separate
/// convenience conversion and must not be presented as native provider data.
public struct ObservedSpendItem: Codable, Sendable, Equatable {
    public var stableId: String { providerId + "|" + currency.uppercased() }
    public var providerId: String
    public var amount: Double
    public var currency: String
    /// Optional estimate. nil means no known conversion and must not be shown
    /// as USD by assuming a 1:1 rate.
    public var convertedUSD: Double?
    public var conversionRateToUSD: Double?
    /// Human-readable provenance for the rate, e.g. an internal static table.
    public var conversionSource: String?
    public var observedAt: Double
    /// Outer sampling bounds in Unix seconds. The amount is interval net
    /// decrease; a sample before the selected period may be its baseline.
    public var intervalStart: Double?
    public var intervalEnd: Double?

    public init(
        providerId: String,
        amount: Double,
        currency: String,
        convertedUSD: Double?,
        conversionRateToUSD: Double? = nil,
        conversionSource: String? = nil,
        observedAt: Double,
        intervalStart: Double? = nil,
        intervalEnd: Double? = nil
    ) {
        self.providerId = providerId
        self.amount = amount
        self.currency = currency
        self.convertedUSD = convertedUSD
        self.conversionRateToUSD = conversionRateToUSD
        self.conversionSource = conversionSource
        self.observedAt = observedAt
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
    }
}

/// Subscription quota state (Claude / Copilot window utilization + reset).
/// Mirrors the macOS model so iCloud-synced snapshots decode identically.
public struct QuotaStatusItem: Codable, Sendable {
    public var toolId: String
    /// Stable provider window id such as "5h", "7d", or "monthly".
    /// nil only when decoding a legacy snapshot.
    public var windowId: String?
    public var utilization: Double
    public var limitStatus: String
    public var resetAt: Double
    public var windowSeconds: Double
    /// Unix timestamp (seconds) when this quota value was observed.
    public var updatedAt: Double?

    public init(
        toolId: String,
        windowId: String? = nil,
        utilization: Double,
        limitStatus: String,
        resetAt: Double,
        windowSeconds: Double,
        updatedAt: Double? = nil
    ) {
        self.toolId = toolId
        self.windowId = windowId
        self.utilization = utilization
        self.limitStatus = limitStatus
        self.resetAt = resetAt
        self.windowSeconds = windowSeconds
        self.updatedAt = updatedAt
    }

    public func isStale(asOf: Date = Date(), maxAge: TimeInterval = 2 * 3_600) -> Bool {
        guard let updatedAt, updatedAt.isFinite, updatedAt > 0 else { return true }
        let now = asOf.timeIntervalSince1970
        guard now.isFinite, maxAge.isFinite, maxAge >= 0 else { return true }
        if updatedAt > now || now - updatedAt > maxAge { return true }
        if !resetAt.isFinite || (resetAt > 0 && resetAt <= now) { return true }
        return false
    }

    public var stableId: String { "\(toolId)|\(windowId ?? "legacy")" }
}
