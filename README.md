<p align="center"><img src="assets/readme/hero.svg" width="100%" alt="AI Pulse — AI 编程花费追踪仪"></p>

<p align="center">
  <img src="assets/readme/icon-rounded.png" width="96" height="96" alt="AI Pulse App Icon">&nbsp;
  <a href="https://apps.apple.com/us/app/ai-pulse/id6786290416?mt=12"><img src="assets/readme/download-button-appstore-mac.svg" width="360" height="82" alt="Download on the Mac App Store"></a>&nbsp;
  <a href="https://apps.apple.com/us/app/ai-pulse-coding-cost-tracker/id6786290416?mt=8"><img src="assets/readme/download-button-appstore-ios.svg" width="360" height="82" alt="Download on the iOS App Store"></a>
</p>

<p align="center"><code>SWIFTUI · SWIFT 6 · MACOS 14+ · IOS 16+</code></p>

<p align="center">
  [![CI](https://github.com/wxy/ai-pulse-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/wxy/ai-pulse-macos/actions/workflows/ci.yml)
  [![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
  [![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20%2F%20iOS%2016%2B-lightgrey)]()
  [![Swift](https://img.shields.io/badge/swift-6.0-orange)]()
</p>

<p align="center"><img src="assets/readme/section-screens.svg" width="100%" alt="Screens · 截图"></p>

**macOS**

|  | 中文 | English |
|:---:|:---:|:---:|
| **仪表盘 · 今日 / Dashboard · Today** | <img src="docs/screenshots/macos-dashboard-today-zh.jpg" alt="仪表盘今日" width="420"> | <img src="docs/screenshots/macos-dashboard-today-en.jpg" alt="Dashboard Today" width="420"> |
| **仪表盘 · 30 天 / Dashboard · 30 Days** | <img src="docs/screenshots/macos-dashboard-30d-zh.jpg" alt="仪表盘30天" width="420"> | <img src="docs/screenshots/macos-dashboard-30d-en.jpg" alt="Dashboard 30 Days" width="420"> |
| **欢迎 · 授权 / Onboarding · Access** | <img src="docs/screenshots/macos-onboarding-access-zh.jpg" alt="欢迎授权" width="420"> | <img src="docs/screenshots/macos-onboarding-access-en.jpg" alt="Onboarding Access" width="420"> |
| **设置 · AI 服务商 / Settings · AI Providers** | <img src="docs/screenshots/macos-settings-providers-zh.jpg" alt="设置AI服务商" width="420"> | <img src="docs/screenshots/macos-settings-providers-en.jpg" alt="Settings AI Providers" width="420"> |
| **设置 · 开发工具 / Settings · Dev Tools** | <img src="docs/screenshots/macos-settings-devtools-zh.jpg" alt="设置开发工具" width="420"> | <img src="docs/screenshots/macos-settings-devtools-en.jpg" alt="Settings Dev Tools" width="420"> |
| **设置 · 仓库 / Settings · Repos** | <img src="docs/screenshots/macos-settings-repos-zh.jpg" alt="设置仓库" width="420"> | <img src="docs/screenshots/macos-settings-repos-en.jpg" alt="Settings Repos" width="420"> |

**iOS**

|  | 中文 | English |
|:---:|:---:|:---:|
| **仪表盘 · 今日 / Dashboard · Today** | <img src="docs/screenshots/ios-dashboard-today-zh.jpg" alt="iOS 仪表盘今日" width="220"> | <img src="docs/screenshots/ios-dashboard-today-en.jpg" alt="iOS Dashboard Today" width="220"> |
| **仪表盘 · 30 天 / Dashboard · 30 Days** | <img src="docs/screenshots/ios-dashboard-30d-zh.jpg" alt="iOS 仪表盘30天" width="220"> | <img src="docs/screenshots/ios-dashboard-30d-en.jpg" alt="iOS Dashboard 30 Days" width="220"> |

**watchOS**

|  | 中文 | English |
|:---:|:---:|:---:|
| **首页 / Home** | <img src="docs/screenshots/watchos-home-zh.jpg" alt="watchOS 首页" width="160"> | <img src="docs/screenshots/watchos-home-en.jpg" alt="watchOS Home" width="160"> |

<p align="center"><img src="assets/readme/section-download.svg" width="100%" alt="Download · 下载"></p>

**Universal Purchase — buy once, use on both platforms.** A single purchase covers macOS and iOS. If you already own one version and still see a price button on the other, don't worry — as long as you're signed in with the same Apple ID, the App Store recognizes your existing purchase and lets you download for free. You will never be charged twice.

> **多平台通用购买（Universal Purchase）—— 一次购买，iOS 与 macOS 通用。** 如果您已经购买了 Mac 版，在 iPhone / iPad 上下载时仍看到价格按钮，请不要担心：只要使用同一个 Apple ID，直接点击购买即可，系统会自动识别您的购买记录并提示「免费下载」，绝不会向您重复扣费。

- **macOS** — requires macOS 14 Sonoma or later
    > **macOS 版** — 需要 macOS 14 Sonoma 或更高版本
- **iOS** — requires iOS 16 or later, and the macOS version as its data source
    > **iOS 版** — 需要 iOS 16 或更高版本，以及 macOS 版作为数据来源

<p align="center"><img src="assets/readme/section-features.svg" width="100%" alt="Features · 功能"></p>

**Dashboard** — your home screen, styled as a robot head, shows the full picture at a glance.

> **仪表盘** — 以机器人头像为主视觉的主窗口，一目了然。

- **Today / This Week / 30 Days** — switch time ranges with one click
    > **今日 / 本周 / 30 天** — 一键切换时间范围
- **Donut chart** — subscription vs. API spending split, plus a per-provider breakdown
    > **环形图** — 订阅 vs API 花费分布，外加各服务商明细
- **Trend chart** — daily costs stacked by API + subscription (Week and 30 Days tabs)
    > **趋势图** — 每日 API + 订阅花费堆叠展示（本周 / 30 天页签）
- **Tool & repo ranking** — which AI tools and projects cost the most, with **Cost Per Line (CPL)**
    > **工具 & 仓库排行** — 哪些 AI 工具和项目烧钱最多，含 **CPL（代码行成本）**
- **Live stats** — net lines of code, added/deleted lines, request count, and token usage
    > **实时统计** — 净增代码行、增/删行数、请求次数、Token 用量
- **Balances & quotas** — remaining API balance and subscription utilization (e.g. Claude, Copilot) on the Today tab
    > **余额 & 额度** — 今日页签显示 API 余额与订阅用量（如 Claude、Copilot）

**Dock** — the Dock icon is a living gauge for your spending.

> **Dock 图标** — Dock 图标是你的「活」花费仪表。

- **Spending ring** — a progress ring around the icon fills with today's spend vs. your daily rate
    > **花费进度环** — 图标周围的光环随今日花费 vs 日均费率填充
- **Badge** — today's total, right on the icon
    > **角标** — 图标上直接显示今日总额
- **Right-click stats menu** — today/week summaries and drill-downs by tool, provider, and repo
    > **右键统计菜单** — 今日/本周概览，以及按工具、服务商、仓库下钻
- **Gold pulse** — a brief glow whenever new data arrives
    > **金色脉冲** — 新数据到达时的一抹光晕

**iOS Companion** — a read-only companion that mirrors your spending to your iPhone or iPad via iCloud: today, this week, 30-day trends, donut charts, and per-repo breakdowns. It never collects or uploads anything on its own; it only reads what your Mac has synced.

> **iOS 伴侣应用** — 只读伴侣应用，通过 iCloud 将花费镜像到你的 iPhone / iPad —— 今日、本周、30 天趋势、环形图、按仓库明细。它自身不采集、不上传任何数据，只读取 Mac 同步过来的内容。

**Supported Tools** — AI Pulse tracks 13 AI tools today across three collection methods.

> **支持的工具** — 目前追踪 13 款 AI 工具，通过三种采集方式。

| Collection method<br>采集方式 | Tools<br>工具 |
|---|---|
| **Log parsing** (token-level)<br>**日志解析**（Token 级计价） | Claude Code、aider、OpenCode、Qwen Code |
| **Balance API** (exact deltas)<br>**余额 API**（精确余额差值） | DeepSeek、Kimi、智谱（ChatGLM）、Anthropic\* |
| **Subscription detection** (monthly fee amortized)<br>**订阅检测**（月费按天摊销） | Cursor、GitHub Copilot、Windsurf（+ Trae、Augment Code） |

\* Anthropic has no balance API, so its usage is estimated from token pricing.

> \* Anthropic 无余额 API，其用量按 Token 计价估算。

<p align="center"><img src="assets/readme/section-getting-started.svg" width="100%" alt="Getting Started · 快速上手"></p>

1. **Install** — download from the Mac App Store (requires macOS 14 or later).
    > **安装** — 从 Mac App Store 下载（需要 macOS 14 或更高版本）。
2. **Onboarding** — on first launch, a short walkthrough detects your installed AI tools across four steps: AI providers, dev tools, repos, and a summary. Detected tools are enabled automatically.
    > **首次引导** — 首次启动的四步引导会检测你已安装的 AI 工具：AI 服务商、开发工具、仓库、完成。检测到的工具会自动启用。
3. **Grant Home access** — to read logs from Claude Code, Codex, OpenCode, Qwen, and aider inside the sandbox, allow Home-folder access when prompted.
    > **授权主目录访问** — 在沙盒环境下读取 Claude Code、OpenCode、Qwen 和 aider 的日志时，按提示允许访问主目录。
4. **Add API keys** — Settings → Integrations → **AI Providers**. Keys are stored locally and validated with a live balance check.
    > **添加 API Key** — 设置 → 集成 → **AI 服务商**。Key 仅保存在本地，并通过实时余额校验验证。
5. **Choose plans** — Settings → Integrations → **Dev Tools** lets you pick your subscription plan (e.g. Cursor Pro).
    > **选择订阅方案** — 设置 → 集成 → **开发工具**，选择你的订阅方案（如 Cursor Pro）。
6. **Explore the Dashboard** — switch between Today, This Week, and 30 Days.
    > **浏览仪表盘** — 在今日、本周、30 天之间切换。
7. **Right-click the Dock icon** anytime for a quick stats menu.
    > **随时右键 Dock 图标** 查看快速统计菜单。
8. **On the go?** Install the iOS companion with the same Apple ID — your spending syncs automatically via iCloud.
    > **手机查看？** 使用同一 Apple ID 安装 iOS 伴侣应用 —— 花费会自动通过 iCloud 同步。

<p align="center"><img src="assets/readme/section-privacy.svg" width="100%" alt="Data & Privacy · 数据与隐私"></p>

- **100% local** — everything is processed on your Mac; no data leaves your machine.
    > **100% 本地运行** — 一切都在你的 Mac 上处理，数据绝不出设备。
- **API keys** are stored locally and used only to query your own balances.
    > **API Key** 仅保存在本地，只用于查询你自己的余额。
- **iOS companion is read-only** — it never collects anything itself, and iCloud sync happens only between your own devices signed in with the same Apple ID.
    > **iOS 伴侣为只读** — 它自身不采集任何数据；iCloud 同步只发生在使用同一 Apple ID 登录的你自己的设备之间。

<p align="center"><img src="assets/readme/section-requirements.svg" width="100%" alt="Requirements · 环境要求"></p>

- macOS 14 Sonoma or later
    > macOS 14 Sonoma 或更高版本
- The iOS companion requires iOS 16 or later (plus the macOS version as its data source)
    > iOS 伴侣需要 iOS 16 或更高版本（并以 macOS 版作为数据来源）

<p align="center"><img src="assets/readme/section-related.svg" width="100%" alt="Related Projects · 相关项目"></p>

- [AI Pulse for Chrome](https://github.com/wxy/ai-pulse) — browser extension for web-based AI tools (ChatGPT, Claude.ai, DeepSeek Chat, and more)
    > [AI Pulse Chrome 扩展](https://github.com/wxy/ai-pulse) — 覆盖网页端 AI 工具（Claude.ai、DeepSeek Chat 等）

<p align="center"><img src="assets/readme/section-contributing.svg" width="100%" alt="Contributing · 参与贡献"></p>

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, architecture, and how to add new integrations.

> 开发环境搭建、架构说明、如何新增集成，请参阅 [CONTRIBUTING.md](CONTRIBUTING.md)。

<p align="center"><img src="assets/readme/section-license.svg" width="100%" alt="License · 许可证"></p>

Released under the [Apache License 2.0](LICENSE).

> 本项目基于 [Apache License 2.0](LICENSE) 发布。
