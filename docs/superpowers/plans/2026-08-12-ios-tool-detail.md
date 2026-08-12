# iOS Tool Detail（会话级统计）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS 把工具三行摘要 + 会话列表（含会话档案指标）增量写入 CloudKit 快照，iOS 端提供可点击的工具详情面板（摘要 + 会话列表 + 会话档案卡）。

**Architecture:** 数据层在 macOS 的 `DashboardSnapshot` 增量添加 `toolDetails` 字段（不 bump payloadVersion、不新增 CloudKit 记录类型）；会话档案指标在 macOS 写快照时用"单次批量读取 + Swift 分组聚合"计算。UI 层在 iOS 新增 sheet 详情面板，数据直接来自快照。

**Tech Stack:** SwiftUI、GRDB（macOS 聚合查询）、CloudKit（现有同步，不改）、Xcode 26.6（Swift 6.3）。

## Global Constraints

- `CKSchema.payloadVersion` 保持 `"1.2.4"` 不变（两份常量文件都不改）。
- 不新增 CloudKit 记录类型、不新增订阅、不改同步循环。
- `toolDetails` 为增量可选字段（默认空数组），旧客户端忽略，旧快照缺失时 iOS 显示空态。
- iOS 不实现 per-turn 趋势图；会话行点开显示"会话档案卡"，底部标注"对话历史趋势图请在 macOS 版查看"。
- 会话档案指标（turnCount / avgOccupancy / avgCacheRatio / compactionCount）在 macOS 侧计算，不依赖定价表。
- iOS I18n 新增 key 需在 `Suites/Shared/I18n/I18n.swift` 的全部 10 种语言（en、zh-Hans、zh-Hant-TW、zh-Hant-HK、ja、ko、de、fr、es、pt-BR）中补齐。
- 验证命令：
  - macOS 构建：`xcodebuild -project AIPulse/AIPulse.xcodeproj -scheme AIPulse_macOS -configuration Debug -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/AIPulse-aczbwitgdbvfhncfhiamhgkajsjm CODE_SIGNING_ALLOWED=NO build`
  - macOS 测试（隔离缓存，不污染 Xcode）：`swift test --scratch-path /tmp/ai-pulse-spm --cache-path /tmp/ai-pulse-spm-cache --config-path /tmp/ai-pulse-spm-config`
  - iOS 构建：`xcodebuild -project Suites/AIPulse_Suites.xcodeproj -scheme AIPulse_iOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/aipulse-suites-dd CODE_SIGNING_ALLOWED=NO build`

---

### Task 1: macOS 数据模型（DashboardSnapshot 增加 toolDetails）

**Files:**
- Modify: `Sources/Store/DashboardCache.swift`

**Interfaces:**
- Produces: `DashboardSnapshot.toolDetails: [ToolDetailItem]`，以及 `ToolDetailItem` / `ToolConclusionItem` / `ToolSessionItem` 三个 Codable 结构（Task 2/4 使用，两端字段必须一致）

- [ ] **Step 1: 在 DashboardSnapshot 增加字段与结构**

在 `Sources/Store/DashboardCache.swift` 的 `DashboardSnapshot` 中、`payloadVersion` 声明之前插入：

```swift
    // Tool detail: per-tool conclusion summary + session list, added in 1.2.5
    // as a backward-compatible increment (old clients ignore this field).
    var toolDetails: [ToolDetailItem] = []
```

在文件末尾（`TrendPoint` 之后、`RemainingBalanceItem` 之前任意位置均可）追加三个结构：

```swift
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
```

- [ ] **Step 2: 构建验证**

Run: macOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add Sources/Store/DashboardCache.swift
git commit -m "feat: add toolDetails to macOS DashboardSnapshot"
```

---

### Task 2: macOS 会话档案指标计算 + 快照填充

**Files:**
- Modify: `Sources/Store/SessionStats.swift`
- Modify: `Sources/Store/StatsService.swift`
- Modify: `Tests/SessionStatsTests.swift`

**Interfaces:**
- Consumes: `ToolDetailItem` / `ToolConclusionItem` / `ToolSessionItem`（Task 1）；现有 `ToolConclusion` / `SessionRow` / `TurnPoint`
- Produces:
  - `SessionMetrics`（turnCount / avgOccupancy / avgCacheRatio / compactionCount）
  - `SessionStats.metrics(turns:windowTokens:) -> SessionMetrics`
  - `StatsService.toolDetail(source:sinceMs:) async -> ToolDetailItem`
  - `SessionRow` 扩展四个档案字段（供 overlay 与映射复用）

- [ ] **Step 1: 写失败测试（SessionStats.metrics）**

在 `Tests/SessionStatsTests.swift` 末尾追加：

```swift
    func testSessionMetricsComputesProfile() {
        let turns = [
            TurnPoint(index: 0, ts: 1, inputTokens: 50, cacheTokens: 40, outTokens: 10, cost: 0.1, contextTokens: 50),
            TurnPoint(index: 1, ts: 2, inputTokens: 100, cacheTokens: 90, outTokens: 20, cost: 0.2, contextTokens: 100),
            // context 100 → 60 (< 70%) is marked as a compaction
            TurnPoint(index: 2, ts: 3, inputTokens: 60, cacheTokens: 50, outTokens: 30, cost: 0.3, contextTokens: 60),
        ]
        let m = SessionStats.metrics(turns: turns, windowTokens: 200)
        XCTAssertEqual(m.turnCount, 3)
        XCTAssertEqual(m.avgOccupancy ?? -1, (50 + 100 + 60) / Double(3 * 200), accuracy: 0.0001)
        XCTAssertEqual(m.avgCacheRatio ?? -1, (40.0 / 50 + 90.0 / 100 + 50.0 / 60) / 3, accuracy: 0.0001)
        XCTAssertEqual(m.compactionCount, 1)
    }

    func testSessionMetricsEmptyAndNilWindow() {
        let m = SessionStats.metrics(turns: [], windowTokens: nil)
        XCTAssertEqual(m.turnCount, 0)
        XCTAssertNil(m.avgOccupancy)
        XCTAssertNil(m.avgCacheRatio)
        XCTAssertEqual(m.compactionCount, 0)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --scratch-path /tmp/ai-pulse-spm --cache-path /tmp/ai-pulse-spm-cache --config-path /tmp/ai-pulse-spm-config --filter SessionStatsTests`
Expected: FAIL — `value of type 'SessionStats' has no member 'metrics'`

- [ ] **Step 3: 实现 SessionStats.metrics**

在 `Sources/Store/SessionStats.swift` 的 `SessionStats` 枚举内、`cacheSavings` 之后追加：

```swift
    /// Aggregated per-session profile metrics for the iOS session card.
    struct SessionMetrics: Equatable {
        var turnCount: Int = 0
        var avgOccupancy: Double?
        var avgCacheRatio: Double?
        var compactionCount: Int = 0
    }

    static func metrics(turns: [TurnPoint], windowTokens: Int?) -> SessionMetrics {
        var m = SessionMetrics()
        m.turnCount = turns.count
        if let window = windowTokens, window > 0, !turns.isEmpty {
            m.avgOccupancy = turns.reduce(0.0) { $0 + Double($1.contextTokens) } / Double(turns.count * window)
        }
        let ratios = turns
            .filter { $0.contextTokens > 0 }
            .map { Double($0.cacheTokens) / Double($0.contextTokens) }
        if !ratios.isEmpty {
            m.avgCacheRatio = ratios.reduce(0.0, +) / Double(ratios.count)
        }
        m.compactionCount = compactionMarks(turns).count
        return m
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: 同 Step 2
Expected: PASS（2 个新测试）

- [ ] **Step 5: 扩展 SessionRow 并让 sessionRows 计算档案指标**

在 `Sources/Store/SessionStats.swift` 的 `SessionRow` 中追加四个字段：

```swift
    // Session profile metrics (computed by StatsService.sessionRows)
    var turnCount: Int = 0
    var avgOccupancy: Double? = nil
    var avgCacheRatio: Double? = nil
    var compactionCount: Int = 0
```

在 `Sources/Store/StatsService.swift` 的 `sessionRows(source:sinceMs:)` 中，把 `AppDatabase.shared.read` 闭包替换为（基础查询不变，追加批量 turn 读取 + Swift 分组聚合）：

```swift
            return try await AppDatabase.shared.read { db -> [SessionRow] in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT u.session_id AS sid,
                           MIN(u.ts) AS first_ts,
                           MAX(u.ts) AS last_ts,
                           (SELECT in_tokens FROM usage_event u3
                            WHERE u3.source = u.source AND u3.session_id = u.session_id
                            ORDER BY u3.ts DESC LIMIT 1) AS last_input,
                           COALESCE(SUM(u.cost_usd), 0) AS cost,
                           COALESCE((SELECT repo_path FROM usage_event u2
                                     WHERE u2.source = u.source AND u2.session_id = u.session_id
                                     ORDER BY u2.ts LIMIT 1), '') AS repo,
                           s.title AS title,
                           s.window_tokens AS window
                    FROM usage_event u
                    LEFT JOIN session_info s ON s.source = u.source AND s.session_id = u.session_id
                    WHERE u.source = ? AND u.ts >= ? AND u.ts < ? AND u.session_id IS NOT NULL
                    GROUP BY u.session_id
                    ORDER BY cost DESC
                    """, arguments: [source, sinceMs, toMs])
                // Batch-load all turns in the range, then aggregate per session
                // in Swift (30d ≈ 20k rows, millisecond-scale; keeps SQL simple
                // and the aggregation logic unit-testable via SessionStats.metrics).
                let turns = try Row.fetchAll(db, sql: """
                    SELECT session_id AS sid, in_tokens AS inT, cache_tokens AS cacheT
                    FROM usage_event
                    WHERE source = ? AND ts >= ? AND ts < ? AND session_id IS NOT NULL
                      AND (in_tokens + cache_tokens) > 0
                    ORDER BY ts
                    """, arguments: [source, sinceMs, toMs])
                var grouped: [String: [TurnPoint]] = [:]
                for row in turns {
                    let sid: String = row["sid"]
                    let input: Int = row["inT"] ?? 0
                    let cache: Int = row["cacheT"] ?? 0
                    let ctx = input + (source == "claude-code" ? cache : 0)
                    var list = grouped[sid] ?? []
                    list.append(TurnPoint(
                        index: list.count, ts: 0, inputTokens: input,
                        cacheTokens: cache, outTokens: 0, cost: 0, contextTokens: ctx))
                    grouped[sid] = list
                }
                return rows.map { row in
                    let sid: String? = row["sid"]
                    let window: Int? = row["window"]
                    let m = SessionStats.metrics(
                        turns: sid.flatMap { grouped[$0] } ?? [],
                        windowTokens: window)
                    return SessionRow(
                        source: source,
                        sessionId: sid,
                        title: row["title"],
                        repo: (row["repo"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                        firstTs: row["first_ts"] ?? 0,
                        lastTs: row["last_ts"] ?? 0,
                        lastInput: row["last_input"] ?? 0,
                        cost: row["cost"] ?? 0,
                        windowTokens: window,
                        turnCount: m.turnCount,
                        avgOccupancy: m.avgOccupancy,
                        avgCacheRatio: m.avgCacheRatio,
                        compactionCount: m.compactionCount)
                }
            }
```

- [ ] **Step 6: 实现 StatsService.toolDetail 并在 dashboardSnapshot 中填充**

在 `Sources/Store/StatsService.swift` 的 `sessionRows` 之后追加：

```swift
    /// One tool's detail block for the iOS detail panel: conclusion summary
    /// + session list with profile metrics.
    static func toolDetail(source: String, sinceMs: Int64) async -> ToolDetailItem {
        async let conclusion = toolConclusion(source: source, sinceMs: sinceMs)
        let rows = await sessionRows(source: source, sinceMs: sinceMs)
        let c = await conclusion
        return ToolDetailItem(
            source: source,
            conclusion: ToolConclusionItem(
                spend: c.spend,
                previousSpend: c.previousSpend,
                deltaPct: c.deltaPct,
                projectedMonth: c.projectedMonth,
                sessionCount: c.sessionCount,
                commitCount: c.commitCount,
                addedLines: c.addedLines,
                deletedLines: c.deletedLines,
                avgCostPerSession: c.avgCostPerSession,
                cpl: c.cpl,
                crossToolDeltaPct: c.crossToolDeltaPct),
            sessions: rows.map {
                ToolSessionItem(
                    sessionId: $0.sessionId,
                    title: $0.title,
                    repo: $0.repo,
                    firstTs: $0.firstTs,
                    lastTs: $0.lastTs,
                    cost: $0.cost,
                    windowTokens: $0.windowTokens,
                    lastInput: $0.lastInput,
                    turnCount: $0.turnCount,
                    avgOccupancy: $0.avgOccupancy,
                    avgCacheRatio: $0.avgCacheRatio,
                    compactionCount: $0.compactionCount)
            })
    }
```

在 `dashboardSnapshot(days:)` 的 `let toolRows = await resultOrLog("toolCosts", ...)` 之后插入并发计算并在返回前填充：

```swift
        async let codexDetail = StatsService.toolDetail(source: "codex", sinceMs: toolStartMs)
        async let claudeDetail = StatsService.toolDetail(source: "claude-code", sinceMs: toolStartMs)
```

在 `snap` 构造处（`var snap = DashboardSnapshot(...)` 之前）追加：

```swift
        var detailItems = [await codexDetail, await claudeDetail].filter { !$0.sessions.isEmpty }
```

并把 `snap` 改为 `var snap`（已是 var），随后在 `snap.payloadVersion = ...` 之前加：

```swift
        snap.toolDetails = detailItems
```

- [ ] **Step 7: 运行全部测试**

Run: `swift test --scratch-path /tmp/ai-pulse-spm --cache-path /tmp/ai-pulse-spm-cache --config-path /tmp/ai-pulse-spm-config`
Expected: 127 个测试全部通过（原 125 + 新增 2）

- [ ] **Step 8: 构建验证 + 提交**

Run: macOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`

```bash
git add Sources/Store/SessionStats.swift Sources/Store/StatsService.swift Tests/SessionStatsTests.swift
git commit -m "feat: compute session profile metrics and fill toolDetails in snapshot"
```

---

### Task 3: macOS 显示格式（footer + 关于页）

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardView.swift`
- Modify: `Sources/UI/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `Bundle.main`（`CFBundleShortVersionString`）、`CKSchema.payloadVersion`
- Produces: 仪表盘底部与关于页显示 `AI Pulse v1.2.5/CloudKit 1.2.4`

- [ ] **Step 1: macOS 仪表盘 footer**

在 `Sources/UI/Dashboard/DashboardView.swift` 的 `lastUpdatedFooter` 中，把：

```swift
            Text("CloudKit \(CKSchema.payloadVersion)")
                .font(.caption2).foregroundColor(.secondary)
```

替换为：

```swift
            Text("AI Pulse v\(Self.appVersion)/CloudKit \(CKSchema.payloadVersion)")
                .font(.caption2).foregroundColor(.secondary)
```

并在文件内新增：

```swift
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
```

- [ ] **Step 2: macOS 关于页**

在 `Sources/UI/Settings/SettingsView.swift` 的 `AboutTab` 中，把：

```swift
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"))").font(.caption).foregroundColor(.secondary)
```

替换为：

```swift
            Text("AI Pulse v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.0")").font(.caption).foregroundColor(.secondary)
```

（`CloudKit 1.2.4` 行保留。）

- [ ] **Step 3: 构建验证 + 提交**

Run: macOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`

```bash
git add Sources/UI/Dashboard/DashboardView.swift Sources/UI/Settings/SettingsView.swift
git commit -m "feat: show app + CloudKit version pair in macOS dashboard and About"
```

---

### Task 4: iOS 数据模型同步

**Files:**
- Modify: `Suites/Shared/Models/DashboardSnapshot.swift`

**Interfaces:**
- Produces: iOS 端 `DashboardSnapshot.toolDetails` + 三个结构（与 Task 1 字段完全一致），Task 5 的详情面板读取

- [ ] **Step 1: 增加字段与结构**

在 `Suites/Shared/Models/DashboardSnapshot.swift` 的 `DashboardSnapshot` 中、`payloadVersion` 之前插入：

```swift
    // Tool detail: per-tool conclusion summary + session list. Optional/empty
    // when produced by an older macOS app; old iOS clients ignore this field.
    var toolDetails: [ToolDetailItem] = []
```

在文件末尾追加与 Task 1 完全一致的三个结构（`ToolDetailItem` / `ToolConclusionItem` / `ToolSessionItem`）。

- [ ] **Step 2: 构建验证 + 提交**

Run: iOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`

```bash
git add Suites/Shared/Models/DashboardSnapshot.swift
git commit -m "feat: add toolDetails to iOS DashboardSnapshot"
```

---

### Task 5: iOS 详情面板 UI

**Files:**
- Create: `Suites/iOS/UI/ToolDetailSheetView.swift`
- Modify: `Suites/iOS/UI/DashboardView.swift`
- Modify: `Suites/Shared/I18n/I18n.swift`

**Interfaces:**
- Consumes: `DashboardSnapshot.toolDetails`（Task 4）、`I18n.t(...)` 新 key
- Produces: 工具行可点击 → sheet 显示三行摘要 + 会话列表 + 会话档案卡

- [ ] **Step 1: 新增 I18n keys（10 种语言）**

在 `Suites/Shared/I18n/I18n.swift` 每种语言中、`version.mismatch.supported` 行之后插入以下 16 个 key（每种语言一行表项）：

| key | en | zh-Hans | zh-Hant-TW/HK | ja | ko | de | fr | es | pt-BR |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| tool.detail.title | "Session Details" | "会话详情" | "會話詳情" | "セッション詳細" | "세션 상세" | "Sitzungsdetails" | "Détails de session" | "Detalles de sesión" | "Detalhes da sessão" |
| tool.detail.no_sessions | "No session data" | "暂无会话数据" | "暫無會話資料" | "セッションデータがありません" | "세션 데이터 없음" | "Keine Sitzungsdaten" | "Aucune donnée de session" | "Sin datos de sesión" | "Sem dados de sessão" |
| tool.detail.sessions | "Sessions" | "会话" | "會話" | "セッション" | "세션" | "Sitzungen" | "Sessions" | "Sesiones" | "Sessões" |
| tool.detail.spend | "Spend %@" | "支出 %@" | "支出 %@" | "支出 %@" | "지출 %@" | "Ausgaben %@" | "Dépenses %@" | "Gasto %@" | "Gasto %@" |
| tool.detail.delta | "vs previous %@" | "较上期 %@" | "較上期 %@" | "前回比 %@" | "이전 대비 %@" | "gegenüber vorher %@" | "vs précédent %@" | "vs anterior %@" | "vs anterior %@" |
| tool.detail.sessions_count | "%d sessions" | "%d 个会话" | "%d 個會話" | "%d セッション" | "%d개 세션" | "%d Sitzungen" | "%d sessions" | "%d sesiones" | "%d sessões" |
| tool.detail.commits | "%d commits" | "%d 次提交" | "%d 次提交" | "%d コミット" | "%d회 커밋" | "%d Commits" | "%d commits" | "%d commits" | "%d commits" |
| tool.detail.lines | "+%d/-%d lines" | "+%d/-%d 行" | "+%d/-%d 行" | "+%d/-%d 行" | "+%d/-%d 줄" | "+%d/-%d Zeilen" | "+%d/-%d lignes" | "+%d/-%d líneas" | "+%d/-%d linhas" |
| tool.detail.avg_cost | "Avg %@/session" | "平均 %@/会话" | "平均 %@/會話" | "平均 %@/セッション" | "평균 %@/세션" | "Ø %@/Sitzung" | "Moy. %@/session" | "Prom. %@/sesión" | "Méd. %@/sessão" |
| tool.detail.cpl | "CPL %@" | "CPL %@" | "CPL %@" | "CPL %@" | "CPL %@" | "CPL %@" | "CPL %@" | "CPL %@" | "CPL %@" |
| tool.detail.projected | "Projected month %@" | "预计本月 %@" | "預計本月 %@" | "今月予測 %@" | "이번 달 예상 %@" | "Prognose Monat %@" | "Mois projeté %@" | "Mes proyectado %@" | "Mês projetado %@" |
| tool.detail.turns | "%d turns" | "%d 轮对话" | "%d 輪對話" | "%d ターン" | "%d턴" | "%d Runden" | "%d tours" | "%d turnos" | "%d turnos" |
| tool.detail.avg_occupancy | "Avg occupancy %@" | "平均占用率 %@" | "平均佔用率 %@" | "平均使用率 %@" | "평균 점유율 %@" | "Ø Auslastung %@" | "Occupation moy. %@" | "Ocupación prom. %@" | "Ocupação méd. %@" |
| tool.detail.avg_cache | "Avg cache %@" | "平均缓存 %@" | "平均快取 %@" | "平均キャッシュ %@" | "평균 캐시 %@" | "Ø Cache %@" | "Cache moy. %@" | "Caché prom. %@" | "Cache méd. %@" |
| tool.detail.compactions | "%d compactions" | "%d 次压缩" | "%d 次壓縮" | "%d 回圧縮" | "%d회 압축" | "%d Komprimierungen" | "%d compressions" | "%d compresiones" | "%d compactações" |
| tool.detail.macos_note | "Conversation history trend is available in the macOS app" | "对话历史趋势图请在 macOS 版查看" | "對話歷史趨勢圖請在 macOS 版查看" | "会話履歴のトレンドはmacOS版で表示できます" | "대화 기록 추이는 macOS 앱에서 확인하세요" | "Gesprächsverlauf-Trend in der macOS-App verfügbar" | "L'historique des conversations est disponible dans l'app macOS" | "El historial de conversaciones está disponible en la app de macOS" | "O histórico de conversas está disponível no app macOS" |
| tool.detail.no_title | "No Title" | "无标题" | "無標題" | "タイトルなし" | "제목 없음" | "Kein Titel" | "Sans titre" | "Sin título" | "Sem título" |
| tool.detail.no_repo | "No repo" | "无仓库" | "無倉庫" | "リポジトリなし" | "저장소 없음" | "Kein Repo" | "Aucun dépôt" | "Sin repositorio" | "Sem repositório" |
| tool.detail.done | "Done" | "完成" | "完成" | "完了" | "완료" | "Fertig" | "Terminé" | "Listo" | "Concluído" |

（zh-Hant-TW 与 zh-Hant-HK 使用相同文案；每种语言需写成 `"key": "value",` 字典行。）

- [ ] **Step 2: 新建 ToolDetailSheetView.swift**

创建 `Suites/iOS/UI/ToolDetailSheetView.swift`：

```swift
import SwiftUI

/// Tool detail sheet: three-line conclusion summary + session list.
/// Sessions expand to a profile card (no per-turn chart — macOS only).
struct ToolDetailSheetView: View {
    let detail: ToolDetailItem
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSessionId: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    conclusionCard
                    if detail.sessions.isEmpty {
                        Text(I18n.t("tool.detail.no_sessions"))
                            .font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        sessionList
                    }
                }
                .padding()
            }
            .navigationTitle(I18n.t("tool.detail.title"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(I18n.t("tool.detail.done")) { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private var conclusionCard: some View {
        let c = detail.conclusion
        let delta = c.deltaPct
        return VStack(alignment: .leading, spacing: 8) {
            Text(detail.source == "codex" ? "ChatGPT" : "Claude Code")
                .font(.headline)
            Text(String(format: I18n.t("tool.detail.spend"), "$\(String(format: "%.2f", c.spend))"))
                .font(.title3).fontWeight(.bold)
            Text(String(format: I18n.t("tool.detail.delta"), String(format: "%+.1f%%", delta)))
                .font(.caption).foregroundColor(delta > 0 ? Color.deepRed : Color.marsGreen)
            HStack(spacing: 10) {
                Text(String(format: I18n.t("tool.detail.sessions_count"), c.sessionCount))
                Text(String(format: I18n.t("tool.detail.commits"), c.commitCount))
                Text(String(format: I18n.t("tool.detail.lines"), c.addedLines, c.deletedLines))
            }
            .font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 10) {
                Text(String(format: I18n.t("tool.detail.avg_cost"), "$\(String(format: "%.2f", c.avgCostPerSession))"))
                Text(String(format: I18n.t("tool.detail.cpl"), String(format: "%.2f", c.cpl)))
                if c.projectedMonth > 0 {
                    Text(String(format: I18n.t("tool.detail.projected"), "$\(String(format: "%.0f", c.projectedMonth))"))
                }
            }
            .font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18n.t("tool.detail.sessions")).font(.caption).foregroundColor(.secondary)
            ForEach(detail.sessions, id: \.sessionId) { row in
                sessionRow(row)
                if expandedSessionId == row.sessionId {
                    profileCard(row)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func sessionRow(_ row: ToolSessionItem) -> some View {
        let expanded = expandedSessionId == row.sessionId
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(row.title ?? I18n.t("tool.detail.no_title"))
                    .font(.caption).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                occupancyBar(row)
                Text("$\(String(format: "%.2f", row.cost))")
                    .font(.caption).monospacedDigit()
                    .foregroundColor(expanded ? Color.accentColor : Color.primary)
            }
            Text("\(row.lastTs > 0 ? Date(timeIntervalSince1970: Double(row.lastTs) / 1000).formatted(date: .abbreviated, time: .shortened) : "") · \(row.repo ?? I18n.t("tool.detail.no_repo"))")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(expanded ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedSessionId = expanded ? nil : row.sessionId
            }
        }
    }

    private func occupancyBar(_ row: ToolSessionItem) -> some View {
        let occ = row.windowTokens.flatMap { w in w > 0 ? Double(row.lastInput) / Double(w) : nil }
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.1)).frame(width: 40, height: 5)
            Capsule().fill(occ.map { $0 > 0.8 ? Color.orange : ($0 > 0.5 ? Color.yellow : Color.marsGreen) } ?? Color.primary.opacity(0.2))
                .frame(width: 40 * CGFloat(min(occ ?? 0, 1)), height: 5)
        }
    }

    private func profileCard(_ row: ToolSessionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: I18n.t("tool.detail.turns"), row.turnCount))
            Text(String(format: I18n.t("tool.detail.avg_occupancy"), row.avgOccupancy.map { String(format: "%.0f%%", $0 * 100) } ?? "—"))
            Text(String(format: I18n.t("tool.detail.avg_cache"), row.avgCacheRatio.map { String(format: "%.0f%%", $0 * 100) } ?? "—"))
            Text(String(format: I18n.t("tool.detail.compactions"), row.compactionCount))
            Text(I18n.t("tool.detail.macos_note"))
                .font(.caption2).foregroundColor(.secondary)
        }
        .font(.caption)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 3: DashboardView 接入点击 + sheet**

在 `Suites/iOS/UI/DashboardView.swift`：

新增状态：

```swift
    @State private var selectedTool: ToolDetailItem? = nil
```

在 `toolBars` 的 `ForEach(shown, id: \.name) { tool in` 中，把整行内容用 `Button` 包起来（替换现有 HStack 为可点击版本）：

```swift
            ForEach(shown, id: \.name) { tool in
                Button {
                    selectedTool = matchingToolDetail(for: tool.name)
                } label: {
                    HStack {
                        Text(tool.name).font(.caption).frame(width: 90, alignment: .leading)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3).fill(Color.marsGreenBar)
                                .frame(width: max(geo.size.width * CGFloat(tool.cost / maxCost), 2))
                        }.frame(height: 8)
                        Spacer()
                        Text(usd(tool.cost)).font(.caption2).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
            }
```

新增匹配函数（文件内任意位置）：

```swift
    private func matchingToolDetail(for displayName: String) -> ToolDetailItem? {
        let source: String
        switch displayName {
        case "ChatGPT":      source = "codex"
        case "Claude Code":  source = "claude-code"
        default:             return nil
        }
        return snap.toolDetails.first { $0.source == source }
    }
```

在 `body` 的 `ScrollView` 上追加 sheet 修饰符（`.refreshable` 附近）：

```swift
        .sheet(item: $selectedTool) { detail in
            ToolDetailSheetView(detail: detail)
        }
```

为让 `ToolDetailItem` 满足 `Identifiable`，在 `Suites/Shared/Models/DashboardSnapshot.swift` 的 `ToolDetailItem` 上追加：

```swift
extension ToolDetailItem: Identifiable {
    var id: String { source }
}
```

- [ ] **Step 4: 构建验证 + 提交**

Run: iOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`

```bash
git add Suites/iOS/UI/ToolDetailSheetView.swift Suites/iOS/UI/DashboardView.swift Suites/Shared/I18n/I18n.swift Suites/Shared/Models/DashboardSnapshot.swift
git commit -m "feat: add iOS tool detail sheet with session list and profile cards"
```

---

### Task 6: iOS footer 显示格式

**Files:**
- Modify: `Suites/iOS/UI/DashboardView.swift`

**Interfaces:**
- Consumes: `Bundle.main`、`CKSchema.payloadVersion`
- Produces: iOS 仪表盘底部显示 `AI Pulse v1.2.5/CloudKit 1.2.4`

- [ ] **Step 1: 修改 footer**

把：

```swift
                HStack(spacing: 6) {
                    Text("CloudKit \(CKSchema.payloadVersion)")
                        .font(.caption2).foregroundColor(.secondary)
```

替换为：

```swift
                HStack(spacing: 6) {
                    Text("AI Pulse v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")/CloudKit \(CKSchema.payloadVersion)")
                        .font(.caption2).foregroundColor(.secondary)
```

- [ ] **Step 2: 构建验证 + 提交**

Run: iOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`

```bash
git add Suites/iOS/UI/DashboardView.swift
git commit -m "feat: show app + CloudKit version pair in iOS dashboard footer"
```

---

### Task 7: 全量验证

**Files:** 无代码改动

- [ ] **Step 1: macOS 测试**

Run: `swift test --scratch-path /tmp/ai-pulse-spm --cache-path /tmp/ai-pulse-spm-cache --config-path /tmp/ai-pulse-spm-config`
Expected: 全部通过（127）

- [ ] **Step 2: macOS 构建**

Run: macOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: iOS 构建**

Run: iOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 核对工作区**

Run: `git -C /Users/xingyuwang/develop/ai-pulse-macos status --short`
Expected: 仅含本计划改动 + 用户既有未提交文件（两个 pbxproj、Localizable.xcstrings、两个 xcuserdata）
