# Data Flow — AI Pulse Multi-Platform

## Architecture Overview

macOS is the sole data producer. iOS and watchOS are read-only consumers via iCloud.

```
┌─────────────────────────────────────────────────────────────────┐
│                     macOS (Data Producer)                       │
│                                                                 │
│  AI Tools ──▶ LogWatcher/ApiPoller ──▶ GRDB (SQLite)           │
│                                            │                    │
│                              StatsService.dashboardSnapshot()   │
│                                            │                    │
│                              DashboardCache (GRDB table)        │
│                                            │                    │
│                              CloudSyncService ──▶ iCloud        │
└─────────────────────────────────────────────────────────────────┘
                     │
          ┌──────────┴──────────┐
          ▼                     ▼
┌──────────────────┐  ┌──────────────────┐
│       iOS        │  │     watchOS      │
│                  │  │                  │
│ CloudDataService │  │ CloudDataService │
│  hasData()       │  │  refresh()       │
│  mergeWeek()     │  │  mergeWeek()     │
│  mergeMonth()    │  │  mergeMonth()    │
│       │          │  │       │          │
│       ▼          │  │       ▼          │
│ DashboardView    │  │  SpendView       │
│ (Swift Charts)   │  │ (Activity Rings) │
└──────────────────┘  └──────────────────┘
```

## CloudKit Schema

Single record type: `DashboardCache_v2`

| Record Name | Content | Sync Frequency |
|-------------|---------|---------------|
| `snapshot-today` | Full snapshot (today perspective) | ~5 min |
| `snapshot-week` | Full snapshot (week perspective) | ~1 hour |
| `snapshot-30d` | Full snapshot (30d perspective) | ~12 hours |

Each record stores a JSON blob (`DashboardSnapshot`) under the `json` field.

## DashboardSnapshot Structure

```swift
struct DashboardSnapshot: Codable {
    // Primary cost data
    var todayCost: Double       // From snapshot-today
    var weekCost: Double        // From snapshot-week
    var monthCost: Double       // From snapshot-30d
    var yesterdaySpend: Double  // From snapshot-today
    var subDaily: Double        // Subscription daily amortization

    // Volume data
    var todayCalls: Int64       // Int64 for arm64_32 watchOS
    var todayTokens: Int64

    // Charts & rankings
    var providerBreakdown: [ProviderItem]
    var toolBreakdown: [NameCostItem]
    var topRepos: [RepoItem]
    var prediction: PredictionItem?

    // Trend data
    var dailyStats: [TrendPoint]
    var codeChanges: [TrendPoint]
    var balanceDaily: [TrendPoint]

    var updatedAt: Date
}
```

### Merge Strategy

Each platform fetches all three records but only merges range-specific fields:

| Record | Fields Merged |
|--------|--------------|
| `snapshot-today` | `todayCost`, `yesterdaySpend` |
| `snapshot-week` | `weekCost` |
| `snapshot-30d` | `monthCost`, `prediction` |

This prevents the week record's stale `todayCost` from overwriting the fresh today record's value.

## Platform Details

### macOS — Data Producer

1. **Collection**: LogWatcher parses Claude Code/aider logs; ApiPoller queries provider balance APIs
2. **Storage**: GRDB (SQLite) stores `DailyStat`, `DailyCodeChange`, `ProviderCost`
3. **Aggregation**: `StatsService.dashboardSnapshot(days:)` computes `DashboardSnapshot`
4. **Local Cache**: `DashboardCache` table (GRDB) for instant dashboard open
5. **iCloud Sync**: `CloudSyncService.syncFromCache()` writes 3 CKRecords, throttled per range

### iOS — Data Consumer

1. **Launch**: `ContentView` splash → `checkCloud()` → parallel with 1s minimum
2. **Fetch Today**: `hasData()` → CK fetch `snapshot-today` → DashboardView appears
3. **Fill Week/Month**: `fetchAndMergeWeek()` + `fetchAndMergeMonth()` → merge into snapshot
4. **No local cache**: Every open fetches from iCloud. Sub-second latency on good network.

### watchOS — Data Consumer

1. **Launch/Active**: `refresh()` → account check → fetch all three snapshots
2. **Merge**: Same merge strategy as iOS
3. **Refresh**: Triggered by wrist raise (`didBecomeActive`), tap, or app open
4. **No push notifications**: Companion to iOS, relies on on-demand iCloud fetch

## Cache Strategy

| Platform | Cache | Purpose | TTL |
|----------|-------|---------|-----|
| macOS DashboardView | `DashboardCache` (GRDB) | Instant open | 30s (skip on first load) |
| macOS → iCloud | `CloudSyncService` | Background sync | 5min/1hr/12hr per range |
| iOS | None | — | Direct iCloud fetch |
| watchOS | None | — | Direct iCloud fetch |

## Architecture Decisions

- **Single writer**: macOS is the only writer to iCloud. No merge conflicts.
- **Three records, not one**: Different sync frequencies. Today changes frequently; 30d is stable. Writing all three avoids fetching a single giant record every time.
- **JSON blob, not typed fields**: `DashboardSnapshot` is serialized as JSON into a single `json` field. Simpler schema evolution — add fields to the struct without CloudKit schema changes.
- **Int64 for tokens**: watchOS arm64_32 has 32-bit `Int`. Token counts >2.1B overflow. `Int64` everywhere for consistency.
