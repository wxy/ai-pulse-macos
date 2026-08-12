# iOS 工具详情（会话级统计）设计

日期：2026-08-12
分支：`codex/ios-tool-detail`

## 背景与目标

macOS 端已有开发工具详情面板：点击工具行可看到三行摘要（结论卡），点击摘要可查看会话级统计。本次目标是在 iOS 端实现"三行摘要 + 会话列表"的详情面板，并把会话级数据随现有 CloudKit 快照同步给 iOS。

## 产品定位决策

| 端 | 定位 |
| --- | --- |
| macOS | 完整分析：三行摘要 + 会话列表 + per-turn 趋势图 |
| iOS | 会话级概览：三行摘要 + 会话列表 + 每会话指标（不做 per-turn 趋势图） |
| Widget / watchOS | 成本概览（现状，不改变） |

**决策依据**：per-turn 趋势图是数据密集型冷数据（30 天约 2.3MB），手机小屏价值低、同步成本高；iOS 提供会话级概览已满足"点击摘要看会话统计"的核心诉求。

## 版本语义与显示

### payloadVersion 语义（兼容基线）

`payloadVersion` 定义为**格式兼容基线**，而非"数据最新变更版本"：

- 只有破坏性变更（删除/重命名/改变字段含义）才 bump。
- 增量添加字段不 bump——旧客户端通过 JSONDecoder 忽略未知字段继续读取。

本次会话数据为**增量添加**，因此 `payloadVersion` **保持 1.2.4 不变**（macOS 与 iOS 两端常量都不改）。

### 显示格式

仪表盘底部（macOS + iOS）与 macOS 关于页统一显示应用版本与数据库版本的联合语义，去掉构建号：

- 仪表盘底部：`AI Pulse v1.2.5/CloudKit 1.2.4`
- macOS 关于页：`AI Pulse v1.2.5`（软件版本）+ `CloudKit 1.2.4`（数据库版本），移除现有 `(27)` 构建号

语义：应用版本决定 UI 能力（是否展示会话详情），payloadVersion 决定数据读取能力（兼容基线）。

## 数据模型

`DashboardSnapshot`（macOS 的 `Sources/Store/DashboardCache.swift` 与 iOS 的 `Suites/Shared/Models/DashboardSnapshot.swift` 各一份，需保持同步）增量添加字段：

```swift
/// 每个时间范围快照内各工具的三行摘要 + 会话列表。
/// 增量添加：旧客户端忽略此字段；旧 macOS 快照缺失此字段时 iOS 显示空态。
var toolDetails: [ToolDetailItem] = []

struct ToolDetailItem: Codable {
    var source: String                    // "codex" / "claude-code"
    var conclusion: ToolConclusionItem    // 三行摘要
    var sessions: [ToolSessionItem]       // 会话列表（不含 per-turn 数据）
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
    var crossToolDeltaPct: Double?        // 与另一工具平均成本对比
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
}
```

数据来源：macOS 现有 `StatsService.toolConclusion(source:sinceMs:)` 与 `StatsService.sessionRows(source:sinceMs:)`，直接复用。

数据量估算：30 天快照加会话列表后约 100KB 出头，远低于 CloudKit 单记录 1MB 上限。**不新增 CloudKit 记录类型**，同步循环与订阅不变。

## macOS 改动

1. `Sources/Store/DashboardCache.swift`：`DashboardSnapshot` 添加 `toolDetails` 字段及三个新结构（`ToolDetailItem` / `ToolConclusionItem` / `ToolSessionItem`）。
2. `Sources/Store/StatsService.swift`：`dashboardSnapshot(days:)` 中为 `codex` 与 `claude-code` 两个 source 调用 `toolConclusion` + `sessionRows`，填充 `toolDetails`（两个查询并行执行，避免拖慢快照）。
3. `Sources/UI/Dashboard/DashboardView.swift`：仪表盘底部显示改为 `AI Pulse v1.2.5/CloudKit 1.2.4`（应用版本取自 `Bundle.main`，数据库版本取自 `CKSchema.payloadVersion`）。
4. `Sources/UI/Settings/SettingsView.swift`（AboutTab）：软件版本行改为 `AI Pulse v1.2.5`（去掉 `(27)`），保留 `CloudKit 1.2.4` 行。
5. `Sources/Utils/I18n.swift`：如需要新增文案（版本号拼接可硬编码，专有名词不翻译）。

## iOS 改动

1. `Suites/Shared/Models/DashboardSnapshot.swift`：同步添加 `toolDetails` 及三个结构（与 macOS 完全一致）。
2. `Suites/iOS/UI/DashboardView.swift`：
   - 工具行（toolBars）改为可点击，点击后弹出详情面板（sheet）。
   - 详情面板显示该工具的三行摘要 + 会话列表；会话行显示标题、时间、成本、上下文占用率（复用现有 SessionRow 展示逻辑，按 iOS 样式重写）。
   - `toolDetails` 为空时显示"暂无会话数据"空态。
3. 仪表盘底部显示改为 `AI Pulse v1.2.5/CloudKit 1.2.4`。
4. `Suites/Shared/I18n/I18n.swift`：新增详情面板相关文案，补齐 10 种语言（如"会话"、"暂无会话数据"、"提交行数"等）。

## 兼容性

- iOS 1.2.4（旧客户端）：忽略 `toolDetails` 字段，仪表盘照常显示；不识别任何新记录类型（也没有）。
- iOS 1.2.5（新客户端）读旧 macOS 快照（无 `toolDetails`）：显示"暂无会话数据"空态。
- macOS 1.2.5 写快照：`payloadVersion` 仍为 1.2.4，旧 iOS 1.2.4 正常读取。
- 不新增 CloudKit 记录类型，不新增订阅，同步频率不变。

## 验证

1. macOS：`xcodebuild` Debug 构建通过；`swift test`（隔离缓存方式）全部通过。
2. iOS：`xcodebuild` 模拟器构建通过。
3. 手动：macOS 仪表盘/关于页显示新格式；iOS 工具行可打开详情面板，三行摘要与会话列表正确显示；旧快照（无 toolDetails）显示空态。

## 不做的内容（YAGNI）

- 不做 iOS per-turn 趋势图。
- 不新增 CloudKit 记录类型/订阅。
- 不 bump `payloadVersion`。
- 不修改 Widget / watchOS。
- 不改变 macOS 现有 per-turn 趋势图功能。
