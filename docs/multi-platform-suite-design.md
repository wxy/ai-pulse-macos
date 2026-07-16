# AI Pulse 多端套装设计

## 架构概览

```
┌─────────────────────────────────────────────────────────┐
│                    iCloud Private DB                     │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐  │
│  │ daily_stats  │  │ code_changes │  │ balance_snap   │  │
│  └──────┬───────┘  └──────┬───────┘  └───────┬────────┘  │
└─────────┼─────────────────┼───────────────────┼──────────┘
          │                 │                   │
    ┌─────┴─────┐    ┌──────┴──────┐    ┌───────┴───────┐
    │ 读取+写入  │    │   只读      │    │    只读       │
    │           │    │            │    │              │
    │  macOS    │    │   iOS      │    │   watchOS    │
    │  采集+展示 │    │   仪表盘    │    │   小组件      │
    └───────────┘    └────────────┘    └──────────────┘
```

## 角色分工

| 平台 | 角色 | 功能 |
|------|------|------|
| macOS | **数据采集 + 展示** | LogWatcher, ApiPoller, GitMonitor, 设置, 集成, 仪表盘 |
| iOS / iPadOS | **只读仪表盘** | Today/Week/30d 趋势图, 花费概览, donut charts |
| watchOS | **极简仪表盘** | 今日花费 complication, 花费趋势 app |

## 数据同步

### 同步方向

**macOS → iCloud 单向写入，移动端只读**

移动端不写任何数据，不做设置、不配置集成、不输入 Key。所有配置和集成仍在 macOS 端完成。

### 同步内容

仅同步聚合数据（非原始日志）：

| CKRecord Type | 字段 | 同步触发 |
|---------------|------|---------|
| `DailyStat` | date, cost, calls, tokens, netLines | DataRefreshCoordinator Phase 1 完成后 |
| `DailyCodeChange` | date, added, deleted | 同上 |
| `ProviderCost` | date, providerId, cost | 同上 |
| `AppConfig` | demoMode, currency, monthProjection | 设置变更时 |

不同步：
- 原始 `usage_event` 行（数据量大，移动端不需要）
- API Key（安全敏感，不同步）
- 文件路径、仓库路径（跨设备无意义）

### 冲突策略

单向写入，无冲突。macOS 每次 `DataRefreshCoordinator` 周期后覆盖式写入 CKRecord。

## 文件结构

```
ai-pulse/
├── ai-pulse-macos/          # 现有 macOS app（SPM project）
│   └── Sources/
│       └── Sync/
│           └── CloudSyncService.swift   # 新增：CKRecord 写入
│
├── ai-pulse-ios/            # 新建 iOS app（SPM project）
│   └── Sources/
│       ├── App/
│       │   └── AIPulseApp.swift
│       ├── UI/
│       │   └── Dashboard/
│       │       └── DashboardView.swift  # 复用 macOS Dashboard 逻辑
│       └── Store/
│           └── CloudDataService.swift   # CKQuery 读取
│
├── ai-pulse-watchos/        # 新建 watchOS app（SPM project）
│   └── Sources/
│       ├── App/
│       │   └── AIPulseWatchApp.swift
│       ├── UI/
│       │   └── Complication/
│       │       └── SpendComplication.swift
│       └── Store/
│           └── CloudDataService.swift
│
└── ai-pulse-shared/         # 新建 shared Swift package
    └── Sources/
        ├── Models/
        │   └── DailyStat.swift
        │   └── DailyCodeChange.swift
        │   └── ProviderCost.swift
        ├── UI/
        │   └── Dashboard/
        │       └── TrendChart.swift    # 跨平台复用
        │       └── DonutChart.swift
        │       └── SpendingCard.swift
        └── I18n/
            └── I18n.swift
```

## 需要解决的问题

### 1. 共享代码

**方案**：将数据模型 + Dashboard UI 组件 + I18n 抽取到 `ai-pulse-shared` Swift Package。

- DashboardView 需要适配不同屏幕尺寸（macOS 700x660 → iOS compact → watchOS complication）
- Charts 框架在 macOS 14+ / iOS 16+ / watchOS 10+ 均可用
- I18n 当前使用 Info.plist 内嵌字典，需改为 `.strings` 文件以支持 SPM 跨平台

### 2. CloudKit 集成

**方案**：使用 `NSPersistentCloudKitContainer` 或直接 CKRecord API。

- macOS 端：`CloudSyncService` 在 DataRefreshCoordinator 周期后写入
- iOS/watchOS 端：`CloudDataService` 在 app 进入前台时查询
- 需要 `com.apple.developer.icloud-services` entitlement

### 3. App 套装

**方案**：在 App Store Connect 创建 App Group，以"AI Pulse Suite"品牌发布。

- 每个平台独立审核（macOS / iOS / watchOS 分别上架）
- 可选：Xcode 单一 project 通过多 target 管理（简化签名和依赖）

### 4. Dashboard 响应式布局

**方案**：macOS 保持现有 700x660 布局；iOS 使用 NavigationStack + TabView；watchOS 使用极简单屏。

- 共享 View 组件接收 `sizeClass` 或 `horizontalSizeClass` 适配
- watchOS 不显示完整图表，使用环形进度 + 数字

## 优先级

| 阶段 | 内容 | 工作量估计 |
|------|------|-----------|
| 1 | 抽取共享 Models + I18n 到 ai-pulse-shared | 2-3 天 |
| 2 | macOS 端 CloudSyncService | 2 天 |
| 3 | iOS 端基础 Dashboard（Today + spending cards） | 3-5 天 |
| 4 | iOS 端完整 Dashboard（Week/30d trend + donuts） | 3 天 |
| 5 | watchOS complication + 基础 app | 2-3 天 |
| 6 | App Store 套装发布 | 1 天 |

总计约 2-3 周。
