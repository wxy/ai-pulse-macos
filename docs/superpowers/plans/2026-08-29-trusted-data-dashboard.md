# 可信数据仪表盘（macOS 落地）Implementation Plan

> **For agentic workers:** 由主代理在当前会话内顺序执行（用户已禁用子代理模式）。
> 步骤使用 checkbox（`- [ ]`）语法跟踪。

**Goal:** 在 macOS 端落地"事实优先、来源可溯"的仪表盘：数据层加入
工具/模型/仓库 Token 用量、可归因金额、订阅周期与有效单价数据（全 Optional），
机器人脸 UI 按新规则重排，估算数据以"？"标记。

**Architecture:** 数据由 macOS `StatsService` 单一组装进 DashboardSnapshot，
客户端只呈现；新字段全 Optional，不 bump `payloadVersion`；UI 保持机器人脸布局，
按"用量/支出/产出/工具/身体"重排语义。

**Tech Stack:** Swift / SwiftUI / Charts / GRDB / XCTest

**Spec:** `docs/superpowers/specs/2026-08-29-trusted-data-dashboard-design.md`

## Global Constraints

- 工作基于新分支 `codex/trusted-data-dashboard`（从 main 创建），不触碰已发布的 1.2.7 线。
- 所有 DashboardSnapshot 新字段必须 Optional/带默认值，不 bump `payloadVersion`。
- 不估算就不估算：无法归因的金额不进 UI；估算一律"？"标记。
- 本轮只改 macOS（AIPulseShared + Sources）；Suites（iOS/watchOS/Widget）不改 UI，
  但编译必须不因新字段破坏。
- 每次提交编译通过、相关测试通过。

---

### Task 1: AIPulseShared 数据模型扩展

**Files:**
- Modify: `Packages/AIPulseShared/Sources/AIPulseShared/Models/DashboardSnapshot.swift`
- Test: `Tests/SnapshotSanitizeTests.swift`

**Interfaces:**
- Produces: `ModelCostItem`、`RateSeriesItem`、`RatePoint`（public Codable Sendable）；
  `DashboardSnapshot.modelBreakdown/rateSeries/subscriptionStart/subscriptionPeriodDays`；
  `ProviderItem.sourceKind`、`NameCostItem.tokens`、`RepoItem.tokens`；
  `sanitized()` 覆盖全部新字段。

- [ ] **Step 1: 写失败测试**（SnapshotSanitizeTests 增加新字段消毒断言）

```swift
func testSanitizesNewTrustedDataFields() {
    var snap = DashboardSnapshot()
    snap.modelBreakdown = [ModelCostItem(model: "m", providerId: "p",
        tokens: -5, calls: -2, cost: .nan, costIsEstimate: nil)]
    snap.rateSeries = [RateSeriesItem(toolId: "t", label: "T",
        points: [RatePoint(ts: .nan, tokens: -1, cost: -.infinity)])]
    snap.subscriptionStart = Date()
    snap.subscriptionPeriodDays = -30
    snap.toolBreakdown = [NameCostItem(name: "n", cost: 1, tokens: -7)]
    snap.topRepos = [RepoItem(name: "r", cost: 1, added: 1, deleted: 1, cpl: 1, tokens: -3)]
    snap.providerBreakdown = [ProviderItem(providerId: "p", name: "P", cost: 1, sourceKind: "balance")]

    let clean = snap.sanitized()

    XCTAssertEqual(clean.modelBreakdown[0].tokens, 0)
    XCTAssertEqual(clean.modelBreakdown[0].calls, 0)
    XCTAssertEqual(clean.modelBreakdown[0].cost ?? -1, 0)
    XCTAssertEqual(clean.rateSeries[0].points[0].ts, 0)
    XCTAssertEqual(clean.rateSeries[0].points[0].tokens, 0)
    XCTAssertEqual(clean.rateSeries[0].points[0].cost, 0)
    XCTAssertEqual(clean.subscriptionPeriodDays, 30)
    XCTAssertEqual(clean.toolBreakdown[0].tokens, 0)
    XCTAssertEqual(clean.topRepos[0].tokens, 0)
    XCTAssertEqual(clean.providerBreakdown[0].sourceKind, "balance")
}
```

- [ ] **Step 2: 运行测试确认失败**（新字段/init 参数缺失导致编译错误）
- [ ] **Step 3: 实现**：新增三个 public 结构；给 ProviderItem/NameCostItem/RepoItem
  增加带默认值 `nil` 的字段与 init 参数；DashboardSnapshot 加新字段；
  `sanitized()` 对 tokens/calls/cost/ts/periodDays 做非负/有限处理
  （periodDays 非法时回退 30）。
- [ ] **Step 4: 运行测试确认通过**
- [ ] **Step 5: 提交** `feat: add trusted-data fields to dashboard snapshot`

---

### Task 2: StatsService 计算层（聚合 / 归因 / 订阅周期）

**Files:**
- Modify: `Sources/Store/StatsService.swift`
- Test: `Tests/StatsServiceTests.swift`

**Interfaces:**
- Produces: 纯函数 `modelBreakdown(rows:)`、`exclusiveProviders(usageByTool:)`、
  `subscriptionProgress(start:periodDays:now:)`；dashboardSnapshot 组装
  `modelBreakdown/rateSeries/sourceKind/subscriptionStart/periodDays/topRepos.tokens`。

- [ ] **Step 1: 写失败测试**

```swift
func testModelBreakdownSanitizesRows() {
    let rows = [
        (model: "deepseek-v4-pro", providerId: "deepseek", tokens: Int64(860_000), calls: 92, cost: 1.2),
        (model: "bad", providerId: "deepseek", tokens: -1, calls: 0, cost: .nan),
    ]
    let items = StatsService.modelBreakdown(rows: rows)
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items[0].tokens, 860_000)
    XCTAssertEqual(items[1].tokens, 0)
    XCTAssertEqual(items[1].cost ?? -1, 0)
}

func testExclusiveProvidersOnlyWhenSingleTool() {
    let usage: [String: Set<String>] = [
        "claude-code": ["deepseek"],
        "chatgpt": ["openai"],
        "api": ["deepseek"],   // deepseek 被两个工具引用 → 非独占
    ]
    XCTAssertEqual(StatsService.exclusiveProviders(usageByTool: usage), ["openai"])
}

func testSubscriptionProgress() {
    let cal = Calendar.current
    let start = cal.date(byAdding: .day, value: -15, to: cal.startOfDay(for: Date()))!
    let p = StatsService.subscriptionProgress(start: start, periodDays: 30, now: Date())
    XCTAssertEqual(p.elapsedDays, 15)
    XCTAssertEqual(p.totalDays, 30)
    XCTAssertNotNil(p.nextReset)
}
```

- [ ] **Step 2: 运行确认失败**（函数不存在）
- [ ] **Step 3: 实现**
  - `modelBreakdown(rows:)`：sanitize tokens/calls/cost，cost 非有限 → nil。
  - `exclusiveProviders(usageByTool:)`：provider 出现在且仅出现在一个 tool 的集合中。
  - `subscriptionProgress(start:periodDays:now:)`：elapsed=clamp(0...total)，nextReset=start+total。
  - `dashboardSnapshot` 内：
    1. 新增按 model 聚合 SQL（`GROUP BY model` → tokens/calls/cost_source_id）；
    2. 按 source 聚合 token + 对应 cost_source_id 集合 → 独占判定；
    3. 按 repo_path 聚合 token 填 `topRepos[].tokens`；
    4. 对每个独占 (tool, provider)：balanceDailySpend 按 provider 的每日差值 +
       usage_event 按 tool 的每日 token，组装 RateSeriesItem；
    5. 从 UserDefaults 读 `subscription_start` / `subscription_period_days` 填入快照。
- [ ] **Step 4: 运行测试**
- [ ] **Step 5: 提交** `feat: assemble trusted usage, attribution and subscription data`

---

### Task 3: DashboardView 头部重排（额头 / 双眼 / 鼻子）

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardView.swift`

**Interfaces:**
- Consumes: `snap.todayTokens/todayCalls`、`providerBreakdown[].sourceKind/cost`、
  `topRepos`、`codeChanges`、`subscriptionStart/PeriodDays/subDaily`。

- [ ] **Step 1: 实现头部**
  - 额头：当前范围 Token 总量大数字 + `calls · sessions` 副行，角标 `来源：日志`。
  - 左眼：眉标签 `实际支出 $X · +订阅 $Y/月`；donut 按供应商余额差值
    （`sourceKind == "balance"` 实心，`usage` 描边扇区只计 token 占比不显示金额）。
  - 右眼：眉标签 `代码产出 +A/-D`；donut 按仓库净行占比，中心总净行。
  - 鼻子：+A / -D / 净增 三个 stat card。
  - 删除旧的混合大金额、订阅-vs-API donut、按供应商金额 donut、CPL 卡。
- [ ] **Step 2: `swift build` + 现有测试通过**
- [ ] **Step 3: 提交** `feat: rework dashboard head to usage/expense/output`

---

### Task 4: 嘴（工具）与模型区块

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardView.swift`

- [ ] **Step 1: 实现工具行**：`name · T tokens · N calls`；独占余额工具追加
  `$X`（实心事实）；共享工具不显示金额；行尾展开该工具模型明细。
- [ ] **Step 2: 实现模型区块**：`modelBreakdown` 列表，
  `model · T tokens · N calls`，可归因时显示金额；costIsEstimate 为 true 时
  金额旁加灰字"？"；空数据显示"等待 macOS 更新"占位。
- [ ] **Step 3: `swift build` + 测试**
- [ ] **Step 4: 提交** `feat: tool rows show tokens and model breakdown`

---

### Task 5: 身体（仓库 / 趋势 / 余额 / 有效单价图）

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardView.swift`

- [ ] **Step 1: 仓库列表**：每行 `repo · +A/-D · T tokens`（移除估算费用与 CPL）。
- [ ] **Step 2: 趋势图（本周/30日）**：逐日余额差值柱 + 净行线 + token 线（右轴）；
  移除订阅曲线；图例注明来源。
- [ ] **Step 3: 今日余额列表**：供应商最新余额 + 配额 + 订阅进度
  `Claude Pro $20/月 · 已过 15/30 天 · 9/13 重置`（用 subscriptionProgress 结果）。
- [ ] **Step 4: 有效单价图**：`rateSeries` 折线（X=时间，Y=$/M tokens）；
  无 rateSeries 时显示"余额来源不可归因，无法绘制"文字说明。
- [ ] **Step 5: `swift build` + 测试**
- [ ] **Step 6: 提交** `feat: repos, trend, balance and effective-rate charts`

---

### Task 6: 设置页订阅周期输入

**Files:**
- Modify: `Sources/UI/Settings/SettingsView.swift`

- [ ] **Step 1: 实现**：订阅区块加周期选择（30/90/365 天）与开始日期 DatePicker，
  写入 UserDefaults `subscription_start` / `subscription_period_days`。
- [ ] **Step 2: `swift build`**
- [ ] **Step 3: 提交** `feat: subscription cycle start input in settings`

---

### Task 7: 全量验证与交接

- [ ] `make test` 全量通过
- [ ] `git diff --check` 通过
- [ ] Suites 三端 `swift build` 不受影响（xcodebuild AIPulseShared 目标）
- [ ] 交由用户运行验证：三视图、余额、模型区块、有效单价图、订阅周期
