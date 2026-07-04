# Data Refresh Coordination & UX Feedback — Design Spec

> 日期：2026-07-03
> 状态：已批准

## 问题概述

解决 4 个关联问题：

1. **新仓库未被识别**：仓库目录下新增仓库后，菜单和仪表盘不显示
2. **设置页重复扫描**：每次打开 Repos 设置页都做全量文件系统扫描
3. **数据刷新不协调**：多个独立定时器各自刷新，导致菜单、仪表盘、Dock 数据不一致
4. **音效/动画缺失**：音效仅在 ApiPoller（每小时）触发，缺少图标脉冲反馈

## 核心设计：DataRefreshCoordinator

新建集中式调度器 `DataRefreshCoordinator`，替代当前散落在 `AppDelegate` 中的多个独立定时器。

### 架构

```
DataRefreshCoordinator (单例)
├── Phase 1 — Ingest (30s)
│   ├── LogWatcher.scan()         增量解析日志
│   └── RepoDiscovery.scan()      发现新仓库
├── Phase 2 — Git Scan (5min)
│   └── GitMonitor.poll()         扫描已知仓库新 commit
├── Phase 3 — Balance (1h)
│   └── ApiPoller.pollAll()       拉取余额快照
├── Change Detection              比较写入前后的数据量
├── Debounce (500ms)              合并密集写入
└── Notify Consumers
    ├── MenuBar.refresh()
    ├── Dashboard.reload()        (via NotificationCenter)
    ├── Dock.refresh()            (badge + progress + pulse)
    └── CoinSound.play()          (有新数据时)
```

### 定时策略

| Phase | 间隔 | 首次延迟 | 职责 |
|-------|------|---------|------|
| Phase 1 — Ingest | 30s | 5s | 增量日志解析 + 新仓库扫描 |
| Phase 2 — Git | 5min | 15s | commit 扫描 |
| Phase 3 — Balance | 1h | 10s | 余额 API 轮询 |

每个 Phase 串行执行（同一 Phase 内部），不同 Phase 之间可并行。

### Change Detection

每个 Phase 执行后，Coordinator 检查是否有新数据写入：
- Phase 1：比较 `usage_event` 表行数变化
- Phase 2：比较 `code_change` 表行数变化
- Phase 3：比较 `balance_snapshot` 表行数变化

有任一变化 → 经过 500ms 防抖窗口 → 触发统一通知。

### 防抖机制

500ms 窗口内多次 Phase 完成（如 Phase 1 和 Phase 2 几乎同时完成）合并为一次 UI 通知，避免短时间内多次重建菜单。

---

## 问题 1：新仓库发现

### 修改点

**新增 `RepoDiscovery` 模块**（或在 `LogWatcher` 中增加方法）：

```
Sources/Engine/RepoDiscovery.swift
```

职责：扫描 `repo_search_dirs` 配置的目录，发现新的 `.git` 仓库，自动注册到 `GitMonitor`。

### 逻辑

1. 读取 `repo_search_dirs` 中配置的目录列表
2. 遍历每个目录，找到所有含 `.git` 的子目录
3. 与 `GitMonitor.watchedRepos` 做差集
4. 对每个新仓库调用 `GitMonitor.shared.watch(repoPath:)`
5. 记录日志：发现 N 个新仓库

### 调度

- 在 Phase 1（Ingest，30s）中执行
- 首次启动时立即执行一次（由 `LogWatcher.start()` 已有逻辑覆盖）
- 用户通过设置添加新目录时，立即执行一次该目录的扫描

### 去重

`GitMonitor.watch()` 已有 `watchedRepos.insert().inserted` 去重检查，新仓库发现天然幂等。

---

## 问题 2：设置页缓存

### 修改点

`Sources/UI/Settings/SettingsView.swift` — `ReposTab`

### 缓存结构

```swift
// 模块级静态缓存（应用生命周期内有效）
private static var repoScanCache: [String: (timestamp: Date, repos: [String])] = [:]
private static let cacheTTL: TimeInterval = 300 // 5 分钟
```

### 逻辑

- `onAppear` → 检查缓存：命中且未过期 → 直接展示，不扫描
- 缓存未命中 → 执行 `scanOne()`，完成后写入缓存
- 用户添加/移除目录 → 清除对应条目的缓存
- "重新检测"按钮（可选，后续加）→ 清除所有缓存并重新扫描

---

## 问题 3：数据协调

### 修改点

**新建** `Sources/Engine/DataRefreshCoordinator.swift`

**修改** `Sources/App/AIPulseApp.swift` — 替换独立 Timer 为 Coordinator

**修改** `Sources/UI/MenuBar/MenuBarController.swift` — 改为响应通知

**修改** `Sources/UI/Dock/DockManager.swift` — 改为响应通知

### Coordinator 核心逻辑

```swift
final class DataRefreshCoordinator {
    static let shared = DataRefreshCoordinator()

    private var phase1Timer: Timer?  // 30s
    private var phase2Timer: Timer?  // 5min
    private var phase3Timer: Timer?  // 1h
    private var pendingNotify = false
    private let debounceQueue: DispatchQueue

    func start() {
        // 启动三个 Phase 的定时器
        // 首次延迟：Phase1=5s, Phase2=15s, Phase3=10s
    }

    func stop() { /* 停止所有定时器 */ }

    // 每个 Phase 调用此方法报告完成
    private func phaseDidComplete(_ phase: Phase, changesDetected: Bool) {
        guard changesDetected else { return }
        scheduleUINotify()
    }

    private func scheduleUINotify() {
        // 500ms 防抖：取消之前的 pending，重新调度
        // 到期后发送 NotificationCenter.post(name: .dataDidChange)
    }
}
```

### 通知名称

- **新增** `.dataDidChange` — 替代现有的 `.dashboardRefresh`，所有 UI 消费者统一监听
- **保留** `.dashboardRefresh` 作为别名（兼容）

### UI 消费者改造

| 组件 | 当前刷新方式 | 改造后 |
|------|------------|--------|
| MenuBarController | 独立 Timer 30s | 监听 `.dataDidChange`，收到后 `refreshStats()` |
| DashboardView | `.task` + `.onReceive(.dashboardRefresh)` | 改为监听 `.dataDidChange` |
| DockManager | 独立 Timer 60s | 监听 `.dataDidChange`，收到后 `refresh()` |

### 数据一致性保证

- MenuBar 和 Dashboard 都由同一个通知触发，读取同一时刻的 DB 快照
- Coordinator 保证"先完成所有 Phase、再通知 UI"的顺序
- 防抖窗口确保短时间内多次数据写入只触发一次 UI 刷新

---

## 问题 4：音效与图标脉冲

### 4a. 音效

#### 修改点

`Sources/Engine/CoinSound.swift` + `DataRefreshCoordinator`

#### 变更

- `CoinSound.play()` 不再只在 `ApiPoller.cacheBalance()` 中调用
- **新的触发时机**：Coordinator 检测到数据变更且即将通知 UI 时调用
- 改为播放 bundle 中的 `.wav`/`.mp3` 音效文件（如 `Resources/coin.wav`），保留 `NSSound.beep()` 作为 fallback
- 如果在设置中关闭了音效开关，跳过

### 4b. 图标脉冲

#### 修改点

`Sources/UI/Dock/DockManager.swift`

#### 实现

在 `NSApp.dockTile` 收到数据变更通知后，对 `contentView` 做一次缩放动画：

```swift
func pulseIcon() {
    guard let tileView = NSApp.dockTile.contentView else {
        // Fallback: animate applicationIconImage via CALayer
        return
    }
    let anim = CAKeyframeAnimation(keyPath: "transform.scale")
    anim.values = [1.0, 1.15, 1.0]
    anim.keyTimes = [0, 0.5, 1.0]
    anim.duration = 0.3
    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    tileView.layer?.add(anim, forKey: "pulse")
}
```

- 仅在数据有实质变化时触发（由 Coordinator 控制）
- 脉冲与 Dock badge 更新同步
- 节流：最短间隔 2 秒，避免连续脉冲

---

## 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `Sources/Engine/DataRefreshCoordinator.swift` | **新建** | 集中式调度器 |
| `Sources/Engine/RepoDiscovery.swift` | **新建** | 新仓库扫描 |
| `Sources/App/AIPulseApp.swift` | 修改 | 替换独立 Timer，启动 Coordinator |
| `Sources/UI/MenuBar/MenuBarController.swift` | 修改 | 移除内部 Timer，改为响应通知 |
| `Sources/UI/Dock/DockManager.swift` | 修改 | 移除内部 Timer，响应通知 + 脉冲动画 |
| `Sources/UI/Dashboard/DashboardView.swift` | 修改 | 通知名称改为 `.dataDidChange` |
| `Sources/UI/Settings/SettingsView.swift` | 修改 | ReposTab 加内存缓存 |
| `Sources/GitMonitor/GitMonitor.swift` | 修改 | 暴露 `watchedRepos` 用于差集比较 |
| `Sources/Engine/CoinSound.swift` | 修改 | 支持从 Coordinator 触发，支持音效文件 |
| `Resources/coin.wav` | **新建** | 音效文件（可选，fallback 到 beep） |

## 不变更的部分

- 数据库 schema 不变
- IntegrationRegistry / ProviderRegistry 不变
- LogWatcher 增量解析逻辑不变
- GitRepo (libgit2) 不变
- Dashboard 图表渲染逻辑不变
- 设置页其他 Tab 不变

## 验收标准

1. 在监控目录下 `git clone` 新仓库后，30s 内菜单出现新仓库
2. 设置页 Repos Tab 第二次打开时不触发文件系统扫描（无 spinner）
3. 菜单和仪表盘的"按仓库"/"按供应商"数据一致（同一时刻刷新）
4. 每次有新数据（日志/commit/余额变化）时听到音效
5. Dock 图标在数据更新时有一次缩放脉冲动画
