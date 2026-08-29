# 数据与图表防御性加固 Implementation Plan

> **For agentic workers:** 本任务由主代理在当前会话内顺序执行（用户已禁用子代理模式）。步骤使用 checkbox（`- [ ]`）语法跟踪。

**Goal:** 全面审计 AI Pulse macOS 数据管道与图表渲染代码，修复已发现的数值/除零/强制解包缺陷，使应用在任何异常数据下不崩溃、不无响应。

**Architecture:** 分层防御：数据入口（API 解析）→ 统计计算（除零/溢出）→ 渲染边界（NaN/Inf/负值）→ 快照进入 UI 前统一消毒 → 消除强制解包。每个修复带单元测试。

**Tech Stack:** Swift / SwiftUI Charts / GRDB / XCTest

**Spec:** 用户要求：全面审计数据和图表相关代码，找到可能缺陷点并做防御性工作；错误数据尽量修复；目标是不崩溃、不无响应。

## Global Constraints

- 不引入新依赖，不改动 iOS/Shared 行为（sanitize 放 macOS target）。
- 保留现有测试全部通过（当前 151 tests）。
- 每次提交保持编译通过、相关测试通过。
- 不记录 API key / prompt / 文件内容到诊断日志（沿用现有约束）。

---

### Task 1: 数据入口数值消毒（ApiPoller + UsageMonitor）

**Files:**
- Modify: `Sources/Ingest/ApiPoller.swift`（`parseDouble`、`cacheBalance`）
- Modify: `Sources/Engine/UsageMonitor.swift`（utilization clamp）
- Test: `Tests/ApiPollerTests.swift`（新增）、`Tests/UsageMonitorTests.swift`

**Interfaces:**
- Produces: `ApiPoller.parseDouble(_ value: Any?) -> Double?` 变为 `internal static`，非有限值返回 nil。

- [ ] **Step 1: 写失败测试**

```swift
func testParseDoubleRejectsNonFiniteStrings() {
    XCTAssertNil(ApiPoller.parseDouble("nan"))
    XCTAssertNil(ApiPoller.parseDouble("inf"))
    XCTAssertNil(ApiPoller.parseDouble("-inf"))
    XCTAssertEqual(ApiPoller.parseDouble("12.5") ?? -1, 12.5)
    XCTAssertNil(ApiPoller.parseDouble("not-a-number"))
}
```

- [ ] **Step 2: 运行测试确认失败（编译错误）**
- [ ] **Step 3: 实现**：`parseDouble` 增加 `isFinite` 过滤；`cacheBalance` 写库/写缓存前 `filter { $0.totalBalance.isFinite }`；UsageMonitor 写入 DB 前将 utilization clamp 到 0...100。
- [ ] **Step 4: 运行测试确认通过**
- [ ] **Step 5: 提交** `fix: sanitize balance parsing and quota utilization at ingestion`

---

### Task 2: 统计计算防 Inf/溢出（StatsService + SessionStats + PricingManager）

**Files:**
- Modify: `Sources/Store/StatsService.swift`（`dashboardSnapshot.repoScale`）
- Modify: `Sources/Store/SessionStats.swift`（`deltaPct`、`projectMonth`、`metrics`）
- Modify: `Sources/Ingest/PricingCatalog.swift`（`costUSD` token 减法）
- Test: `Tests/SessionStatsTests.swift`、`Tests/PricingCatalogTests.swift`

**Interfaces:**
- Produces: `SessionStats.deltaPct(current:previous:)` 对非有限输入返回 0；`projectMonth` 同；`metrics` 用 Double 乘法。

- [ ] **Step 1: 写失败测试**（deltaPct NaN/Inf → 0；metrics 大 window 不溢出；costUSD cacheTokens > inTokens 不 trap）
- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现**
  - `repoScale = toolTotal > 0 && logTotal > 0 ? apiSpend / logTotal : 1.0`
  - `scaledCost` 结果非有限 → 0
  - `deltaPct` / `projectMonth` guard `isFinite`
  - `metrics`：`Double(turns.count) * Double(window)`
  - `costUSD`：`let nonCachedIn = inTokens > cacheTokens ? inTokens - cacheTokens : 0`
- [ ] **Step 4: 运行测试**
- [ ] **Step 5: 提交** `fix: guard division and overflow in stats and pricing math`

---

### Task 3: 渲染边界辅助函数（ChartMath + DashboardView）

**Files:**
- Modify: `Sources/Utils/ChartMath.swift`（新增 `ratio`、`percentageDelta`、`unit`）
- Modify: `Sources/UI/Dashboard/DashboardView.swift`（`toolBarRow`、`outputSection`、`comparisonBadge`、`usageBarView`、`conclusionCard`、`deltaBadge`、`crossText`）
- Test: `Tests/ChartMathTests.swift`

**Interfaces:**
- Produces: `ChartMath.ratio(_:denominator:fallback:) -> Double`（有限、分母>0 才除）；`percentageDelta(current:previous:fallback:) -> Double`；`unit(_:) -> Double`（clamp 0...1，非有限→0）。

- [ ] **Step 1: 写失败测试**（ratio NaN/负/除零；percentageDelta NaN；unit NaN/越界）
- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现** ChartMath 三个方法
- [ ] **Step 4: DashboardView 接入**：所有比例/百分比/进度计算走 ChartMath；`usageBarView` guard 有限
- [ ] **Step 5: 运行测试**
- [ ] **Step 6: 提交** `fix: sanitize dashboard ratios, percentages and progress at render boundary`

---

### Task 4: ToolDetailOverlayView 图表防御

**Files:**
- Modify: `Sources/UI/Dashboard/ToolDetailOverlayView.swift`（`occupancyBar`、`contextChart`）

- [ ] **Step 1: 实现**：`occupancyBar` 用 `ChartMath.unit`；AreaMark/LineMark 用 `ChartMath.barValue` 非负化
- [ ] **Step 2: 编译 + 现有测试**
- [ ] **Step 3: 提交** `fix: clamp occupancy and sanitize context trend chart values`

---

### Task 5: 消除日期强制解包

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardView.swift`（`TimeRange.days`、`chartStart`、`rangeSinceMs`、`forceRefresh`）
- Modify: `Sources/Utils/Calendar+Extensions.swift`（`mondayOfWeek`）
- Modify: `Sources/UI/Dashboard/DemoData.swift`
- Modify: `Sources/Engine/DataRefreshCoordinator.swift`
- Modify: `Sources/UI/MenuBar/MenuBarController.swift`
- Modify: `Sources/Store/StatsService.swift`
- Modify: `Sources/Engine/AnomalyDetector.swift`
- Test: `Tests/CalendarTests.swift`（新增 mondayOfWeek 始终返回有效日期）

- [ ] **Step 1: 写测试**：mondayOfWeek 对任意日期非崩溃且返回周一
- [ ] **Step 2: 实现**：所有 `date(byAdding:)!` / `.day!` 替换为 guard + 安全 fallback
- [ ] **Step 3: 编译 + 测试**
- [ ] **Step 4: 提交** `fix: remove force-unwrapped date math from data and chart paths`

---

### Task 6: 快照进入 UI 前统一消毒

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardView.swift`（新增 `sanitizedSnapshot` 静态方法，`applySnapshot` 与 cache 读取路径接入）
- Test: `Tests/ChartMathTests.swift`（或新建 `Tests/SnapshotSanitizeTests.swift`）

- [ ] **Step 1: 写失败测试**：构造含 NaN/Inf/负值的 DashboardSnapshot，sanitize 后全为有限非负，正常值不变
- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现** sanitize（Double 非有限/负 → 0；Int64/Int 负 → 0；TrendPoint.ts 非有限 → 0），在 `applySnapshot` 入口调用
- [ ] **Step 4: 运行测试**
- [ ] **Step 5: 提交** `fix: sanitize dashboard snapshots before they reach SwiftUI state`

---

### Task 7: 全量验证与交接

- [ ] `make test` 全量通过（151+ 新测试）
- [ ] `git diff --check` 通过
- [ ] 构建最新版本，交由用户运行验证 Today/本周/30 日
- [ ] 汇总审计发现与修复清单
