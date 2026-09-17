<p align="center"><img src="assets/readme/hero.svg" width="100%" alt="AI Pulse — AI 消费脉搏"></p>

<p align="center">
  <img src="assets/readme/icon-rounded.png" width="96" height="96" alt="AI Pulse App Icon">&nbsp;
  <a href="https://apps.apple.com/us/app/ai-pulse/id6786290416?mt=12"><img src="assets/readme/download-button-appstore-mac.svg" width="300" height="69" alt="Mac App Store listing"></a>
</p>

<p align="center"><code>MACOS 14+ · SWIFTUI · SWIFT 6 · 2.0 IN DEVELOPMENT</code></p>

<p align="center">
  <a href="https://github.com/wxy/ai-pulse-macos/actions/workflows/ci.yml"><img src="https://github.com/wxy/ai-pulse-macos/actions/workflows/ci.yml/badge.svg" alt="CI"></a>&nbsp;
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue" alt="License"></a>&nbsp;
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey" alt="macOS platform">
</p>

AI Pulse makes ongoing AI activity tangible and shows the local Git output alongside it. A consumption pulse, not a precise meter, invoice, or verdict on whether your work was worth the money.

> AI Pulse 让持续的 AI 活动被感受到，并展示伴随的本地 Git 成果。它是消费脉搏，不是精确计量器、账单，也不判断产出是否值得。

This README describes the macOS 2.0 development direction. Implementation and automated checks are progressing; runtime, visual, sound, and cloud acceptance are not complete. The App Store listing above does not imply these changes are released. iOS, watchOS, and Widget development is paused until macOS is ready.

> 本文描述 macOS 2.0 开发方向。代码与自动检查持续推进，但实际运行、视觉、声音和云端验收尚未完成。上方商店入口不代表这些改动已经发版；macOS 达标前暂停 iOS、watchOS 和 Widget 开发。

<p align="center"><img src="assets/readme/section-features.svg" width="100%" alt="Features · 功能"></p>

- **Robot dashboard** — Today, This Week, and 30 Days keep independent snapshots. The eyes show tool and authorized-repository token shares; the nose shows Git output; the mouth pairs token and code rhythms.

    > **机器人仪表盘** — 今日、本周、30 天保留独立快照。双眼表示工具与授权仓库的词元份额，鼻子表示 Git 成果，嘴部对应词元与代码节奏。

- **Aligned rhythms** — local hourly activity today, seven daily slots this week, thirty daily slots over 30 days. Empty activity keeps a segmented placeholder; unknown collection is not healthy zero.

    > **对齐的节奏** — 今日按本地小时，本周七个日槽位，30 天三十个日槽位。无活动保留分节占位；采集未知不等于健康的零。

- **Tools, models, and sessions** — all three periods offer tool/model and repository details. Model identity includes its provider; missing model or tool attribution stays visible. A text-labelled tool-detail entry opens session activity, without cost estimates.

    > **工具、模型与会话** — 三个周期均有工具模型与仓库明细。模型身份包含供应商，缺失模型或工具归属仍可见；带文字的详情入口解释会话活动，不展示估价。

- **Observable Git output** — commits are independent of changed lines, including zero-line and merge commits; changed-line statistics exclude merges. Only real Git roots within configured development directories count.

    > **可观察 Git 成果** — 提交独立于行数，包括零行数和合并提交；行数统计排除合并。仅纳入配置开发目录中的真实 Git 根。

- **Optional money and quota observations** — native-currency balance decreases are sampling-interval facts, not per-session charges. Declared monthly fees are separate 30-day context, not daily spending. Quotas retain source time and window boundaries.

    > **条件式金额与额度观察** — 原币余额下降是采样区间事实，不是会话扣费。声明月费仅为 30 天独立背景，不作每日消费；额度保留源时间和窗口边界。

- **Menu bar, Dock, and daily recap** — current pulse is separate from historical summaries. Ordinary refreshes do not manufacture consumption feedback. Daily recaps use structured facts that are rendered in the current language.

    > **菜单栏、Dock 与收盘回顾** — 当前脉搏与历史汇总分开，一般刷新不制造消费反馈；收盘保存结构化事实并按当前语言显示。

- **Sound controls** — consumption sounds, closing chime, and optional startup chime have separate controls. One-tap mute, quiet hours, volume, and consumption caps are grouped coherently; sound packs offer previews. No automatic system Focus/full-screen synchronization is promised.

    > **声音控制** — 消费提示、收盘钟和可选启动钟分别控制。一键静音、静音时段、音量与消费上限分组组织，声音包可试听；不承诺自动同步系统专注或全屏状态。

No token-price conversion, monthly-fee amortization, forecast bill, Cost Per Line, or PR/Release statistics. Token and output counters use K/M/G/T; decimals use one digit. Tool trailers are weak declarations, not proof of AI authorship.

> 不提供词元估价、月费摊销、预测账单、每行成本或 PR／Release 统计。词元与成果使用 K/M/G/T，带小数保留一位；工具 trailer 是弱声明，不是 AI 创作证明。

<p align="center"><img src="assets/readme/section-screens.svg" width="100%" alt="Screens · 截图"></p>

These retained screenshots show an older interface, not the current 2.0 dashboard. New screenshots must come from the validated running app; no mock data or legacy screenshots are presented as proof of acceptance.

> 保留截图展示历史界面，不代表当前 2.0 仪表盘。新截图须来自验收后的实际应用，不以模拟数据或旧截图证明达标。

| Historical macOS view<br>历史 macOS 界面 | 中文 | English |
|---|---|---|
| Today<br>今日 | <img src="docs/screenshots/macos-dashboard-today-zh.jpg" width="420" alt="Historical Today dashboard in Chinese"> | <img src="docs/screenshots/macos-dashboard-today-en.jpg" width="420" alt="Historical Today dashboard in English"> |
| 30 Days<br>30 天 | <img src="docs/screenshots/macos-dashboard-30d-zh.jpg" width="420" alt="Historical 30-day dashboard in Chinese"> | <img src="docs/screenshots/macos-dashboard-30d-en.jpg" width="420" alt="Historical 30-day dashboard in English"> |

<p align="center"><img src="assets/readme/section-download.svg" width="100%" alt="Download · 下载"></p>

The Mac App Store button links to the existing listing. This working tree is not a release announcement. See the [macOS acceptance plan](docs/macos-v2-closure-plan.md) before treating 2.0 as ready; new cloud contracts are not yet validated for paused companion clients.

> Mac App Store 按钮指向现有商店页面，本工作树不是发版公告。2.0 是否达标以 [macOS 验收计划](docs/macos-v2-closure-plan.md) 为准；新的云端契约尚未为暂停的伴侣客户端完成验证。

<p align="center"><img src="assets/readme/section-getting-started.svg" width="100%" alt="Getting Started · 快速上手"></p>

1. Use macOS 14 or later. For development setup and native dependencies, see [CONTRIBUTING.md](CONTRIBUTING.md).

    > 使用 macOS 14 或更高版本；开发环境与原生依赖见 [CONTRIBUTING.md](CONTRIBUTING.md)。

2. Grant the requested access to local tool logs and configure development directories containing Git repositories. A workspace directory by itself is not a repository.

    > 授权读取本地工具日志，并配置包含 Git 仓库的开发目录；工作区目录本身不是仓库。

3. Supported log adapters include Claude Code, Codex, DeepSeek Harness, aider, OpenCode, and Qwen Code. Availability depends on installed tools, log formats, and access permissions; missing data does not mean zero account usage.

    > 日志适配包括 Claude Code、Codex、DeepSeek Harness、aider、OpenCode 和 Qwen Code；可用性取决于安装、格式与授权，缺失数据不等于账户零用量。

4. API keys and plan declarations are optional enhancements, not prerequisites for sensing local AI activity. Chinese UI applies the China-region visibility policy; switch to English to configure OpenAI/Anthropic where supported.

    > API Key 和套餐声明是可选增强，不是感知本地活动的前提。中文界面采用中国区可见性规则；需要配置 OpenAI／Anthropic 时切换英文。

5. Compare the three periods, open tool details, and configure notification/sound preferences. Use one-tap mute whenever needed.

    > 查看三个周期、打开工具详情，并设置通知与声音偏好；需要时一键静音。

<p align="center"><img src="assets/readme/section-privacy.svg" width="100%" alt="Data & Privacy · 数据与隐私"></p>

Log and Git parsing happen locally. Provider balance/quota requests contact the relevant service; iCloud synchronization can send derived summaries, repository identifiers/paths, and current observations to the user's private CloudKit database. “Local parsing” does not mean no data ever leaves the Mac. Debug cloud writes are disabled.

> 日志与 Git 在本地解析。余额／额度请求会访问对应服务；iCloud 同步可将派生摘要、仓库身份／路径和当前观察发送到用户私有 CloudKit 数据库。“本地解析”不等于任何数据都不出设备；Debug 禁止云端写入。

API keys stay in local credential storage and are not part of dashboard snapshot payloads. Collection scope and cloud permissions still require runtime verification. Original user history is preserved; derived caches may be invalidated and rebuilt.

> API Key 保留在本地凭据存储，不进入仪表盘快照载荷。采集范围与云端权限仍需运行验证；保留用户原始历史，派生缓存可失效重建。

<p align="center"><img src="assets/readme/section-requirements.svg" width="100%" alt="Requirements · 环境要求"></p>

macOS 14+, Swift 6/Xcode development environment, and access to the supported local logs/repositories. CloudKit requires appropriate account, entitlement, and deployment configuration; build success alone does not verify it.

> macOS 14+、Swift 6／Xcode 开发环境，以及相应日志和仓库授权。CloudKit 需要账户、权限与部署配置，构建成功不证明云端可用。

<p align="center"><img src="assets/readme/section-related.svg" width="100%" alt="Related Projects · 相关项目"></p>

[AI Pulse for Chrome](https://github.com/wxy/ai-pulse) is a separate browser-extension project, not evidence of account-wide coverage here.

> [AI Pulse Chrome 扩展](https://github.com/wxy/ai-pulse) 是独立浏览器项目，不代表本应用具备账户全量覆盖。

<p align="center"><img src="assets/readme/section-contributing.svg" width="100%" alt="Contributing · 参与贡献"></p>

Read [the current product rules](docs/PRODUCT_DESIGN.md), [data semantics](docs/data-facts-and-surfaces.md), and [acceptance plan](docs/macos-v2-closure-plan.md). Historical money-first plans are archived, not implementation requirements. Do not upload local audio assets or infer AI authorship from Git output.

> 请先阅读 [现行产品规则](docs/PRODUCT_DESIGN.md)、[数据语义](docs/data-facts-and-surfaces.md) 与 [验收计划](docs/macos-v2-closure-plan.md)。历史金额优先方案不再作为实现要求；不要上传本地音频，也不要以 Git 成果推断 AI 创作。

<p align="center"><img src="assets/readme/section-license.svg" width="100%" alt="License · 许可证"></p>

Source code is released under [Apache License 2.0](LICENSE). Bundled audio has separate source/license terms; the source-code license does not relicense third-party media.

> 源代码采用 [Apache License 2.0](LICENSE)。应用音频遵守各自素材来源与许可，源代码许可证不会重新授权第三方媒体。
