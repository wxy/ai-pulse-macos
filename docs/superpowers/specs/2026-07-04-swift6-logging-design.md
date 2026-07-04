# Swift 6 迁移 & 日志系统 — 设计规格

> 日期：2026-07-04 | 分支：feature/swift6-and-logging

## Part 1: Swift 6 迁移

### 现状

- Package.swift: `swift-tools-version: 5.9`
- 本地编译器: Swift 6.3.3（严格并发检查未启用）
- `@preconcurrency import AppKit` 在 2 个文件中遮蔽 Sendable 警告
- 15 处裸 `Task {}`，无 actor 绑定
- 15 个 `class`，0 处 `@MainActor`，0 个 `actor`
- 只有 `AppDatabase.write/read` 标注了 `@Sendable`

### 策略：渐进式迁移（3 步，每步可编译）

#### Step 1: 升级声明 + 临时标记

- Package.swift: `swift-tools-version: 5.9` → `6.0`
- 对无法立即修复的 class 添加 `@unchecked Sendable`，让编译通过：
  - `AppDelegate` — NSApplicationDelegate 回调
  - `MenuBarController` — NSObject + #selector
  - `DockManager` — 通知回调 + Task
  - `DataRefreshCoordinator` — DispatchSourceTimer + 串行队列保证安全
  - `LogWatcher`、`GitMonitor`、`ApiPoller` — 各自有内部队列
- 裸 `Task {}` 加 `@MainActor` 标注（UI 相关）或 `Task { @MainActor in }` 闭包

#### Step 2: 逐文件收紧（后续 PR）

- 移除 `@unchecked Sendable`，替换为正确的并发模型
- UI 层 → `@MainActor class`
- 数据层 → 保持 `@Sendable` closure

#### Step 3: 清理 `@preconcurrency`（后续 PR）

- 移除 `@preconcurrency import AppKit`
- 确保所有 AppKit 调用都在 `@MainActor` 上下文中

### 影响范围

| 文件 | Step 1 改动 |
|------|------------|
| `Package.swift` | 版本号 5.9 → 6.0 |
| `App/AIPulseApp.swift` | AppDelegate: `@unchecked Sendable`；删除 diagLog() |
| `UI/MenuBar/MenuBarController.swift` | MenuBarController: `@unchecked Sendable` |
| `UI/Dock/DockManager.swift` | DockManager: `@unchecked Sendable` |
| `Engine/DataRefreshCoordinator.swift` | DataRefreshCoordinator: `@unchecked Sendable` |
| `Ingest/LogWatcher.swift` | LogWatcher: `@unchecked Sendable` |
| `GitMonitor/GitMonitor.swift` | GitMonitor: `@unchecked Sendable` |
| `Ingest/ApiPoller.swift` | ApiPoller: `@unchecked Sendable` |

---

## Part 2: 日志系统

### 设计目标

1. Debug 构建：详细日志帮助开发者诊断
2. Release 构建：只记录重要事件（info+），供用户反馈时排查
3. 统一 API，替换所有 `print()` 和 `diagLog()`
4. 零开销 debug 日志（Release 编译时完全移除）

### 日志级别

| 级别 | 语义 | Debug | Release |
|------|------|-------|---------|
| `debug` | 详细诊断信息 | → 文件 + 控制台 | ❌ 编译期排除 |
| `info` | 关键事件 | → 文件 + 控制台 | → 文件 |
| `warning` | 可恢复异常 | → 文件 + 控制台 | → 文件 |
| `error` | 错误 | → 文件 + 控制台 | → 文件 + OSLog |

### 输出目标

```
Debug 构建:
  ~/Library/Logs/AIPulse/aipulse-debug.log  (所有级别)
  控制台 NSLog (所有级别)

Release 构建:
  ~/Library/Logs/AIPulse/aipulse.log  (info+)
  OSLog (error 级别，Console.app 可查)
```

### API

```swift
enum Logger {
    static func debug(_ msg: String)   // #if DEBUG — Release 中完全不存在
    static func info(_ msg: String)
    static func warning(_ msg: String)
    static func error(_ msg: String)
}
```

文件写入策略：串行后台队列 + 每次写入后 fsync（防止崩溃丢日志）。日志文件超过 1MB 自动滚动（保留最近一个 .old 文件）。

### 现有日志迁移

共 33 处，按级别分类：

| 现有调用 | 数量 | 新调用 |
|---------|------|--------|
| `diagLog("started/stopped/posting/suppressing/combinedSpend")` | 13 | `Logger.info/debug(...)` |
| `print("DB opened/✓/✗/migration")` | 5 | `Logger.info/error(...)` |
| `print("ApiPoller[...]: ok")` | 2 | `Logger.info(...)` |
| `print("...failed...")` | 5 | `Logger.error(...)` |
| `print("AnomalyDetector/StatsService error")` | 4 | `Logger.error(...)` |
| `print("PricingCatalog: ...")` | 3 | `Logger.warning/error(...)` |
| `print("SIGHUP/Claude projects...")` | 2 | `Logger.info(...)` |

迁移后删除 `AIPulseApp.swift` 中的 `diagLog()` 函数、`diagQueue`、`diagLogFile`。

---

## 实施顺序

```
Step 1: 新建 Sources/Utils/Logger.swift
Step 2: 升级 Package.swift → swift-tools-version 6.0
Step 3: 批量添加 @unchecked Sendable（使编译通过）
Step 4: 逐文件迁移 print/diagLog → Logger
Step 5: 删除 AIPulseApp.swift 中的 diagLog() 函数
Step 6: 编译验证 + 运行测试
```

每步均可独立编译通过。
