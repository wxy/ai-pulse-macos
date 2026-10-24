# AI Pulse 2.0.2 — Safer Collection and Scan Recovery

## What's New

### macOS

- Follow symbolic links in local tool logs and development directories, with clearer guidance when the actual target folder needs authorization.
- See when the Mac is reading, parsing, or preparing local activity. Dashboard tooltips now fit their content.

### iOS and Apple Watch

- No client changes or new builds in this release. The iPhone app, Watch app, and their widgets remain at 2.0.1 (build 33).

### Shared

- No changes to the shared snapshot contract or CloudKit schema. Payload version remains 2.0.0; the macOS update does not require companion-client upgrades.

## Fixes & Engineering

### macOS

- Queue Git scans without dropping repositories when workers are busy, and resume completed diff work after time limits or restarts.
- Recover Claude historical cache-token backfills after interrupted writes, using durable replay checkpoints.
- Reduce repeated reads of large, unchanged log histories with a bounded cache, and avoid redundant CloudKit uploads caused by unstable content fingerprints.
- Harden local ingestion and folder-access error handling. Upgrade libgit2 from 1.9.0 to 1.9.7, including its fix for a known malicious-pack allocation vulnerability.

## Deployment Notes

- **macOS app and bundled Mac widget: 2.0.2 (build 34).** iPhone, Apple Watch, and their widgets remain at **2.0.1 (build 33)** and are not included in this release.
- CloudKit record types and snapshot payload version remain at the 2.0.0 contract. This release requires no CloudKit schema deployment or companion-client version bump.
- The Mac adds local Git diff-progress metadata and durable Claude replay preparation. Existing data stays in place; unfinished scanning and replay resume from saved progress.
- This is a release draft. The release owner will create the signed macOS Archive and upload it to App Store Connect after the preparation PR merges. Publish this GitHub Release after App Store approval.

## Verification

- [Security and scan-recovery fixes in PR #96](https://github.com/wxy/ai-pulse-macos/pull/96) passed directed filesystem/Git/SQLite end-to-end checks and [CI](https://github.com/wxy/ai-pulse-macos/actions/runs/40039502238): 550 package tests, 4 skipped, 0 failures, plus static analysis.
- Version preparation passed an unsigned arm64 macOS Release build with Xcode 27.1, including the Mac widget. Both built bundles report 2.0.2 (34); all iOS/watchOS target configurations remain 2.0.1 (33).
- Earlier changes have separate evidence for [symbolic-link access](https://github.com/wxy/ai-pulse-macos/blob/a5dbf438635c0d0a3c660eecccf38c0ad15cd772/docs/verification/symlink-access-2026-10-23.md), [local processing stages](https://github.com/wxy/ai-pulse-macos/blob/a5dbf438635c0d0a3c660eecccf38c0ad15cd772/docs/verification/local-processing-status-2026-10-23.md), and [tooltip layout](https://github.com/wxy/ai-pulse-macos/blob/a5dbf438635c0d0a3c660eecccf38c0ad15cd772/docs/verification/dashboard-tooltip-sizing-2026-10-23.md). Those scoped checks do not establish acceptance of the final distribution archive.
- Still pending: signed overwrite upgrade from 2.0.1 with real history, live CloudKit synchronization with existing 2.0.1 companion clients, final archive validation, and App Store review. No new iOS/watchOS release or runtime acceptance is claimed.

---

# AI Pulse 2.0.2 — 采集安全与扫描恢复

## 本次改进

### macOS

- 本地工具日志与开发目录支持跟随符号链接；真实目标目录需要额外授权时，提示更明确。
- Mac 展示读取、解析和准备本地活动的处理阶段；仪表盘提示框按内容调整尺寸。

### iOS 与 Apple Watch

- 本次没有客户端改动或新构建。iPhone、Watch 应用及其小组件保持 2.0.1（构建 33）。

### 公共部分

- 共享快照协议与 CloudKit schema 均未变更，载荷版本仍为 2.0.0；本次 Mac 更新不要求伴侣客户端同步升级。

## 修复与工程改进

### macOS

- Git 扫描在工作线程繁忙时排队，避免遗漏仓库；超时或重启后复用已完成的差异扫描进度。
- Claude 历史缓存词元回填采用持久检查点，在写入中断后可以继续恢复。
- 有界缓存减少大量未变日志的重复读取；稳定内容指纹，减少无实际内容变化的 CloudKit 上传。
- 加固本地采集与目录访问错误处理。libgit2 从 1.9.0 升级至 1.9.7，包含针对已知恶意 pack 内存分配漏洞的修复。

## 部署说明

- **macOS App 与内嵌 Mac 小组件：2.0.2（构建 34）。** iPhone、Apple Watch 及其小组件保持 **2.0.1（构建 33）**，不在本次发布范围内。
- CloudKit 记录类型与快照载荷继续使用 2.0.0 协议，无需部署新 schema，也无需为此升级伴侣客户端。
- Mac 新增本地 Git 差异扫描进度和 Claude 回填准备记录，保留现有数据；未完成的扫描与回填从持久进度继续。
- 当前为发布草稿。准备 PR 合入后，由发布负责人创建签名 macOS Archive 并上传 App Store Connect；App Store 审核通过后再公开 GitHub Release。

## 验证

- [PR #96 的安全与扫描恢复修复](https://github.com/wxy/ai-pulse-macos/pull/96)已通过定向文件系统／Git／SQLite 端到端检查与 [CI](https://github.com/wxy/ai-pulse-macos/actions/runs/40039502238)：550 项包测试，4 项跳过，0 失败，静态检查通过。
- 本次版本准备已通过 Xcode 27.1 的 arm64 macOS Release 无签名编译，包含 Mac 小组件。两个实际产物均为 2.0.2（34）；iOS／watchOS 所有 target 配置仍为 2.0.1（33）。
- 此前改动分别留有[符号链接访问](https://github.com/wxy/ai-pulse-macos/blob/a5dbf438635c0d0a3c660eecccf38c0ad15cd772/docs/verification/symlink-access-2026-10-23.md)、[本地处理阶段](https://github.com/wxy/ai-pulse-macos/blob/a5dbf438635c0d0a3c660eecccf38c0ad15cd772/docs/verification/local-processing-status-2026-10-23.md)与[提示框布局](https://github.com/wxy/ai-pulse-macos/blob/a5dbf438635c0d0a3c660eecccf38c0ad15cd772/docs/verification/dashboard-tooltip-sizing-2026-10-23.md)验证记录；这些定向结果不代表最终分发归档已验收。
- 待完成：2.0.1 真实历史的签名覆盖升级、与现有 2.0.1 伴侣客户端的真实 CloudKit 同步、最终归档校验与 App Store 审核。本次不发布 iOS／watchOS 更新，也不声明新增的这些平台运行验收。

## Store Copy Handoff

- Version: macOS 2.0.2 (build 34); tag v2.0.2
- Platforms: macOS app and its bundled Mac widget only
- Unchanged platforms: iPhone, Apple Watch, and their widgets stay at 2.0.1 (build 33)
- Shared changes: no shared snapshot-contract or CloudKit schema changes; payload version remains 2.0.0
- Core themes: safer local collection, symbolic-link target access guidance, visible local processing stages, recoverable Git scanning and Claude history replay, libgit2 security update
- Deployment: CloudKit record schema and payload version unchanged from 2.0.0; local Git progress migration and durable replay preparation happen on the Mac
- Verification: PR #96 directed end-to-end checks and CI passed; version-preparation unsigned macOS Release build and bundle metadata checks passed
- Pending acceptance: signed real-history upgrade, live sync with existing companion clients, final Archive validation, and App Store review
- Publication status: GitHub Release draft; owner-created Archive and App Store submission pending; publish GitHub Release after App Store approval
