# AI Pulse for macOS

[![CI](https://github.com/wxy/ai-pulse-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/wxy/ai-pulse-macos/actions/workflows/ci.yml)
[![Mac App Store](https://img.shields.io/badge/Mac%20App%20Store-AI%20Pulse-0D96F6?logo=apple)](https://apps.apple.com/us/app/ai-pulse/id6786290416?mt=12)
[![iOS App Store](https://img.shields.io/badge/iOS%20App%20Store-AI%20Pulse-0D96F6?logo=apple)](https://apps.apple.com/cn/app/ai-pulse-%E7%BC%96%E7%A8%8B%E8%8A%B1%E8%B4%B9%E8%BF%BD%E8%B8%AA%E4%BB%AA/id6786290416)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20%2F%20iOS%2016%2B-lightgrey)]()
[![Swift](https://img.shields.io/badge/swift-6.0-orange)]()

你的 AI 编程油量表 —— 精确追踪每笔 AI 费用花在了哪里、花了多少、
产出是否值得。**100% 本地运行，数据绝不出设备。**

同时关注 [AI Pulse Chrome 扩展](https://github.com/wxy/ai-pulse) ——
覆盖 ChatGPT、Claude.ai、DeepSeek Chat 等网页端 AI 工具。

## 下载

[![Download on the Mac App Store](https://tools.applemediaservices.com/api/badges/download-on-the-mac-app-store/black/en-us?size=250x83)](https://apps.apple.com/us/app/ai-pulse/id6786290416?mt=12)
[![Download on the App Store](https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83)](https://apps.apple.com/cn/app/ai-pulse-%E7%BC%96%E7%A8%8B%E8%8A%B1%E8%B4%B9%E8%BF%BD%E8%B8%AA%E4%BB%AA/id6786290416)

- **macOS 版** — 需要 macOS 14 Sonoma 或更高版本
- **iOS 版** — 需要 iOS 16 或更高版本，以及 macOS 版（数据来源）

💡 **多平台通用购买（Universal Purchase）—— 一次购买，iOS 与 macOS 通用。**
如果您已经购买了 Mac 版，在 iPhone / iPad 上下载时仍看到价格按钮，请不要担心：
只要使用同一个 Apple ID，直接点击购买即可，系统会自动识别您的购买记录并提示「免费下载」，
绝不会向您重复扣费。

## iOS 伴侣应用

iOS 版是 macOS 版的**只读伴侣应用**。它会在您的 iPhone / iPad 上展示 macOS 采集到的
AI 用量与花费信息——今日、本周、30 天趋势图，按工具和供应商统计的环形图，以及按仓库的明细排行。
所有数据通过 iCloud 同步，仅保存在您自己的设备上，不会离开您的 Apple ID 生态。

- **只读** — iOS 应用本身不采集、不上传任何数据
- **iCloud 同步** — 自动完成，零配置
- **推送通知** — 花费提醒，搭配金币音效
- **与 macOS 一致的仪表盘** — 环形图、趋势图、工具 & 仓库排行

请先下载并配置 **macOS 版**，AI 用量信息由 macOS 采集后通过 iCloud 同步到 iOS。

iOS 上架描述见 [docs/appstore-description-ios.md](docs/appstore-description-ios.md)。

## 工作原理

AI Pulse 通过三层数据采集发现你的 AI 支出，然后通过 CostSource 模型
将每一分钱精确归属到对应的工具、供应商和代码仓库：

```
┌──────────────────────────────────────────────┐
│  第一层：日志解析（Token 级精确计价）         │
│  Claude Code、aider — 原始请求/响应日志       │
├──────────────────────────────────────────────┤
│  第二层：余额 API（精确到分）                 │
│  DeepSeek、OpenAI、Kimi、智谱、Anthropic      │
├──────────────────────────────────────────────┤
│  第三层：订阅检测（按天摊销）                 │
│  Cursor、Copilot、Windsurf、Claude Code Pro   │
└──────────────────────────────────────────────┘
                    ↓
           Arbitrator 将每笔
           使用事件解析到唯一 CostSource
                    ↓
          CostSource（谁在收钱？）
          • apiKey(providerId: "deepseek")
          • subscription(toolId: "cursor", tier: "Pro")
                    ↓
         ┌──────────┼──────────┐
      Dashboard    MenuBar     Dock
```

### CostSource 计费模型

两层归因体系替代了旧的 A/B/C 分级模型：

- **Integration 层**：每个集成声明自己提供的 CostSource ——
  API Key 配合余额轮询、订阅配合月费摊销
- **Arbitrator 层**：将每条使用事件解析到最可能的 CostSource，
  优先级：用户首选 API Key → apiKey → subscription

每个 CostSource 带有可信度级别（`exact` > `estimated` > `amortized` >
`uncertain` > `incomplete`），让你时刻了解数据的可靠程度。

## 功能

### 仪表盘（Dashboard）
三区块主窗口，一目了然：
- **环形图** — 按供应商/工具的费用分布，玛尔斯绿（#2C5B48）与深红（#AD2E23）配色
- **30 天趋势图** — 每日 API 费用 + 订阅摊销堆叠展示
- **仓库 & 工具排行** — 哪些项目和 AI 工具烧钱最多

### 菜单栏（Menu Bar）
- 菜单栏中快速查看今日/累计花费
- 按 **供应商**、**工具**、**仓库**、**本周** 四个维度下钻
- 四个视图与仪表盘总额完全一致（统一计费公式）

### Dock 图标
- 油量表环形进度，对数刻度显示
- 角标显示今日花费总额
- 数据更新时金色脉冲动画
- 右键菜单快速查看费用分布

### 数据采集
| 层级 | 来源 | 方式 |
|------|------|------|
| 日志解析 | Claude Code、aider | 从请求日志中提取 Token × 定价 |
| 余额 API | DeepSeek、OpenAI、Kimi、智谱、Anthropic | 每日余额差值 |
| 订阅检测 | Cursor、Copilot、Windsurf、Claude Code Pro | 月费摊销到天 |

### 其他功能
- **异常检测** — 费用异常飙升时发送 macOS 通知
- **金币音效** — 数据刷新时的反馈音效（MP3）
- **提交追踪** — libgit2 驱动的仓库扫描，将代码产出与 AI 花费关联
- **多语言** — 中文 / English
- **沙盒化** — 符合 Mac App Store 要求

## 环境要求

- macOS 14 Sonoma 或更高版本
- Xcode 16.6+
- [Apple Developer Program](https://developer.apple.com) 会员（分发需要）

## 快速开始

```bash
git clone https://github.com/wxy/ai-pulse-macos.git
cd ai-pulse-macos

# 命令行
make build   # 编译
make test    # 运行测试（56 个测试用例）
make run     # 开发模式启动

# 或在 Xcode 中打开
open AIPulse/AIPulse.xcodeproj
```

## 分发打包

```bash
# 1. 配置凭据（仅需一次）
cp .env.example .env
# 编辑 .env，填入 Apple ID 和 App-Specific Password

# 2. 在 Xcode 中归档
#    Product → Archive → Distribute App → Direct Distribution
#    导出已公证的 AIPulse.app 到 dist/

# 3. 打包 DMG
NOTARIZE=1 ./scripts/make-dmg.sh
# → dist/AIPulse-{version}.dmg
```

## 架构

```
Sources/
├── App/                应用入口、启动流程
├── Engine/             核心逻辑
│   ├── CostSource      "谁在收钱？" — 费用归因模型
│   ├── Arbitrator      通过模型名解析事件 → CostSource
│   ├── Integration*    协议（Detectable/Collectable）+ 注册中心
│   ├── DataRefreshCoordinator  三阶段调度器（30s/5min/1h）
│   ├── RepoDiscovery   扫描文件系统发现 Git 仓库
│   ├── AnomalyDetector 费用异常检测
│   ├── CoinSound       数据刷新金币音效
│   ├── UsageMonitor    追踪活跃 AI 工具（Claude 缓存等）
│   └── EditorDetector  推断编辑器-仓库关联
├── GitMonitor/         libgit2 驱动的提交追踪
├── Ingest/
│   ├── LogWatcher      tail 风格的日志扫描
│   ├── ApiPoller       余额 API 轮询
│   ├── PricingCatalog  Token 定价数据库
│   └── LogParsers/     Claude Code + aider 日志解析器
├── Integrations/       10 个 AI 工具集成
├── Store/              GRDB/SQLite 持久化 + StatsService
├── UI/
│   ├── Dashboard       三区块主窗口
│   ├── MenuBar         菜单栏费用明细
│   ├── Dock            油量表 + 角标
│   ├── Settings        按集成配置
│   ├── Onboarding      首次启动集成选择器
│   └── Shared/         AppIconLoader、IntegrationRow
└── Utils/              I18n（中文/英文）、Logger
```

### 数据流

```
LogWatcher        ──┐
ApiPoller         ──┤
GitMonitor        ──┤
RepoDiscovery     ──┤
                     ↓
        DataRefreshCoordinator
        （错峰调度 30s / 5min / 1h）
                     ↓
              .dataDidChange
                     ↓
    ┌────────┬────────┬────────┬──────────┐
 仪表盘    菜单栏     Dock   金币音效   异常检测
```

## 脚本

| 脚本 | 用途 |
|------|------|
| `scripts/build-app.sh` | 从 SPM 构建 `.app` Bundle |
| `scripts/release.sh` | 归档 + 签名 + DMG + 可选公证 |
| `scripts/make-dmg.sh` | 从 `.app` 制作带图标和布局的 DMG |

## CI

| 工作流 | 触发条件 | 内容 |
|--------|----------|------|
| `ci.yml` | Push / PR 到 `main` | 编译 + 测试 |
| `release.yml` | `git tag v*` | 签名 + 公证 + DMG + GitHub Release |

## 相关项目

- [AI Pulse Chrome 扩展](https://github.com/wxy/ai-pulse) — 覆盖网页端 AI 工具（ChatGPT、Claude.ai、DeepSeek Chat 等）

## 许可证

Apache-2.0
