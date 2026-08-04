# AI Pulse · Onboarding 流程重构 + 快速仓库扫描 + 共享缓存

- **日期**：2026-08-04
- **状态**：设计稿，待实现
- **相关代码**：
  - `Sources/UI/Onboarding/OnboardingView.swift`（4 步 onboarding，含内联慢速扫描）
  - `Sources/UI/Settings/SettingsView.swift`（`ReposTab`，含内联慢速扫描 + 内存缓存）
  - `Sources/Utils/GitRepoScanner.swift`（共享递归仓库 walker）
  - `Sources/Integrations/AiderIntegration.swift`（aider 检测，依赖 `repo_search_dirs` 全量走树）
  - `Sources/Engine/RepoDiscovery.swift`、`Sources/Ingest/LogWatcher.swift`（运行期消费 `repo_search_dirs` + `GitRepoScanner`）
  - `Sources/Engine/BookmarkManager.swift`（沙盒安全作用域授权）

---

## 1. 背景与问题

### 1.1 授权与检测的时序错误

现在的 onboarding 是 4 步：

| 步骤 | 内容 |
|---|---|
| 0 欢迎 | 纯文案 |
| 1 API 提供方 | DeepSeek/OpenAI/Kimi/ChatGLM/Anthropic key 输入 |
| 2 开发工具 | 检测结果 + 订阅套餐；**主目录授权按钮藏在这里面** |
| 3 仓库目录 | 手动添加目录 + 慢速扫描 + 勾选 |

工具的检测位置分为两类：

- **依赖主目录授权**（`~/.claude`、`~/.codex`、`~/.qwen`、`~/.opencode`、编辑器 Application Support）：Claude Code、Codex、Qwen Code、OpenCode、Cursor/Copilot/Windsurf。
- **依赖开发目录授权**（在仓库内找 `.aider.chat.history.md` / `.aider.llm.history`）：**只有 aider**。

**问题**：aider 的 `detect()` 读 `repo_search_dirs`（第 3 步仓库目录保存的值），但它的检测发生在第 2 步。onboarding 流程里 aider **永远检测不到**——授权与检测的顺序反了。

### 1.2 扫描慢 + 无进度反馈

三处扫描（GitRepoScanner、OnboardingView 内联、SettingsView 内联）都有同样的问题：

1. **无限深度递归**，且**不跳过重型依赖目录**（`node_modules`、`Pods`、`DerivedData`、`.venv`、`build`、`dist`、`.next`、`target`、`.gradle` 等）。一个前端项目仅 `node_modules` 就有几万个文件，几十个仓库 × 依赖树 = 数百万个目录项，导致"一直转圈"。
2. SettingsView 用 `enumerator(...).allObjects` 把整棵树**全部物化成数组**再遍历，额外浪费内存。
3. 结果只在**全部扫完后**一次性写回，扫描过程中 UI 只有转圈、看不到"已找到多少"。
4. aider 的 `detect()` 每次调用都会自己全量走一遍目录树，与扫描重复。

### 1.3 仓库确认页多余

第 3 步"仓库目录"页在快速检测后可省略：授权后后台扫描即可，无需阻塞式确认页。

## 2. 目标

1. **修复时序**：主目录 + 开发目录授权必须在检测之前，让 home 型和 dev 型工具都能在一次检测中上报。
2. **快速扫描**：几十个仓库的检测从几十秒降到 ~1s 内（通常几十毫秒），并**增量上报进度**（"已找到 N 个仓库"）替代无限转圈。
3. **统一扫描 + 共享缓存**：单一扫描引擎 + 持久化缓存，供 onboarding、设置页、aider 检测、RepoDiscovery、LogWatcher 复用。
4. **Onboarding 简化**：开发目录只选一个即可跑通流程；去掉仓库确认页；多目录交给设置页。
5. **设置页**：仓库只显示数量，不展开明细。

## 3. 核心设计

### 3.1 统一快速扫描引擎（升级 GitRepoScanner）

`Sources/Utils/GitRepoScanner.swift` 是 LogWatcher / RepoDiscovery / aider 的共享 walker，作为唯一扫描引擎，加三条规则：

1. **跳过重型依赖目录**：`node_modules`、`Pods`、`DerivedData`、`.venv`、`venv`、`__pycache__`、`build`、`dist`、`.next`、`target`、`.gradle`、`Carthage`、`.build`、`Packages`、`vendor`、`.cache`。
2. **限制深度**（约 4 层）；**发现某目录是仓库就不再下钻**（这条现网已有，但 onboarding/settings 的两份内联扫描没有）。
3. **增量回调**：找到仓库即调用 handler，调用方自行驱动进度 UI。

保留现有签名 `enumerate(in:handler:)`（同步、回调式），让 LogWatcher / RepoDiscovery 立刻变快、零改动。删除 OnboardingView 与 SettingsView 的两份内联扫描实现。

### 3.2 共享仓库缓存 RepoScanCache

新增 `Sources/Utils/RepoScanCache.swift`，作为所有 UI 与检测的**单一数据源**：

```swift
struct CachedRepo: Codable {
    let path: String       // 完整路径
    let name: String       // lastPathComponent
    let hasAiderMarkers: Bool  // 是否含 .aider.chat.history.md / .aider.llm.history
}

struct CachedDirScan: Codable {
    let dirPath: String
    let repos: [CachedRepo]
    let scannedAt: Date
    var truncated: Bool = false   // 软时间预算内未扫完时为 true，结果不完整
}

final class RepoScanCache: ObservableObject {
    static let shared = RepoScanCache()
    @Published private(set) var scans: [String: CachedDirScan]  // dirPath → 扫描结果
    func cachedScan(for dir: String) -> CachedDirScan?
    func scan(dir: String) async        // 后台跑 GitRepoScanner，单遍采集 repos + aider 标记
    func invalidate(dir: String)
}
```

- **持久化**：UserDefaults 键 `repo_scan_cache`（JSON `[String: CachedDirScan]`）。启动时加载 → UI 立即有数，后台按 TTL（约 5 分钟）刷新。
- **aider 标记随扫描采集**：扫描每一仓库时检查 `.aider.chat.history.md` / `.aider.llm.history`，单遍遍历同时产出"仓库列表 + aider 检测"，不再单独走树。
- **后台执行**：`scan(dir:)` 内 `Task.detached` 运行 walker，增量回调经 MainActor 更新 `@Published`。

### 3.3 Onboarding 流程（4 步，无仓库确认页）

| 步 | 内容 | 关键行为 |
|---|---|---|
| 0 欢迎 | 纯文案 | 保留现状 |
| **1 授权页** | 主目录授权 + 开发目录选择 | dev 目录默认定位主目录（`realHomeDirectory`），**只选一个**、可跳过；选完 `createAndSave` 书签 → 写入 `repo_search_dirs`（append-if-missing，不清空已有）→ 立即后台 `RepoScanCache.scan(dir)` |
| **2 检测与配置页** | 全部开发工具 + 订阅套餐 | home 型工具立即出结果；aider 读扫描缓存；顶部实时"已找到 N 个仓库"（由 `@Published` 驱动）；**下一步不被扫描阻塞** |
| 3 API 提供方 | key 输入 | 沿用现有 IntegrationRow |
| 4 完成 | 总结 + 仓库数摘要 | 从缓存读取 |

- 主目录授权按钮从旧第 2 步移到新第 1 步，作为显式第一步。
- 授权后自动重跑 home 型工具检测；dev 目录授权后扫描结果进入缓存供第 2 步使用。
- 全部可跳过：跳过则无检测结果，进入现有 Demo 模式逻辑（`DemoData`）。

### 3.4 设置页

- `ReposTab` 保留：多目录增删、每目录显示仓库数。
- **去掉展开明细**（只显示数量）。
- 目录增删时 `RepoScanCache.invalidate(dir)` 并触发重扫。
- 主目录 / 各工具授权逻辑维持现状，不套用 onboarding 时序。

### 3.5 消费方改造

| 消费方 | 现状 | 改造后 |
|---|---|---|
| OnboardingView | 内联慢扫 | 授权 → 后台 scan → 读 `@Published` |
| SettingsView | 内联慢扫 + 私有内存缓存 | 读 `RepoScanCache`，删内联扫描与私有缓存 |
| AiderIntegration.detect() | 全量走树 | 读缓存 `hasAiderMarkers` 计数；无缓存则触发后台 scan |
| RepoDiscovery | GitRepoScanner | 不变（walker 变快） |
| LogWatcher | GitRepoScanner | 不变（walker 变快） |

## 4. 边界与错误处理

- **未授权 / 全部跳过**：进入现有 Demo 模式，不阻塞。
- **开发目录在主目录之外**：允许，书签覆盖；NSOpenPanel 默认定位主目录仅作起点。
- **超大目录（如用户选 `~/`）**：深度限制 + 重型目录跳过已大幅收敛；另加**软时间预算**（如 2s）作安全阀，超时返回部分结果并在结果上标记 `truncated`。
- **缓存过期**：新仓库在磁盘出现 → DataRefreshCoordinator 的 Git 阶段（每 5 分钟）重扫 → 缓存刷新；设置页/onboarding 增删目录主动 invalidate。
- **沙盒**：书签在启动时 `resolveAll`；仅已授权目录可扫，未授权目录 `fileExists` 为 false → 0 仓库（沿用现状）。
- **波浪线路径**：`repo_search_dirs` 可能含 `"~/dev"`，扫描前按现有模式 `expandingTildeInPath` 展开。

## 5. 测试

- **扫描引擎**：临时目录树内造真实仓库、嵌套仓库、伪 `node_modules`（含大量子目录），断言深度/重型目录跳过正确、扫描快。
- **缓存**：持久化 round-trip、invalidate、TTL 过期。
- **aider 检测**：扫描结果 → `hasAiderMarkers` 计数正确。
- **回归**：现有 91 个测试保持通过。

## 6. 不做的事

- 设置页的授权/检测细节重构（维持现状，本就是分项设置）。
- LogWatcher 增量解析逻辑改动（仅受益于更快的 walker）。
- 多开发目录 onboarding（设计上 onboarding 只选一个，多目录归设置页）。
