# 可信数据仪表盘设计（Trusted Data Dashboard）

> 状态：设计定稿，等待实施计划。本轮范围：macOS 端数据层 + 仪表盘落地；
> iOS / watchOS / Widget 在后续版本跟进（数据字段已为三端预留）。

## 1. 背景与目标

AI 供应商计费策略复杂且多变（定价变化、分时段计价、促销、临时重置），
导致"订阅日均摊销"和"token × 目录单价"两类计算误差大，应用呈现的
金额与用户真实账单偏差明显，动摇应用可信度。

产品重新定位：**应用的意义不是精确记账，而是可信的归因与洞察**——
告诉用户钱花在哪、干了多少活、值不值得。因此确立核心原则：

> 事实归事实，估算归估算，取不到的数据承认边界、不假装知道。

### 1.1 目标

- 所有展示数据可追溯出处（余额 API / JSONL 日志 / Git / 用户输入）。
- 确定数据（余额差值、订阅周期成本、Token 用量、Git 产出）为主视觉。
- 非确定数据（估算金额、细粒度归因金额）只作辅助，带"？"标记。
- 不估算就不估算：工具/模型/仓库级金额无法归因时，只显示用量与产出。
- 保持机器人脸 UI 模式，数据语义按新规则重排。

## 2. 数据真实性与确定性规则

| 数据 | 粒度 | 出处 | 确定性 |
|---|---|---|---|
| 金额 | 供应商级 | 余额 API 差值 | 事实 |
| 金额 | 工具/模型/仓库级 | 需按 token 比例分摊余额差值 | 估算（标"？"） |
| 金额 | 工具级（独占余额来源） | 供应商余额差值可归因 | 事实 |
| 用量 Token | 任意粒度 | JSONL 日志 | 事实 |
| 产出 | 仓库级 | Git 变化 | 事实 |
| 产出 | 工具级 | 多工具共享仓库时不可拆分 | 估算（不展示金额/行数拆分） |
| 订阅 | 周期级 | 用户输入（周期 + 开始日） | 事实 |

**归因规则**：只有"余额来源可归因（该余额 provider 仅被一个工具/模型消费）"
的工具/模型才允许展示细粒度金额；共享余额来源的模糊地带不绘制金额，
只用文字说明。

## 3. 机器人脸布局（定稿）

```
                 ┌──────────────────────────┐
                 │   Token 用量（大数字）      │  ← 额头：用量
                 │   1,240 calls · 8 sessions │
                 └──────────────────────────┘
      左眼（眉：实际支出 $X · +订阅 $Y/月）   右眼（眉：代码产出 +A/-D）
      donut：按供应商余额差值               donut：按仓库净行占比
              ┌────────────────────┐
              │  +A 增加 / -D 删除  │  ← 鼻子：代码增减、净增行
              │  净 +N              │
              └────────────────────┘
     ┌──────────────────────────────────┐
     │  嘴：按工具（每行 Token · calls）   │  ← 工具；独占余额时追加金额
     │  展开：该工具模型明细（BYOK）       │
     └──────────────────────────────────┘
     ┌──────────────────────────────────┐
     │  身体：仓库列表（行数 · Token）      │
     │  趋势图 / 今日余额列表             │
     │  有效单价 × 时间图                 │
     └──────────────────────────────────┘
```

### 3.1 估算标记

估算数据统一使用灰色 **"？"** 标记（非"估"字），置于数值旁；事实数据无标记，
区块角标注明来源：`日志` / `余额 API` / `Git` / `用户输入`。

## 4. 数据模型扩展（全部 Optional，不 bump payloadVersion）

### 4.1 DashboardSnapshot 新增字段

| 字段 | 类型 | 内容 | 对应 UI |
|---|---|---|---|
| `providerBreakdown[].sourceKind` | String? | `balance` / `usage` / `estimated` | donut 实心/描边扇区 |
| `toolBreakdown[].tokens` | Int64? | 工具 Token 总量 | 嘴（工具条）主数字 |
| `modelBreakdown` | [ModelCostItem]? | 按模型：model/provider/tokens/cost | 按模型区块 |
| `topRepos[].tokens` | Int64? | 仓库 Token 总量 | 身体仓库列表 |
| `rateSeries` | [RateSeriesItem]? | 可归因三元组逐日数据 | 有效单价图 |
| `subscriptionStart` | Date? | 订阅周期开始日（用户输入） | 订阅进度 |
| `subscriptionPeriodDays` | Int? | 周期长度（30/90/365） | 订阅进度 |

### 4.2 新结构

```swift
struct ModelCostItem: Codable, Sendable {
    var model: String
    var providerId: String
    var tokens: Int64
    var calls: Int
    var cost: Double?          // 仅可归因时非 nil
    var costIsEstimate: Bool?  // true 时 UI 标"？"
}

struct RateSeriesItem: Codable, Sendable {
    var toolId: String
    var label: String
    var points: [RatePoint]
}

struct RatePoint: Codable, Sendable {
    var ts: Double        // 日起点
    var tokens: Int64     // 当日日志 token（事实）
    var cost: Double      // 当日余额差值（事实，仅可归因系列）
}
```

### 4.3 兼容性

- 全部新字段 Optional/数组默认空 → 旧客户端解码忽略，新客户端读旧快照优雅降级。
- `payloadVersion` 不变；旧 macOS 写出的快照在新客户端中，
  `modelBreakdown` / `rateSeries` 为空，对应区块显示"等待 macOS 更新"。

## 5. macOS 计算规则（StatsService 组装）

1. **Token 聚合**：按 `source`、`model`、`repo_path` 从 usage_event 聚合
   （含 calls 计数）；纯日志事实。
2. **独占性判定**：按 `cost_source_id` 分组，余额 provider 仅被一个工具引用
   时，该 provider 的每日余额差值并入对应工具/模型的 RatePoint；
   否则该工具/模型不产出金额与 rateSeries。
3. **订阅周期**：由 `subscriptionStart` + `subscriptionPeriodDays` 计算
   "已过 N/30 天 · 下次重置日期"；金额保持周期总额，不摊销到天/会话。
4. **供应商 sourceKind**：有余额 API 且取到值 → `balance`；usage 型 → `usage`；
   仅日志无余额 → `estimated`（此时允许 token×单价估算并标"？"）。
5. **顶部大数字**：`todayCalls`/`todayTokens` 等按当前时间范围聚合。

## 6. 本地输入

macOS 设置页新增"订阅周期"输入：套餐选择 + 周期开始日期（DatePicker），
存 UserDefaults（`subscription_start` / `subscription_period_days`），
随快照同步到 iOS/watchOS 只读展示。

## 7. 本轮范围（macOS 落地）

- `Packages/AIPulseShared`：新增 ModelCostItem / RateSeriesItem / RatePoint，
  DashboardSnapshot 加 Optional 字段；sanitized() 覆盖新字段。
- `Sources/Store/StatsService.swift`：token 聚合、独占性判定、rateSeries 组装、
  订阅周期计算、sourceKind 填充。
- `Sources/UI/Dashboard/DashboardView.swift`：机器人脸重排（额头/双眼/鼻子/
  嘴/身体），移除估算金额与 CPL 主展示，新增模型区块、余额列表、有效单价图。
- `Sources/UI/Settings/SettingsView.swift`：订阅周期输入。
- 测试：新增聚合/归因/周期计算的单元测试；快照 sanitize 覆盖新字段。

**不在本轮**：iOS / watchOS / Widget 的 UI 调整（字段已预留）；
趋势图交互增强；有效单价图交互。

## 8. 验证

- macOS `make test` 全量通过。
- 用户运行验证：今日/本周/30 日三视图、余额列表、模型区块、有效单价图、
  订阅周期显示。
- 三端编译保持通过（iOS/watchOS/Widget 源码不因新字段破坏）。
