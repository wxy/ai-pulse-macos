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

iOS/iPadOS 共享同一代码库（自适应布局）。watchOS 单独。

```
ai-pulse-macos/                    # 仓库根（单仓库，不动现有结构）
├── Sources/                        # 现有 macOS 代码，不动
│   └── Sync/
│       └── CloudSyncService.swift  # 🆕 新增：CKRecord 写入
├── Suites/                         # 🆕 移动端套件
│   ├── Shared/                     # 跨平台共享
│   │   ├── Models/
│   │   │   ├── DailyStat.swift
│   │   │   ├── DailyCodeChange.swift
│   │   │   └── ProviderCost.swift
│   │   └── UI/                     # 共享视图组件
│   │       ├── TrendChart.swift
│   │       ├── DonutChart.swift
│   │       └── SpendingCard.swift
│   ├── iOS/                        # iOS + iPadOS（单 target，自适应）
│   │   ├── App/
│   │   │   └── AIPulse_iOSApp.swift
│   │   └── UI/
│   │       ├── DashboardView.swift
│   │       └── WelcomeView.swift   # 无 macOS 时的引导页
│   └── watchOS/                    # watchOS
│       ├── App/
│       │   └── AIPulse_WatchApp.swift
│       ├── UI/
│       │   ├── ContentView.swift
│       │   └── SpendComplication.swift
│       └── Store/
│           └── CloudDataService.swift
├── AIPulse/                         # macOS 工程目录（已有）
│   └── AIPulse.xcodeproj           # macOS project
├── Suites/                          # 🆕 移动端（iOS/watchOS xcodeproj 在此）
├── AIPulse.xcworkspace             # 统一工作空间（已有）
├── Package.swift                   # SPM（已有）
└── Resources/                      # 现有资源
```

**工作空间说明**：`AIPulse.xcworkspace`（已有）作为统一工作空间，包含 macOS project + 新建的 iOS/watchOS project。在 Xcode 中打开一个 workspace，Scheme 选择器切换目标即可构建/运行任一平台。

注意：目前仓库中只有 `AIPulse.xcworkspace` 是实际使用的。`.xcodeproj/project.xcworkspace` 和 `.swiftpm/xcode/package.xcworkspace` 是 Xcode/SPM 自动生成的，无需关注。

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

### 4. 平台定位（第一性原理）

| 平台 | 用户场景 | 核心问题 | 角色 |
|------|---------|---------|------|
| macOS | 正在 Mac 上工作 | "我花了多少？花在哪？" | 数据采集 + 完整分析 |
| watchOS | 离开 Mac，手腕上 | "现在在花钱吗？花了多少？" | 实时消费感知 |
| iOS | 手机在口袋，快速扫一眼 | "今天哪个项目烧钱最多？" | 快捷 Dashboard |
| iPad | 沙发/会议室，大屏便携 | "给我完整的仪表盘" | 完整只读 Dashboard |

### 5. 各平台布局与功能

#### watchOS

**布局**：极简

- 今日花费总额（最大字号，占据屏幕中部）
- 环形进度（月度预算 vs 实际）
- 不需要 Tab 切换（只看今日）

**Complication（表盘集成）**：

- 小号：今日花费数字（如 "$12.50"）
- 中号：今日花费 + 环形进度

**设置**：无 app 内设置面板。通知 + 声音/震动跟随系统级推送通知权限。complication 按系统频率刷新（约 30 分钟），实时推送后期再做。

#### iOS

**布局**：保持机器人面部布局，donut 环缩小适配窄屏，单屏不滚动

- 顶部：花费总额大数字 + Tab 切换（Today / Week / 30d）
- 中间行：donut ~90px | 统计卡（精简为 3 行）| donut ~90px
- 底部：仓库/工具花费 top 3
- 去掉：趋势图、月度预估行、服务商 donut（仅保留订阅 vs API 一个环）

**设置**：无 app 内设置面板。通知 + 声音跟随系统级推送通知权限。

#### iPadOS

**布局**：完整复用 macOS 仪表盘（两列 + donut + 趋势图 + 仓库排行），只读。

**设置**：无 app 内设置面板。通知 + 声音跟随系统级推送通知权限。

### 6. 无 macOS 端时的引导

移动端首次启动检测 iCloud 中是否有数据：
- **有数据** → 直接展示 Dashboard
- **无数据** → 显示引导页 + App Store 链接到 macOS 版

移动端不内置 Demo 模式（Demo 数据只存在于 macOS 端）。如果用户只想预览，引导他们下载 Mac 版。

### 7. macOS → 移动端推送机制

macOS 每次花费更新时：
1. 写入 iCloud（聚合数据）
2. 推送一条静默通知到 APNs → iOS/watchOS 设备

移动端收到静默通知后刷新 Dashboard 并触发本地通知（声音/震动），通知行为跟随系统级通知权限，用户通过系统设置控制。

不需要自建推送服务器——macOS 本身就是"服务端"，直接通过 CloudKit + APNs Provider API 推送。

### 8. 首次安装 macOS 版的场景

macOS 首次运行 → 引导流程（现有）→ 开始采集 → DataRefreshCoordinator 周期后：
1. 将聚合数据写入 iCloud
2. 推送静默通知到 APNs

移动端下次进入前台时自动刷新 Dashboard。

## 优先级

| 阶段 | 内容 | 预估 |
|------|------|-----|
| 1 | 抽取共享 Models + I18n 到 ai-pulse-shared | 2-3 天 |
| 2 | macOS 端 CloudSyncService + 推送触发 | 2 天 |
| 3 | iOS 端：引导页 + 单屏 Dashboard + 设置 | 4 天 |
| 4 | iPad 端：复用 macOS 布局 + 设置 | 1 天 |
| 5 | watchOS：complication + 手表 app + 设置 | 2 天 |
| 6 | App Store 套装发布 | 1 天 |

总计约 2-2.5 周。
