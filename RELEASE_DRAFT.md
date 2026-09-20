# AI Pulse 2.0.0 — One Pulse Across Mac, iPhone, and Apple Watch

> Draft only. Publish only after App Store approval.

## What's New

- A unified, fact-first AI activity dashboard across Mac, iPhone, and Apple Watch.
- Native macOS and iPhone widgets, an Apple Watch companion app, and ten Watch widget presentations for glanceable access.
- Independent Today, This Week, and 30 Days snapshots with aligned token and local Git rhythms.
- Tool, model, repository, captured-session, observed balance, quota, and declared-subscription details without fabricated cost estimates.
- Ten complete interface localizations: English, Simplified Chinese, Traditional Chinese for Taiwan and Hong Kong, Japanese, Korean, German, French, Spanish, and Brazilian Portuguese.

## Fixes & Engineering

- Kept current activity separate from historical summaries and stopped presenting missing or stale observations as zero usage.
- iPhone and Watch widgets retain the last observed activity and its timestamp after expiration, with reduced emphasis instead of replacing it with “no data.”
- Dashboard footers now distinguish the last collection time from the last CloudKit synchronization time; synchronization failures use a warning indicator.
- Reopening the macOS dashboard now revalidates its resident snapshot, so a previous-day or stale chart refreshes without switching ranges.
- Removed the non-actionable partial-resource warning from the dashboard.
- Localized percentage formatting now uses the platform number-formatting APIs rather than a literal percent placeholder.
- Completed privacy manifests, target resource membership, extension embedding, localization validation, and the 2.0 code audit.

## Deployment Notes

- Version: 2.0.0 (build 32).
- Upload two archives: the macOS archive includes the native macOS widget; the iOS archive includes the iPhone widget, Watch app, and Watch widget.
- Before App Store release, deploy and verify the `DashboardCache_v2` schema and the `current-pulse` records in the CloudKit Production environment.
- No Russian localization is included. `Tokens`, `Lines`, currency codes, and explicit product identifiers intentionally remain stable where specified.
- `Sources/Localizable.xcstrings` is the localization source of truth.

## Verification

- Localization: 738 active keys across 10 locales; no missing translations, stale entries, placeholder mismatches, Russian entries, or raw percentage formats.
- Tests: `make test` — 434 executed, 4 optional real-data tests skipped, 0 failures.
- Builds: unsigned, isolated Release builds passed for macOS arm64, iOS Simulator, and watchOS Simulator.
- Product inspection: all app surfaces package the expected localization bundles and privacy manifests; the two host archives embed their required extensions.
- Device acceptance: macOS, macOS widget, iPhone, iPhone widget, Watch app, and Watch widgets passed user acceptance testing.

---

# AI Pulse 2.0.0 — Mac、iPhone 与 Apple Watch 的统一脉搏

> 仅为草案。App Store 审核通过前不得公开发布。

## 新功能

- 在 Mac、iPhone 与 Apple Watch 上提供统一、事实优先的 AI 活动仪表盘。
- 原生 macOS 与 iPhone 小组件、Apple Watch 伴侣应用，以及十种可快速查看的 Watch 小组件呈现。
- 今日、本周与 30 天使用独立快照，并对齐词元活动与本地 Git 成果节奏。
- 展示工具、模型、仓库、已捕获会话、已观测余额、额度及声明订阅，不虚构费用估算。
- 完成 10 种界面语言：英语、简体中文、台湾繁体中文、香港繁体中文、日语、韩语、德语、法语、西班牙语和巴西葡萄牙语。

## 修复与工程改进

- 当前活动与历史摘要保持独立，不再把缺失或过期观察显示为零使用量。
- iPhone 与 Watch 小组件在观察过期后保留最后一次活动及其时间，以降低强调度代替“没有数据”。
- 仪表盘页脚明确区分最后采集时间与最后 CloudKit 同步时间；同步失败以警告图标提示。
- 重新打开 macOS 仪表盘时会复核驻留快照，跨日或陈旧图表无需切换周期即可刷新。
- 移除用户无法处理的“部分资源组成缺失”仪表盘提示。
- 百分比本地化改用系统数字格式化 API，不再使用字面百分号占位符。
- 完成隐私清单、target 资源成员关系、扩展嵌入、国际化完整性检查和 2.0 代码审计。

## 部署说明

- 版本：2.0.0（构建 32）。
- 只需上传两个归档：macOS 归档包含原生 macOS 小组件；iOS 归档包含 iPhone 小组件、Watch 应用和 Watch 小组件。
- 提交 App Store 前，在 CloudKit Production 环境部署并核对 `DashboardCache_v2` schema 与 `current-pulse` 记录。
- 不包含俄语。`Tokens`、`Lines`、货币代码及明确指定的产品标识按约定保持稳定。
- `Sources/Localizable.xcstrings` 是国际化的唯一事实源。

## 验证

- 国际化：738 个有效词条、10 种语言；无缺失翻译、陈旧条目、占位符不匹配、俄语条目或原始百分号格式。
- 测试：`make test` 共执行 434 项，4 项可选真实数据测试跳过，0 失败。
- 构建：macOS arm64、iOS Simulator 与 watchOS Simulator 的隔离未签名 Release 构建均通过。
- 产品检查：各应用界面均打包预期的本地化资源与隐私清单；两个宿主归档均嵌入所需扩展。
- 真机验收：macOS、macOS 小组件、iPhone、iPhone 小组件、Watch 应用和 Watch 小组件均已通过用户验收。

## Store Copy Handoff

- Version: 2.0.0 (build 32)
- Platforms: macOS, iPhone, Apple Watch, and their widgets
- Core themes: unified activity pulse, fact-first dashboard, cross-device private iCloud sync, local Git companion output, ten interface languages
- Required deployment note: verify the `DashboardCache_v2` Production schema before submission
- Publication boundary: GitHub Release remains a draft until App Store approval
