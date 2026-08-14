# 花费激增与余额骤降分级告警（设计）

日期：2026-08-14
分支：`codex/spend-surge-alerts`

## 背景与目标

当前 1.2.5 的用户可感知增量偏少；用户更关心一个真实痛点：**一夜之间 AI 费用可能暴增（甚至数千美元）**。现有 `AnomalyDetector` 只有“单条、单阈值、无级别”的本地告警，无法做到逐步升级，也无法触达 iPhone/watchOS。

目标：在不拦截消费的前提下，检测**意外消费激增**与**余额骤降**，通过**可配置、分级、逐步升级**的告警，在 macOS 与 iOS（首期经 iPhone 镜像到 Apple Watch）上及时告知用户。

核心原则：

- 只告知，不拦截——我们无法阻止消费继续，但可以让用户尽早知情。
- 可配置且默认开启（opt-out）——一次真实告警的价值远高于偶尔的误报；同时提供关闭/静音入口，避免对消费模式本就不规律的用户长期骚扰。
- 信号来自可观测数据（本地日志花费速率 + 服务商余额差值），不依赖订阅周期。
- 跨端：macOS 检测 → CloudKit 新记录 → iOS 静默推送 → 本地通知（→ 镜像到 Apple Watch）。

## 现有基础

该功能不是从零开始，可复用：

| 组件 | 现状 |
| --- | --- |
| `Sources/Engine/AnomalyDetector.swift` | 已有 7 天小时均值基线 + 3× 阈值 + 单条通知 + `notifiedHours` 去重 |
| `Sources/Engine/AppHealthMonitor.swift` | 已有 severity 分级与关键通知通道 |
| `Sources/Ingest/ApiPoller.swift` | 每小时拉取余额，写入 `balance_snapshot` |
| `Sources/Sync/CloudSyncService.swift` / `CKSchema` | 已有 `DashboardCache_v1` 单记录 + JSON blob 同步模式 |
| `Suites/iOS/App/Notifications.swift` | 已有 CloudKit 静默推送订阅 + 本地 `.timeSensitive` 通知 |
| `Suites/watchOS/App/AIPulse_WatchApp.swift` | 目前仅拉取快照，无通知处理 |
| `Resources/coin.mp3` / `coins.mp3` | 现有“金币”音效，需与告警音区分 |

## 信号与触发

### 信号 A：花费速率激增（本地日志）

数据源 `usage_event`（`ts`、`cost_usd`、`source`、`model`），排除 `<synthetic>` 行。

- 窗口：最近 1 小时（沿用现有）与最近 24 小时。
- 基线：过去 7 天（或 14 天）对应窗口的**中位数**。中位数比均值更抗尖峰，避免当前尖峰把基线拉高。
- 绝对下限：低于某金额的波动不告警。

### 信号 B：余额骤降（服务商余额）

数据源 `balance_snapshot`（`ts`、`provider_id`、余额、币种）。

- 归一化为 USD 后比较（复用现有余额 USD 归一化能力）。
- 比较相邻快照与 24 小时窗口内的余额下降幅度。

该信号比日志更可靠，因为余额是服务商侧账单事实，且不依赖本地日志是否完整。它也是“一夜数千美元”最直接的探测器。

## 分级与升级

初始阈值（可调，需用真实数据回填校准）：

| 级别 | 信号 A（速率激增） | 信号 B（余额骤降） |
| --- | --- | --- |
| L1 提醒 | 最近 1h ≥ 2× 小时基线，且 ≥ $1 | 24h 余额下降 ≥ $20 |
| L2 警告 | 最近 1h ≥ 5× 小时基线且 ≥ $5，或 24h ≥ 2× 日基线且 ≥ $20 | 24h 下降 ≥ $50，或单次环比下降 ≥ $100 |
| L3 严重 | 最近 1h ≥ 10× 小时基线且 ≥ $10，或 24h ≥ 5× 日基线且 ≥ $50 | 24h 下降 ≥ $200，或单次环比下降 ≥ $500 |

金额下限采用“绝对下限 + 相对倍数”双条件（AND）：

- 绝对下限为**硬编码**（按级别），用于过滤“绝对金额很小、但相对涨幅很大”的抖动。
- 相对倍数为**历史基线**（中位数），用于适配不同用户的日常消费量级。
- 冷启动：历史不足 N 个窗口时，速率激增信号暂用保守默认基线，或仅发余额骤降；余额骤降为纯绝对判断，立即可用。

升级语义：

- 同一信号在连续检测周期内持续超标时，级别可提升（L1 → L2 → L3）。
- 去重键：`{level}-{kind}-{source}-{timeBucket}`，同一键只发一次。
- 冷却：L1 每 6 小时最多一次、L2 每 12 小时、L3 每 24 小时；L3 在仍严重时允许 2 小时后重复一次，避免“只提醒一次就被忽略”。

## 可配置项

macOS 设置页新增：

| 开关 | 默认 | 说明 |
| --- | --- | --- |
| `spend_alerts_enabled` | 开 | 主开关，默认开启（opt-out） |
| `balance_drop_alerts_enabled` | 开 | 余额骤降，误报极低 |
| `spend_rate_alerts_enabled` | 开 | 速率激增，依赖历史基线 |

这样“突然消费、随后长时间不消费”的用户可以只开启余额骤降，关闭速率激增。

## 跨端通知架构

### CloudKit 新记录类型 `SpendAlert_v1`

沿用现有单记录 + JSON blob 模式：

- 记录名：`alert-latest`（单记录 upsert）。
- 字段：`json`（JSON blob）+ `updatedAt`。

Payload 结构：

```swift
struct SpendAlertPayload: Codable {
    var eventId: String       // 去重 id
    var level: Int            // 1 / 2 / 3
    var kind: String          // "spend_rate" | "balance_drop"
    var source: String        // provider/tool id，或 "aggregate"
    var amountUsd: Double     // 花费或下降金额（USD）
    var baselineUsd: Double?  // 仅速率激增需要
    var occurredAt: Date
}
```

接收端根据 `kind` + `level` 本地本地化文案，不传输完整字符串，利于 10 种语言复用。

### 流程

1. macOS 检测到激增/骤降 → 写 `SpendAlert_v1/alert-latest`。
2. iOS 订阅 `SpendAlert_v1`（`CKQuerySubscription`，`shouldSendContentAvailable = true`，`firesOnRecordCreation` / `firesOnRecordUpdate`）。
3. iOS 收到静默推送 → 拉取 `alert-latest` → 发本地 `UNNotification`（`.timeSensitive` + 系统默认声音）。
4. watchOS 首期：iPhone 本地通知在锁屏/离手时自动镜像到配对的 Apple Watch；后续可选原生 APNs/CloudKit 订阅。

## 通知行为与声音

- macOS：`UNNotificationRequest`，`interruptionLevel = .timeSensitive`，`sound = .default`（系统默认声音，与应用内金币声互不影响）。
- iOS：带声音的 `.timeSensitive`，区别于现有静默 `cost-update`（金币声）。
- 不新增系统权限，不新增告警音资源，复用现有 `UNUserNotificationCenter` 授权与系统声音。

## 本地化

新增按 `kind` + `level` 组合的 key，例如：

- `alert.spend_rate.l1.title` / `alert.spend_rate.l1.body`
- `alert.spend_rate.l2.title` / `alert.spend_rate.l2.body`
- `alert.balance_drop.l2.title` / `alert.balance_drop.l2.body`

遵循现有 10 种语言的 `Localizable.xcstrings` 维护方式。

## 反误报

- 基线用中位数，不用均值。
- 绝对金额下限，忽略小额抖动。
- 排除 `<synthetic>` 合成行。
- 去重键 + 冷却。
- 余额骤降与日志速率双信号，余额信号天然更可靠。
- 冷启动：历史不足时速率信号保守处理，余额信号照常。

## 改动范围（文件）

macOS：

- `Sources/Engine/AnomalyDetector.swift`（增强为分级检测）
- 新增 `Sources/Engine/SpendAlertService.swift`（统一检测、分级、写 CloudKit；或并入现有类）
- `Sources/Sync/CloudKitSchema.swift`（新增 `SpendAlert_v1`）
- `Sources/Sync/CloudSyncService.swift`（写 alert 记录）
- 设置 UI、`Sources/Utils/I18n.swift`、`Sources/Localizable.xcstrings`

iOS：

- `Suites/Shared/Models/CloudKitSchema.swift`（同步常量）
- `Suites/iOS/App/Notifications.swift`（新增 alert 订阅与本地通知）
- `Suites/Shared/I18n/I18n.swift` + 本地化

watchOS：

- 首期无代码（依赖 iPhone 通知镜像）；后续可选。

## 测试点

- 阈值计算：中位数基线、绝对下限、分级边界。
- 去重与冷却逻辑。
- 余额骤降检测（含币种归一化）。
- `SpendAlertPayload` 编解码。
- iOS 收到 push → 拉取 → 发通知的链路。
- 开关默认值与关闭时不写 CloudKit。

## 后续可选项

- 原生 watchOS 通知（独立于 iPhone 镜像）。
- 用户自定义阈值。
- 告警历史列表 / 告警中心。
