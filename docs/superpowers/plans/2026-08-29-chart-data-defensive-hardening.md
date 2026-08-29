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

- [x] **Step 1: 写失败测试**

```swift
func testParseDoubleRejectsNonFiniteStrings() {
    XCTAssertNil(ApiPoller.parseDouble("nan"))
    XCTAssertNil(ApiPoller.parseDouble("inf"))
    XCTAssertNil(ApiPoller.parseDouble("-inf"))
    XCTAssertEqual(ApiPoller.parseDouble("12.5") ?? -1, 12.5)
    XCTAssertNil(ApiPoller.parseDouble("not-a-number"))
}
```

- [x] **Step 2: 运行测试确认失败（编译错误）**
- [x] **Step 3: 实现**：`parseDouble` 增加 `isFinite` 过滤；`cacheBalance` 写库/写缓存前 `filter { $0.totalBalance.isFinite }`；UsageMonitor 写入 DB 前将 utilization clamp 到 0...100。
- [x] **Step 4: 运行测试确认通过**
- [x] **Step 5: 提交** `fix: sanitize balance parsing and quota utilization at ingestion`

---

### Task 2: 统计计算防 Inf/溢出（StatsService + SessionStats + PricingManager）

**Files:**
- Modify: `Sources/Store/StatsService.swift`（`dashboardSnapshot.repoScale`）
- Modify: `Sources/Store/SessionStats.swift`（`deltaPct`、`projectMonth`、`metrics`）
- Modify: `Sources/Ingest/PricingCatalog.swift`（`costUSD` token 减法）
- Test: `Tests/SessionStatsTests.swift`、`Tests/PricingCatalogTests.swift`

**Interfaces:**
- Produces: `SessionStats.deltaPct(current:previous:)` 对非有限输入返回 0；`projectMonth` 同；`metrics` 用 Double 乘法。

- [x] **Step 1: 写失败测试**（deltaPct NaN/Inf → 0；metrics 大 window 不溢出；costUSD cacheTokens > inTokens 不 trap）
- [x] **Step 2: 运行确认失败**
- [x] **Step 3: 实现**
  - `repoScale = toolTotal > 0 && logTotal > 0 ? apiSpend / logTotal : 1.0`
  - `scaledCost` 结果非有限 → 0
  - `deltaPct` / `projectMonth` guard `isFinite`
  - `metrics`：`Double(turns.count) * Double(window)`
  - `costUSD`：`let nonCachedIn = inTokens > cacheTokens ? inTokens - cacheTokens : 0`
- [x] **Step 4: 运行测试**
- [x] **Step 5: 提交** `fix: guard division and overflow in stats and pricing math`

---

### Task 3: 渲染边界辅助函数（ChartMath + DashboardView）

**Files:**
- Modify: `Sources/Utils/ChartMath.swift`（新增 `ratio`、`percentageDelta`、`unit`）
- Modify: `Sources/UI/Dashboard/DashboardView.swift`（`toolBarRow`、`outputSection`、`comparisonBadge`、`usageBarView`、`conclusionCard`、`deltaBadge`、`crossText`）
- Test: `Tests/ChartMathTests.swift`

**Interfaces:**
- Produces: `ChartMath.ratio(_:denominator:fallback:) -> Double`（有限、分母>0 才除）；`percentageDelta(current:previous:fallback:) -> Double`；`unit(_:) -> Double`（clamp 0...1，非有限→0）。

- [x] **Step 1: 写失败测试**（ratio NaN/负/除零；percentageDelta NaN；unit NaN/越界）
- [x] **Step 2: 运行确认失败**
- [x] **Step 3: 实现** ChartMath 三个方法
- [x] **Step 4: DashboardView 接入**：所有比例/百分比/进度计算走 ChartMath；`usageBarView` guard 有限
- [x] **Step 5: 运行测试**
- [x] **Step 6: 提交** `fix: sanitize dashboard ratios, percentages and progress at render boundary`

---

### Task 4: ToolDetailOverlayView 图表防御

**Files:**
- Modify: `Sources/UI/Dashboard/ToolDetailOverlayView.swift`（`occupancyBar`、`contextChart`）

- [x] **Step 1: 实现**：`occupancyBar` 用 `ChartMath.unit`；AreaMark/LineMark 用 `ChartMath.barValue` 非负化
- [x] **Step 2: 编译 + 现有测试**
- [x] **Step 3: 提交** `fix: clamp occupancy and sanitize context trend chart values`

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

- [x] **Step 1: 写测试**：mondayOfWeek 对任意日期非崩溃且返回周一
- [x] **Step 2: 实现**：所有 `date(byAdding:)!` / `.day!` 替换为 guard + 安全 fallback
- [x] **Step 3: 编译 + 测试**
- [x] **Step 4: 提交** `fix: remove force-unwrapped date math from data and chart paths`

---

### Task 6: 快照进入 UI 前统一消毒

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardView.swift`（新增 `sanitizedSnapshot` 静态方法，`applySnapshot` 与 cache 读取路径接入）
- Test: `Tests/ChartMathTests.swift`（或新建 `Tests/SnapshotSanitizeTests.swift`）

- [x] **Step 1: 写失败测试**：构造含 NaN/Inf/负值的 DashboardSnapshot，sanitize 后全为有限非负，正常值不变
- [x] **Step 2: 运行确认失败**
- [x] **Step 3: 实现** sanitize（Double 非有限/负 → 0；Int64/Int 负 → 0；TrendPoint.ts 非有限 → 0），在 `applySnapshot` 入口调用
- [x] **Step 4: 运行测试**
- [x] **Step 5: 提交** `fix: sanitize dashboard snapshots before they reach SwiftUI state`

---

### Task 7: 全量验证与交接

- [x] `make test` 全量通过（151+ 新测试）
- [x] `git diff --check` 通过
- [x] 构建最新版本，交由用户运行验证 Today/本周/30 日
- [x] 汇总审计发现与修复清单

---

# Phase 2: CloudKit 写端与 iOS/watchOS/Widget 客户端防御

**Goal:** 保证写入 CloudKit / 本地缓存的数据安全可靠，并让 iOS、watchOS、Widget
在消费快照时具备与 macOS 同等的防御，避免旧毒数据导致客户端崩溃或无响应。

### Task 8: 防御能力下沉到 AIPulseShared

- [ ] 将 `ChartMath` 迁移至 `Packages/AIPulseShared/Sources/AIPulseShared/ChartMath.swift`（public），删除 macOS 本地副本
- [ ] `DashboardSnapshot` 增加 `public func sanitized()`（迁移 macOS sanitizedSnapshot 逻辑）
- [ ] `ActivityRing` 对非有限 progress 防御（trim 不能收到 NaN）
- [ ] 迁移/新增 macOS 测试覆盖共享方法，`make test` 通过
- [ ] 提交 `feat: move chart math and snapshot sanitization into AIPulseShared`

### Task 9: macOS 写端保证 CloudKit 数据干净

- [ ] `StatsService.dashboardSnapshot()` 返回前调用 `sanitized()`
- [ ] `DashboardView.applySnapshot` 改用 `sanitized()`（保留原始 all_finite 日志）
- [ ] `make test` 通过，提交 `fix: sanitize snapshots at the source before cache/CloudKit writes`

### Task 10: iOS 客户端防御

- [ ] `CloudDataService` 所有解码路径（hasData/fetchAndStore/loadLocalCache）接入 `sanitized()`
- [ ] `DashboardView` donut 过滤非法段、tool/repo 比例与对比徽章用 ChartMath、trend 图加 X 域与 barValue、消除强制解包
- [ ] `ToolDetailSheetView` occupancy 与 delta 防御
- [ ] `xcodebuild` iOS simulator 编译通过，提交 `fix: harden iOS dashboard against poisoned snapshots`

### Task 11: watchOS + Widget 防御

- [ ] watchOS `SpendView` 比例/徽章用 ChartMath（safeInt/unit/percentageDelta）
- [ ] Widget `loadLatestEntry` 解码后 sanitize，`WidgetViews` 同样接入
- [ ] `xcodebuild` watchOS/widget simulator 编译通过，提交

### Task 12: 全量验证

- [ ] macOS `make test` 全量通过
- [ ] iOS/watchOS/Widget 三个 scheme 编译通过
- [ ] 汇总写端 + 三端防御说明
