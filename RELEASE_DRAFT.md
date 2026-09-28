# AI Pulse 2.0.1 — Performance and Stability

**Download AI Pulse on the [Mac App Store](https://apps.apple.com/us/app/ai-pulse/id6786290416?mt=12).**

## What's New

- Mac refreshes are lighter when reading local activity and Git repositories.
- Gemini CLI local logs can now contribute to activity when the logs are available and access is granted.
- Medium and large iPhone widgets make Today, This Week, and 30 Days easier to scan, with clearer accessibility summaries.

## Fixes & Engineering

- Reduced repeated log and Git reads, bounded repository rescans, and moved startup backfill and filesystem probes away from the main thread.
- Improved CloudKit conflict handling, stale cache recovery, database migration reporting, and local folder access recovery.
- Fixed ingestion edge cases, export precision and failure cleanup, and iPhone widget and deep-link regressions.

## Deployment Notes

- Version 2.0.1 (build 33) covers macOS, iPhone, Apple Watch, and their widgets.
- The macOS archive embeds the Mac widget. The iOS archive embeds the iPhone widget and Watch app, which embeds the Watch widget.
- The CloudKit record schema and snapshot payload version are unchanged from 2.0.0. The Production schema was checked for 2.0; 2.0.1 requires no new schema deployment or repeat Production schema check.

## Verification

- [CI on released commit `dfc4594`](https://github.com/wxy/ai-pulse-macos/actions/runs/36412787720) passed static analysis and macOS Swift package tests.
- [iPhone widget layout](https://github.com/wxy/ai-pulse-macos/blob/dfc4594/docs/verification/pr-91-widget-layout-e2e-2026-09-28.md) passed a signed iPhone Simulator build and visual inspection. [Deep-link routing](https://github.com/wxy/ai-pulse-macos/blob/dfc4594/docs/verification/pr-91-ios-deeplink-e2e-2026-09-28.md) was checked in the Simulator.
- The release owner confirmed that final 2.0.1 archive and physical-device acceptance checks passed.

---

# AI Pulse 2.0.1 — 性能与稳定性

**前往 [Mac App Store](https://apps.apple.com/us/app/ai-pulse/id6786290416?mt=12) 下载 AI Pulse。**

## 本次改进

- Mac 读取本地活动和 Git 仓库时刷新更轻快。
- 在日志可用且已获授权时，Gemini CLI 的本地日志也可以计入活动。
- iPhone 中号和大号小组件让今日、本周与 30 天数据更易浏览，辅助功能摘要也更清晰。

## 修复与工程改进

- 减少重复读取日志与 Git 数据，限制仓库重新扫描，并将启动时的历史补录和文件系统检查移出主线程。
- 改进 CloudKit 冲突处理、过期缓存恢复、数据库迁移报错及本地文件夹授权恢复。
- 修复采集边界情况、导出精度与失败清理，以及 iPhone 小组件和深度链接的问题。

## 部署说明

- 版本 2.0.1（构建 33），覆盖 macOS、iPhone、Apple Watch 及其小组件。
- macOS 归档内含 Mac 小组件；iOS 归档内含 iPhone 小组件与 Watch 应用，Watch 应用内含 Watch 小组件。
- CloudKit 记录 schema 和快照载荷版本与 2.0.0 相同。生产环境 schema 已在 2.0 检查，2.0.1 无需重新部署或重复检查。

## 验证

- 已发布提交 `dfc4594` 的 [CI](https://github.com/wxy/ai-pulse-macos/actions/runs/36412787720) 已通过静态检查和 macOS Swift Package 测试。
- [iPhone 小组件布局](https://github.com/wxy/ai-pulse-macos/blob/dfc4594/docs/verification/pr-91-widget-layout-e2e-2026-09-28.md)通过签名的 iPhone 模拟器构建与画面检查；[深度链接](https://github.com/wxy/ai-pulse-macos/blob/dfc4594/docs/verification/pr-91-ios-deeplink-e2e-2026-09-28.md)已在模拟器验证。
- 发布负责人已确认 2.0.1 的最终归档及真机验收通过。

## Store Copy Handoff

- Version: 2.0.1 (build 33)
- Platforms: macOS, iPhone, Apple Watch, and their widgets
- Core themes: lighter Mac refreshes, more reliable collection and synchronization, Gemini CLI log support, clearer medium and large iPhone widgets
- Deployment note: CloudKit record schema and snapshot payload version are unchanged from 2.0.0; no repeat Production schema check is needed for 2.0.1
- Verification: released-commit CI and iPhone Simulator evidence are linked above; release owner confirmed final archive and physical-device acceptance
- Publication status: 2.0.1 is released
