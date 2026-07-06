# 实施方案：A/B/C 三级模型重构为 CostSource 两层模型

## 背景

当前 A/B/C 分级模型将"数据采集方式"和"计费方式"两个正交维度混为一谈，导致：

- **Claude Code + 套餐用户**：日志中有 token → A 级按 API 单价算出虚构花费
- **Cursor + 用户自己的 API Key**：检测到 Cursor → C 级只算订阅费，漏掉 API 余额花费
- **aider + DeepSeek Key**：A 级 token 定价为估算，B 级余额差值为真实花费，可能双重计数
- **同一 repo 多工具协作**：各工具花费混在同一个 CPL 分母里，无法区分来源

同时 GitMonitor 不过滤 commit author，`git pull` 后协作者 commit 被计入用户代码产出。

由于项目处于开发阶段，**不考虑旧数据兼容**：DB schema 直接改 CREATE TABLE 语句，DataGrade 直接删除不标记 deprecated。

## 目标

将硬编码等级模型替换为 **CostSource（计费来源）+ UsageRecord 归属消歧** 两层模型，并修复 commit author 过滤。

---

## Phase 1：Git Commit Author 过滤（独立前置 PR）

**目标**：只统计当前用户本机的 commit。与后续重构解耦，可独立合入。

### 1.1 GitRepo.swift

在 `Sources/Engine/GitRepo.swift` 中新增 `userEmail()`，修改 `log()` 签名增加 `authorEmail` 参数，在遍历循环中用 `git_commit_author()` 过滤。

- `userEmail()` 返回 nil 时不过滤（保持旧行为）

### 1.2 GitMonitor.swift

在 `Sources/GitMonitor/GitMonitor.swift` 的 `scanRecentCommits()` 中传入 `authorEmail`。

### 1.3 验证

在有多协作者的 repo 中运行，确认只计入自己的 commit。更新 `GitMonitorTests`。

---

## Phase 2：核心重构（模型 + DB + 数据流 + UI 一体化）

由于无旧数据包袱，所有改动在一个阶段内完成，不等价切换。

### 2.1 设计原则：数据源层级

在定义具体类型之前，先确定 CostSource 之间的层级关系：

```
API Key（余额差值）          ← 最可靠，真实花费
    ↓ 缺 API Key 覆盖的 model
订阅（月费摊销）             ← 次可靠，日均估算
    ↓ 既无 Key 也无订阅
未归属（unattributed）      ← 进油表，不进 CPL
```

**API Key 永远是更可靠的数据源**。如果一个 model 同时被 API Key 和订阅覆盖，API Key 优先。理由：
- API Key 有余额差值 → `.exact`（真实花费）
- 订阅只有月费 ÷ 天数 → `.amortized`（估算）
- 用户配置了 API Key 意味着他们确实在用它

### 2.2 新建 CostSource.swift

```swift
struct CostSource: Identifiable, Equatable, Hashable, Codable {
    let id: String                     // "api-key:deepseek", "sub:cursor:pro"
    let label: String                  // "DeepSeek API Key"
    let kind: CostSourceKind
    var coveredModels: Set<String>     // normalized model names
    var confidence: CostConfidence
    var limitations: [String]          // ["超量未计入", "假设仅用于编程"]
    static let unknownId = "unattributed"
}

enum CostSourceKind: Equatable, Hashable, Codable {
    case apiKey(providerId: String)
    case subscription(toolId: String, tierLabel: String, monthlyFee: Double)
    case unknown
}

enum CostConfidence: String, Codable, Comparable {
    case exact, estimated, amortized, uncertain, incomplete
}
```

**`Sources/Engine/Arbitrator.swift`** — 消歧引擎：

```swift
enum Arbitrator {
    static func resolve(
        model: String?,
        source toolId: String,
        costSources: [CostSource],
        preferredAPIKeyId: String?  // 来自 IntegrationConfig.preferredAPIKeyCostSourceId
    ) -> (costSourceId: String, confidence: CostConfidence) {

        guard let model, !model.isEmpty else {
            return (CostSource.unknownId, .incomplete)
        }

        let normalized = PricingManager.normalize(model)
        let matching = costSources.filter { cs in
            cs.coveredModels.contains { covered in
                normalized.hasPrefix(covered) || covered.hasPrefix(normalized)
            }
        }

        if matching.isEmpty {
            return (CostSource.unknownId, .incomplete)
        }

        // 1. 优先匹配用户指定的 API Key（来自 Settings 下拉选择）
        if let preferred = preferredAPIKeyId,
           let match = matching.first(where: { $0.id == preferred }) {
            return (match.id, match.confidence)
        }

        // 2. apiKey 优先于 subscription（余额差值更可靠）
        let apiKeys = matching.filter { if case .apiKey = $0.kind { return true }; return false }
        let subs = matching.filter { if case .subscription = $0.kind { return true }; return false }

        if let first = apiKeys.first { return (first.id, first.confidence) }
        if let first = subs.first    { return (first.id, first.confidence) }

        return (matching[0].id, .uncertain)
    }
}
```

**新增特殊 CostSource：Anthropic API Key**

`AnthropicIntegration` 作为第 5 个 apiKey 类型的集成（同 DeepSeek/OpenAI/Kimi/Zhipu）：

```swift
struct AnthropicIntegration: Detectable, Collectable {
    let id = "anthropic"
    let displayName = "Anthropic"
    var costSources: [CostSource] {
        guard ApiKeyManager.shared.get("anthropic") != nil else { return [] }
        return [CostSource(
            id: "api-key:anthropic",
            label: "Anthropic API Key",
            kind: .apiKey(providerId: "anthropic"),
            coveredModels: PricingManager.shared.claudeModels(),
            confidence: .estimated,        // 无余额 API
            limitations: ["无余额 API，按 token × 定价表估算"]
        )]
    }
    func detect() -> DetectionResult { /* 检查 Key 是否配置 */ }
    func start() {}; func stop() {}
}
```

### 2.3 修改 IntegrationProtocols.swift

- **删除** `DataGrade` enum
- 从 `Detectable` 协议**删除** `var grade: DataGrade`，**新增** `var costSources: [CostSource] { get }`
- `Collectable` 协议不变
- `IntegrationConfig` 新增字段：

```swift
struct IntegrationConfig: Codable {
    var enabled: Bool = false
    var apiKey: String = ""
    var subscriptionTier: String = ""
    // 新增：当用户在此 IDE 中使用自己的 API Key 时，
    // 选择已配置的某个 apiKey CostSource 作为优先计费来源。
    // nil 表示不覆盖（subscription 正常生效）
    var preferredAPIKeyCostSourceId: String? = nil
}
```

### 2.4 修改 IntegrationRegistry.swift

- 删除 `enabledAGrade()`、`enabledBGrade()`、`enabledCGrade()`
- 新增 `activeCostSources(editorMappings:) -> [CostSource]` — 遍历所有启用的集成，从各自的 `costSources` 属性收集
- `all` 数组新增 `AnthropicIntegration()`（第 10 个集成）

各集成 `costSources` 的实现逻辑：

| 集成 | 产生的 CostSource | 用量追踪 |
|------|------------------|---------|
| DeepSeek | apiKey(.exact)，覆盖 DeepSeek models | — |
| OpenAI | apiKey(.exact)，覆盖 OpenAI models | — |
| Kimi | apiKey(.exact)，覆盖 Kimi models | — |
| Zhipu | apiKey(.exact)，覆盖 Zhipu models | — |
| **Anthropic**（新增） | apiKey(.estimated)，覆盖 Claude models，limitations: ["无余额 API，按定价表估算"] | — |
| ClaudeCode | subscription(.amortized)，覆盖 Claude models | ✅ Status Cache |
| Aider | 返回 `[]`（它不是计费来源，日志中的 model 通过消歧引擎归入 apiKey CostSource） | — |
| Copilot | subscription(.amortized) | ✅ GitHub API |
| Cursor | subscription(.amortized)，limitations: ["超量费用暂不支持"] | ❌ |
| Windsurf | subscription(.amortized)，limitations: ["超量费用暂不支持"] | ❌ |

> **ClaudeCode 和 Anthropic 的关系**：`ClaudeCodeIntegration.costSources` 只返回 Claude Pro 订阅（如有）；`AnthropicIntegration.costSources` 返回 Anthropic API Key（如有）。两者是独立的 CostSource。消歧引擎按 apiKey 优先原则裁决——如果用户同时配了 Claude Pro + Anthropic Key，日志中的 Claude model 会优先归入 Anthropic Key 而非订阅。

### 2.5 PricingManager 扩展

在 `Sources/Ingest/PricingCatalog.swift` 新增：

```swift
func modelsForProvider(_ providerId: String) -> Set<String>  // catalog 中 provider 的所有 model
func modelsForTool(_ toolId: String) -> Set<String>          // 工具的订阅覆盖哪些 model
func claudeModels() -> Set<String>                           // anthropic 的 model
```

### 2.6 修改 Database.swift — 直接改 CREATE TABLE

在 `Sources/Store/Database.swift` 的 `setup()` 中：

- `usage_event` 表 CREATE 语句中直接加入 `cost_source_id TEXT` 和 `cost_confidence TEXT DEFAULT 'estimated'`
- `balance_snapshot` 表 CREATE 语句中直接加入 `cost_source_id TEXT`
- 新增 `cost_source` 表（id, label, kind, confidence, monthly_fee）

- `cost_source` 表新增字段：`usage_percent REAL`、`usage_limit_status TEXT`（UsageMonitor 写入）

已存在的旧 DB 文件用户手动删除即可（开发阶段）。

**`preferredAPIKeyCostSourceId` 的悬挂引用处理**：如果用户选择了某个 API Key 后又删除了该 Key，`activeCostSources()` 中将不再包含该 id。Arbitrator 在 `matching` 中找不到该 id 时自动回退到正常优先级裁决——无需额外处理。

### 2.7 修改 LogWatcher.swift

`insertEvent()` 中：
1. `let sources = IntegrationRegistry.activeCostSources()`
2. `let preferred = IntegrationRegistry.config(for: event.source).preferredAPIKeyCostSourceId`
3. `let (csId, conf) = Arbitrator.resolve(model: event.model, source: event.source, costSources: sources, preferredAPIKeyId: preferred)`
4. 如果归属到 apiKey 且该 apiKey 有余额 API → `cost_usd` 留 NULL（由 ApiPoller 余额差值写入）
5. INSERT 时写入 `cost_source_id` 和 `cost_confidence`

### 2.8 修改 ApiPoller.swift

`cacheBalance()` 写入 `balance_snapshot` 时填入 `cost_source_id = "api-key:\(pid)"`。

注意：Anthropic 有 apiKey CostSource 但**无余额 API**（`canFetchBalance: false`），所以 ApiPoller 不会为 Anthropic 产生 balance_snapshot 行。Anthropic 的花费完全来自 LogWatcher 的 token × 定价表估算。

### 2.9 新建 UsageMonitor.swift（用量追踪）

新建 `Sources/Engine/UsageMonitor.swift`，负责收集订阅制 IDE 的用量百分比：

**Claude Pro/Max** — 本地文件读取：
- 路径：`~/.claude/vscode-claude-status-cache.json`
- 字段：`usageData.utilization5h`、`usageData.utilization7d`、`usageData.limitStatus`
- 存储到 `cost_source` 表的 `usage_percent` 和 `usage_limit_status` 字段
- 在 DataRefreshCoordinator Phase 1（30s）中调用，与 LogWatcher 同频

**GitHub Copilot** — HTTP 轮询：
- 端点：`GET https://api.github.com/copilot_internal/user`
- 认证：用户提供的 GitHub OAuth token
- 字段：`quota_snapshots.premium_interactions.percent_remaining`、`overage_count`
- 在 DataRefreshCoordinator Phase 3（1h）中调用，与 ApiPoller 同频

**UI 联动**：
- Dashboard 油表上显示 "本月已用 45%"
- 超过 90% 时 Dashboard 预警 "即将超额"
- `overage_count > 0` 时标记 "已产生超量计费"

### 2.10 修改 DataRefreshCoordinator.swift

在 `runPhase1()` 末尾增加 `UsageMonitor.shared.refreshClaudeStatus()`（读取本地缓存，零网络开销）。

在 `runPhase3()` 末尾增加 `UsageMonitor.shared.refreshCopilotStatus()`（HTTP 轮询，与 ApiPoller 同为 1h 间隔）。

### 2.11 修改 App 启动流程

`AIPulseApp.swift` 或 `AppDelegate` 中启动序列不变，增加一步：

```swift
// 在 DB setup + startAllEnabled 之后，Coordinator start 之前：
CostSource.syncToDatabase(IntegrationRegistry.activeCostSources())
```

`IntegrationRegistry.startAllEnabled()` 逻辑不变。`AnthropicIntegration` 实现空 `start()/stop()`（与其他 B-grade 一致，由 ApiPoller 驱动）。

### 2.12 修改 StatsService.swift

- **删除** `enabledAGrade()`/`enabledBGrade()`/`enabledCGrade()` 引用

- **`dailyStats()`** — 新增 `GROUP BY cost_source_id` 查询；新增结构：
  ```swift
  struct CostSourceBreakdown: Identifiable {
      var id: String { costSourceId }
      let costSourceId: String
      let label: String           // "DeepSeek API Key"
      let cost: Double
      let confidence: CostConfidence
      let usagePercent: Double?   // nil for apiKey sources
  }
  ```

- **`repoBreakdown()`** — `CPLSource` 改为 `costSourceId` 代替 `label`

- **`combinedSpend()`** — 从 `cost_source` 表查询所有活跃的 subscription CostSource 的 `monthly_fee` 来计算订阅摊销（替换当前的 `enabledCGrade()` + `SubscriptionRegistry` 硬编码）

- **新增** `costSourceSummary(sinceMs:) -> [CostSourceBreakdown]`

### 2.13 CPL 有效门放宽

旧模型 CPL 有效门：必须同时满足"按量计费 + 有日志 + 单一编程用途"。

新模型下，只要花费能归因到某个 repo，CPL 就能计算。不能算的只有两种：

| 场景 | 能算 CPL？ | 原因 |
|------|:---:|------|
| apiKey + 日志（Claude Code/aider）→ cwd → repo | ✅ | `.exact` 或 `.estimated` |
| subscription + EditorDetector 命中 → repo | ✅ | `.amortized` |
| apiKey + 无日志（裸 API 调用，无 cwd） | ❌ | 余额差值无法归因到 repo |
| subscription + 未检测到工作区 | ❌ | EditorDetector 未命中 |

结论：CPL 不再是"限定条件下偶尔出现"的小窗，而是 Dashboard 的核心指标。

### 2.14 偏差告知 UI（Deviation Awareness, Not Correction）

AI Pulse 的定位是**评估分析工具**，不是**财务审计工具**。不要求用户输入精确的修正数字，只需要诚实告知哪些地方可能有偏差。

每个 CostSource 行旁显示 ⓘ tooltip：

| CostSource | ⓘ tooltip |
|-----------|-----------|
| DeepSeek API Key | "基于余额差值计算。假设此 Key 仅用于编程任务" |
| Anthropic API Key | "按 token × 定价表估算。Anthropic 不提供余额 API，实际花费可能有偏差" |
| Claude Pro | "按 $20/月 ÷ 30 天摊销。用量来自本地缓存" |
| Copilot Pro | "按 $10/月 ÷ 30 天摊销。用量来自 GitHub API" |
| Cursor Pro | "按 $20/月 ÷ 30 天摊销。超量费用暂不支持，实际花费可能更高" |

**唯一的用户主动干预**：Settings 中每个订阅制 IDE 旁一个下拉选择：

```
Cursor:
  订阅方案: [Pro $20/月  ▾]
  优先使用 API Key: [DeepSeek API Key  ▾]   ← 下拉列表
                    (不覆盖此工具)
                    DeepSeek API Key
                    OpenAI API Key
                    Anthropic API Key
```

下拉列表的可选项：**仅已配置的 API Key CostSource**。选中一个 Key 后，消歧引擎在处理该 IDE 的日志时：先检查 model 是否匹配选定 Key 的 `coveredModels`，如匹配 → 归属到该 Key（跳过 subscription）；如不匹配 → 仍归入 subscription。

选中"(不覆盖此工具)" → 行为不变，subscription 正常覆盖其 models。这对大多数用户是默认选项——他们用 Cursor Pro 订阅自带的额度，不需要额外 API Key。

### 2.15 修改 DashboardView.swift

- 顶部：当月总花费 + 按 CostSource 分行明细（含 ⓘ tooltip + 用量百分比条）
- 底部：按 repo 分行，显示 净增行数 + CPL（拆分为各 CostSource 贡献）
- CostConfidence 视觉提示：exact 正常显示 / estimated `~` 前缀 / amortized 灰色 / incomplete ⓘ
- CPL 不再 `if hasAGrade` 条件显示，而是 `if costPerRepo > 0` 显示

### 2.16 修改 Settings / IntegrationRow / Dock / MenuBar

- `IntegrationRow`：`switch grade` → 检查 integration 的 `costSources` 中 `kind` 的类型
- `SettingsView`：按 CostSource 分组显示，API Key 输入 + Subscription Tier 选择器 + 优先 API Key 下拉
- `DockManager`、`MenuBarController`：替换 grade 相关引用

### 2.17 验证

编译通过 + 运行 Dashboard 确认花费显示合理 + 手动删除旧 DB 后重新采集。

---

## Phase 3：测试

### 3.1 新增测试

- `Tests/CostSourceArbiterTests.swift` — 消歧引擎：唯一匹配、零匹配、多匹配优先级、nil model
- `Tests/CostSourceTests.swift` — activeCostSources 构建逻辑、modelsForProvider/modelsForTool

### 3.2 更新现有测试

所有 7 个现有测试文件中删除对 `DataGrade`/`grade`/`enabledAGrade()` 等旧 API 的引用。

---

## 受影响的文件总清单

| 文件 | 操作 |
|------|------|
| `Sources/Engine/CostSource.swift` | **新建** — CostSource, CostSourceKind, CostConfidence |
| `Sources/Engine/Arbitrator.swift` | **新建** — 消歧引擎 |
| `Sources/Engine/UsageMonitor.swift` | **新建** — 用量追踪（Claude 本地文件 + Copilot HTTP） |
| `Sources/Engine/IntegrationProtocols.swift` | 删除 DataGrade，Detectable 新增 costSources |
| `Sources/Engine/IntegrationRegistry.swift` | 删除 grade 方法，新增 activeCostSources() |
| `Sources/Ingest/PricingCatalog.swift` | 新增 modelsForProvider/modelsForTool/claudeModels |
| `Sources/Ingest/SubscriptionRegistry.swift` | 配合调整 |
| `Sources/Engine/GitRepo.swift` | 新增 userEmail()，log() 加 author 过滤 |
| `Sources/GitMonitor/GitMonitor.swift` | scanRecentCommits 传入 authorEmail |
| `Sources/Store/Database.swift` | CREATE TABLE 直接加入 cost_source 列 + cost_source 新表 + usage 字段 |
| `Sources/Ingest/LogWatcher.swift` | insertEvent 调用 Arbitrator |
| `Sources/Ingest/ApiPoller.swift` | cacheBalance 写入 cost_source_id |
| `Sources/Store/StatsService.swift` | 按 cost_source_id 聚合 + 用量百分比查询 |
| `Sources/UI/Dashboard/DashboardView.swift` | CostSource 驱动 UI + 用量百分比条 + ⓘ tooltip |
| `Sources/UI/Dock/DockManager.swift` | 适配新 API |
| `Sources/UI/MenuBar/MenuBarController.swift` | 替换 grade 引用 |
| `Sources/UI/Settings/SettingsView.swift` | CostSource 配置 UI |
| `Sources/UI/Shared/IntegrationRow.swift` | grade 分支 → CostSourceKind 分支 |
| `Sources/Integrations/BGradeIntegrations.swift` | 删除 grade，新增 AnthropicIntegration + costSources 实现 |
| `Sources/Integrations/` 其余 6 个文件 | 删除 grade，新增 costSources 实现 |
| `Tests/` 全部 7 个文件 + 3 个新文件 | 更新 + 新增（Arbitrator, CostSource, UsageMonitor） |

## 风险与注意事项

1. **DB 不兼容旧数据**：用户需手动删除 `~/Library/Application Support/AIPulse/aipulse.db` 后重启
2. **PricingManager 保留**：作为 token 定价回退方案（cost_source_id = unknown 时）
3. **Anthropic 无余额 API**：confidence 标记 `.estimated`
4. **消歧规则可能出错**：Settings 中提供手动覆盖入口
5. **多 CostSource 覆盖同一 model**：默认优先级 apiKey > subscription > 自动检测

## 附录：订阅制 IDE 的用量数据来源

### 已支持

| IDE | 数据来源 | 方式 | 可获得的数据 | 对模型的影响 |
|-----|---------|------|------------|------------|
| **Claude Pro/Max** | `~/.claude/vscode-claude-status-cache.json` | 本地文件读取（零网络开销） | `utilization5h`, `utilization7d`, `limitStatus`, `reset5hAt`, `reset7dAt` | confidence `.amortized`；用量数据用于预警限流 |
| **GitHub Copilot** | `GET api.github.com/copilot_internal/user` | HTTP OAuth | `percent_remaining`, `overage_count`, `quota_remaining` | confidence `.amortized`；`overage_count > 0` 时标记超量 |

### 暂不支持

| IDE | 原因 | 处理方式 |
|-----|------|---------|
| **Cursor** | 用量面板仅在 IDE 内部，无外部 API | `.amortized`，limitations: `["超量费用暂不支持"]` |
| **Windsurf**（个人版） | API 仅限企业版 | `.amortized`，limitations: `["超量费用暂不支持"]` |

> 不支持的花费**不隐藏**——仍然按订阅月费摊销计入 Dashboard，但标注"实际花费可能更高"。
