# AI Pulse 2.0.1 — Performance and Stability

> Draft release. Publish after App Store approval.

## What's New

- Mac refreshes are lighter when reading local activity and Git repositories.
- Small dashboard and iPhone widget refinements make Today, This Week, and 30 Days easier to scan; medium and large widgets also have clearer accessibility summaries.

## Fixes & Engineering

- Reduced repeated log and Git reads, bounded repository rescans, and moved startup backfill and filesystem probes away from the main thread.
- Improved CloudKit conflict handling, stale cache recovery, database migration reporting, and local folder access recovery.
- Fixed ingestion edge cases, export precision and failure cleanup, and iPhone widget and deep-link regressions.

## Deployment Notes

- Version 2.0.1 (build 33) covers macOS, iPhone, Apple Watch, and their widgets.
- The macOS archive embeds the Mac widget. The iOS archive embeds the iPhone widget and Watch app, which embeds the Watch widget.
- Before App Store submission, verify the `DashboardCache_v2` schema and `current-pulse` records in CloudKit Production.
- This GitHub Release is a draft. The source tag and store builds are held until the release process is complete.

## Verification

- [CI on merged `main` commit `dfc4594`](https://github.com/wxy/ai-pulse-macos/actions/runs/36412787720) passed static analysis and macOS Swift package tests.
- [iPhone widget layout](https://github.com/wxy/ai-pulse-macos/blob/dfc4594/docs/verification/pr-91-widget-layout-e2e-2026-09-28.md) passed a signed iPhone Simulator build and visual inspection. [Deep-link routing](https://github.com/wxy/ai-pulse-macos/blob/dfc4594/docs/verification/pr-91-ios-deeplink-e2e-2026-09-28.md) was checked in the Simulator.
- Final 2.0.1 App Store archives, production CloudKit checks, and physical-device acceptance remain release gates.

---

# AI Pulse 2.0.1 — 性能与稳定性

> 发布草稿。App Store 审核通过后再公开发布。

## 本次改进

- Mac 读取本地活动和 Git 仓库时刷新更轻快。
- 小幅调整仪表盘和 iPhone 小组件，让今日、本周与 30 天数据更易浏览；中号和大号小组件的辅助功能摘要也更清晰。

## 修复与工程改进

- 减少重复读取日志与 Git 数据，限制仓库重新扫描，并将启动时的历史补录和文件系统检查移出主线程。
- 改进 CloudKit 冲突处理、过期缓存恢复、数据库迁移报错及本地文件夹授权恢复。
- 修复采集边界情况、导出精度与失败清理，以及 iPhone 小组件和深度链接的问题。

## 部署说明

- 版本 2.0.1（构建 33），覆盖 macOS、iPhone、Apple Watch 及其小组件。
- macOS 归档内含 Mac 小组件；iOS 归档内含 iPhone 小组件与 Watch 应用，Watch 应用内含 Watch 小组件。
- 提交 App Store 前，核对 CloudKit Production 环境中的 `DashboardCache_v2` schema 和 `current-pulse` 记录。
- GitHub Release 目前是草稿；源码标签和商店构建待发布流程完成后再处理。

## 验证

- 合并后的 [`main` 提交 `dfc4594` 的 CI](https://github.com/wxy/ai-pulse-macos/actions/runs/36412787720) 已通过静态检查和 macOS Swift Package 测试。
- [iPhone 小组件布局](https://github.com/wxy/ai-pulse-macos/blob/dfc4594/docs/verification/pr-91-widget-layout-e2e-2026-09-28.md)通过签名的 iPhone 模拟器构建与画面检查；[深度链接](https://github.com/wxy/ai-pulse-macos/blob/dfc4594/docs/verification/pr-91-ios-deeplink-e2e-2026-09-28.md)已在模拟器验证。
- 2.0.1 最终 App Store 归档、CloudKit 生产环境检查和真机验收仍属于发布前检查项。

## Store Copy Handoff

- Version: 2.0.1 (build 33)
- Platforms: macOS, iPhone, Apple Watch, and their widgets
- Core themes: lighter Mac refreshes, more reliable collection and synchronization, small dashboard and widget refinements
- Required deployment note: verify `DashboardCache_v2` and `current-pulse` in CloudKit Production before App Store submission
- Verification boundary: merged-main CI and iPhone Simulator evidence; final archives, production CloudKit, and physical devices remain unchecked for 2.0.1
- Publication boundary: keep this GitHub Release as a draft until App Store approval
