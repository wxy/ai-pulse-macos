# Onboarding 流程重构 + 快速仓库扫描 + 共享缓存 · Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重构 onboarding 的授权/检测时序——先授权主目录 + 开发目录，再用快速扫描 + 共享缓存一次性检测全部开发工具（含 aider），移除仓库确认页；设置页仓库列表改读共享缓存、只显示数量。

**Architecture:** 单一扫描引擎（升级 `GitRepoScanner`，加入重型目录跳过、深度限制、软时间预算截断）产出仓库列表与 aider 标记；新增共享缓存 `RepoScanCache`（NSLock 保护的内存字典 + UserDefaults 持久化 + `didChange` 通知）作为 Onboarding / Settings / Aider 检测的单一数据源。

**Tech Stack:** Swift 6 · SwiftUI · SwiftPM（`swift test`/`swift build`）· XCTest · UserDefaults · String Catalog（`Localizable.xcstrings`）

## Global Constraints

- **分支纪律**：所有提交在 `feat/onboarding-scan-cache` 分支，绝不提交到 `main`。
- **平台/工具链**：`swift-tools-version: 6.0`，`platforms: [.macOS(.v14)]`；本机 Swift 6.3.3。构建命令：`swift build 2>&1 | tail -5`，测试命令：`swift test 2>&1 | tail -20`（可加 `--filter` 单跑；SwiftPM 需要 `Libraries/libgit2/lib`，仓库已含）。
- **本地化**：新 UI 文案必须写入 `Sources/Localizable.xcstrings`（源语言 `en`，共 11 语言：`en, zh-Hans, zh-Hant-TW, zh-Hant-HK, ja, ko, de, fr, es, pt-BR`），`extractionState: "manual"`。Swift 代码一律 `I18n.t(key)`，格式化用 `String(format:)`；**禁止**写带格式符（`%d` 等）的 `Text("...")` 字面量（会触发 SWIFT_EMIT_LOC_STRINGS 的 % 警告）。
- **沙盒**：仅已授权目录可被扫描；书签在启动时由 `BookmarkManager.resolveAll()` 统一开始访问。未授权目录 `fileExists == false` → 扫描返回空（沿用现状语义）。
- **路径语义**：`repo_search_dirs` 沙盒下存绝对路径、非沙盒可为 `~/` 波浪线路径。仓库缓存**键一律先 `expandingTildeInPath` 归一化**，避免同一目录以绝对/波浪线两种形式出现两个缓存条目。
- **测试**：XCTest + SwiftPM；`@testable import AIPulse`；每个测试类在 `setUp`/`tearDown` 中创建/清理临时目录与隔离的 `UserDefaults(suiteName:)`，不污染 `UserDefaults.standard`（除显式测试该行为处）。

---

### Task 1: GitRepoScanner 快速规则（跳过重型目录 / 限深 / 时间预算）

**Files:**
- Modify: `Sources/Utils/GitRepoScanner.swift`
- Test: `Tests/GitRepoScannerTests.swift`

**Interfaces:**
- Consumes: 现有 `GitRepoScanner.enumerate(in:handler:)`（保持调用方式不变，LogWatcher / RepoDiscovery / 旧调用方零改动）。
- Produces（Task 2 依赖）：
  - `static let heavyDirNames: Set<String>` —— 重型依赖目录名单
  - `static let maxDepth: Int = 4`
  - `static func enumerate(in dir: URL, deadline: Date? = nil, _ handler: (URL) -> Void) -> Bool` —— 返回 `true` 表示因 `deadline` 截断（结果不完整）

- [ ] **Step 1: 新增三个失败测试**

在 `Tests/GitRepoScannerTests.swift` 末尾追加（复用已有的 `makeGitRepo` / `makePlainDir` / `scan()` helper）：

```swift
func testSkipsHeavyDirectories() {
    makeGitRepo("node_modules/fake-repo")
    makeGitRepo("Pods/lib/foo")
    makeGitRepo("normal-repo")
    XCTAssertEqual(scan(), ["normal-repo"])
}

func testDepthBoundExcludesDeepRepos() {
    // 5 层深（nested=1 … too-deep-repo=5）超出 maxDepth=4，不应被枚举。
    makeGitRepo("shallow-repo")
    makeGitRepo("nested/deep/deeper/deepest/too-deep-repo")
    XCTAssertEqual(scan(), ["shallow-repo"])
}

func testDeadlineTruncates() {
    makeGitRepo("repo-a")
    var found: [String] = []
    let truncated = GitRepoScanner.enumerate(in: tempDir, deadline: .distantPast) {
        found.append($0.lastPathComponent)
    }
    XCTAssertTrue(truncated)
    XCTAssertTrue(found.isEmpty)
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter GitRepoScannerTests 2>&1 | tail -20`
Expected: `testSkipsHeavyDirectories` / `testDepthBoundExcludesDeepRepos` / `testDeadlineTruncates` FAIL（现实现不跳过重型目录、无限深度、无 deadline 参数）；原有 4 个测试仍 PASS。

- [ ] **Step 3: 实现快速规则**

用以下内容整体替换 `Sources/Utils/GitRepoScanner.swift`：

```swift
import Foundation

enum GitRepoScanner {
    /// System/installer directories skipped during recursive scans — prevents
    /// accidental access to media folders (permission dialogs) and system data.
    static let skippedDirNames: Set<String> = [
        "Music", "Pictures", "Movies", "Library", ".Trash",
    ]

    /// Heavy dependency/build directories never contain repos we want to track.
    /// Descending into them is what made scans slow (node_modules = tens of
    /// thousands of files). Skipped wholesale.
    static let heavyDirNames: Set<String> = [
        "node_modules", "Pods", "DerivedData", ".venv", "venv", "__pycache__",
        "build", "dist", ".next", "target", ".gradle", "Carthage", ".build",
        "Packages", "vendor", ".cache",
    ]

    /// Don't descend deeper than this. Repos are conventionally at depth 1-3
    /// (e.g. ~/dev, ~/dev/work). Bounding the walk keeps huge trees fast.
    static let maxDepth = 4

    /// Enumerate git repositories under `dir`, calling `handler` for each.
    /// Skips descendant traversal inside system/heavy dirs and once a repo is
    /// found (shallow-first: nested repos are not reported separately).
    /// Honors `deadline` (soft scan budget): when exceeded, stops early and
    /// returns `true` (truncated result). `FileManager.enumerator` yields
    /// immediate children at level 1, so `maxDepth` bounds repos to 4 levels.
    @discardableResult
    static func enumerate(in dir: URL, deadline: Date? = nil,
                          _ handler: (URL) -> Void) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }

        var truncated = false
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skippedDirNames.contains(name) || heavyDirNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if enumerator.level >= maxDepth {
                enumerator.skipDescendants()
            }
            let gitDir = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: gitDir.path,
                                                 isDirectory: &isDir),
                  isDir.boolValue else { continue }
            if let deadline, Date() >= deadline {
                truncated = true
                break
            }
            handler(url)
            enumerator.skipDescendants()
        }
        return truncated
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter GitRepoScannerTests 2>&1 | tail -20`
Expected: 全部 7 个测试（4 旧 + 3 新）PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/Utils/GitRepoScanner.swift Tests/GitRepoScannerTests.swift
git commit -m "feat: fast repo scanner — skip heavy dirs, bound depth, deadline truncation"
```

---

### Task 2: RepoScanCache 共享仓库缓存

**Files:**
- Create: `Sources/Utils/RepoScanCache.swift`
- Create: `Tests/RepoScanCacheTests.swift`

**Interfaces:**
- Consumes: `GitRepoScanner.enumerate(in:deadline:handler:)`（Task 1）。
- Produces（Task 3/5/6 依赖）：
  - `struct CachedRepo: Codable, Equatable { let path: String; let name: String; let hasAiderMarkers: Bool }`
  - `struct CachedDirScan: Codable, Equatable { let dirPath: String; let repos: [CachedRepo]; let scannedAt: Date; var truncated: Bool = false }`
  - `final class RepoScanCache`（线程安全：NSLock 保护内部字典；不依赖 @Published，UI 通过 Notification 刷新）
    - `static let shared: RepoScanCache`、`static let ttl: TimeInterval = 300`、`static let storeKey: String`（internal，测试用它直写数据）、`static let didChange: Notification.Name`
    - `init(store: UserDefaults = .standard)`
    - `var scans: [String: CachedDirScan] { get }` —— 加锁快照读取
    - `func cachedScan(for dir: String) -> CachedDirScan?` —— 过期（超过 ttl）视为缺失
    - `func scan(dir: String) async` —— 后台快速扫描，单遍采集 repos + aider 标记，写缓存 + 持久化 + post `didChange`
    - `func invalidate(dir: String)` —— 删除 + 持久化 + post `didChange`
    - `func totalRepos(in dirs: [String]) -> Int`

- [ ] **Step 1: 写失败测试**

创建 `Tests/RepoScanCacheTests.swift`：

```swift
import XCTest
@testable import AIPulse

final class RepoScanCacheTests: XCTestCase {
    private var tempDir: URL!
    private var store: UserDefaults!
    private var cache: RepoScanCache!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoScanCacheTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = UserDefaults(suiteName: "RepoScanCacheTests-\(UUID().uuidString)")!
        cache = RepoScanCache(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        cache = nil
        store = nil
        super.tearDown()
    }

    private func makeRepo(_ rel: String, aider: Bool = false) {
        let r = tempDir.appendingPathComponent(rel)
        try! FileManager.default.createDirectory(
            at: r.appendingPathComponent(".git"), withIntermediateDirectories: true)
        if aider {
            FileManager.default.createFile(
                atPath: r.appendingPathComponent(".aider.chat.history.md").path, contents: Data())
        }
    }

    func testScanCollectsReposAndAiderMarkers() async {
        makeRepo("plain")
        makeRepo("aider-repo", aider: true)
        await cache.scan(dir: tempDir.path)

        let scan = cache.cachedScan(for: tempDir.path)
        XCTAssertNotNil(scan)
        XCTAssertEqual(scan?.repos.count, 2)
        XCTAssertEqual(scan?.repos.first { $0.name == "aider-repo" }?.hasAiderMarkers, true)
        XCTAssertEqual(scan?.repos.first { $0.name == "plain" }?.hasAiderMarkers, false)
        XCTAssertEqual(scan?.truncated, false)
    }

    func testPersistenceRoundTrip() async {
        makeRepo("persisted")
        await cache.scan(dir: tempDir.path)

        // 同一 store 上新建实例必须读到持久化的扫描结果。
        let cache2 = RepoScanCache(store: store)
        XCTAssertEqual(cache2.cachedScan(for: tempDir.path)?.repos.count, 1)
    }

    func testInvalidateRemovesEntry() async {
        makeRepo("gone")
        await cache.scan(dir: tempDir.path)
        XCTAssertNotNil(cache.cachedScan(for: tempDir.path))

        cache.invalidate(dir: tempDir.path)
        XCTAssertNil(cache.cachedScan(for: tempDir.path))
    }

    func testStaleScanTreatedAsMissing() {
        let stale = CachedDirScan(
            dirPath: tempDir.path,
            repos: [CachedRepo(path: tempDir.path + "/x", name: "x", hasAiderMarkers: false)],
            scannedAt: Date().addingTimeInterval(-(RepoScanCache.ttl + 60))
        )
        let data = try! JSONEncoder().encode([tempDir.path: stale])
        store.set(data, forKey: RepoScanCache.storeKey)

        let c = RepoScanCache(store: store)
        XCTAssertNil(c.cachedScan(for: tempDir.path))
    }
}
```

- [ ] **Step 2: 运行测试，确认失败（编译失败也算失败）**

Run: `swift test --filter RepoScanCacheTests 2>&1 | tail -20`
Expected: 编译失败——`RepoScanCache` 不存在。

- [ ] **Step 3: 实现 RepoScanCache**

创建 `Sources/Utils/RepoScanCache.swift`：

```swift
import Foundation

/// One git repository found by a scan.
struct CachedRepo: Codable, Equatable {
    let path: String            // absolute path
    let name: String            // lastPathComponent
    let hasAiderMarkers: Bool   // contains .aider.chat.history.md / .aider.llm.history
}

/// Scan result for one directory.
struct CachedDirScan: Codable, Equatable {
    let dirPath: String
    let repos: [CachedRepo]
    let scannedAt: Date
    var truncated: Bool = false   // deadline hit → result incomplete
}

/// Shared, persisted repository-scan cache — the single source of truth for
/// repo counts/lists across Onboarding, Settings, and aider detection.
///
/// Thread-safe: the internal dict is guarded by `lock` (scans run on background
/// threads and `cachedScan` may be called from tests off-main). UI observes via
/// `NotificationCenter` on `didChange`, matching the existing `.dataDidChange`
/// pattern in this codebase.
final class RepoScanCache {
    static let shared = RepoScanCache()
    static let ttl: TimeInterval = 300            // 5 min; older scans are "missing"
    static let scanBudget: TimeInterval = 2.0      // soft budget per directory
    static let storeKey = "repo_scan_cache"
    static let didChange = Notification.Name("RepoScanCacheDidChange")

    private let lock = NSLock()
    private var _scans: [String: CachedDirScan] = [:]
    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        _scans = Self.load(from: store)
    }

    /// Thread-safe snapshot of all cached scans.
    var scans: [String: CachedDirScan] {
        lock.lock(); defer { lock.unlock() }
        return _scans
    }

    /// Fresh scan for `dir`, or nil if missing/stale.
    func cachedScan(for dir: String) -> CachedDirScan? {
        let key = Self.expand(dir)
        lock.lock(); defer { lock.unlock() }
        guard let s = _scans[key],
              Date().timeIntervalSince(s.scannedAt) < Self.ttl else { return nil }
        return s
    }

    /// Run a fast background scan of `dir`, collecting repos + aider markers in
    /// one pass, then store + persist + notify. No-op if the dir isn't readable.
    func scan(dir: String) async {
        let expanded = Self.expand(dir)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        let deadline = Date().addingTimeInterval(Self.scanBudget)
        let result = await Task.detached(priority: .userInitiated) { () -> (repos: [CachedRepo], truncated: Bool) in
            let fm = FileManager.default
            let root = URL(fileURLWithPath: expanded, isDirectory: true)
            var repos: [CachedRepo] = []
            let truncated = GitRepoScanner.enumerate(in: root, deadline: deadline) { url in
                let hasAider = fm.fileExists(atPath: url.appendingPathComponent(".aider.chat.history.md").path)
                    || fm.fileExists(atPath: url.appendingPathComponent(".aider.llm.history").path)
                repos.append(CachedRepo(path: url.path, name: url.lastPathComponent, hasAiderMarkers: hasAider))
            }
            return (repos, truncated)
        }.value
        let sorted = result.repos.sorted { $0.name < $1.name }
        let scan = CachedDirScan(dirPath: expanded, repos: sorted,
                                 scannedAt: Date(), truncated: result.truncated)
        storeResult(scan, for: expanded)
    }

    func invalidate(dir: String) {
        let key = Self.expand(dir)
        lock.lock()
        _scans.removeValue(forKey: key)
        lock.unlock()
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Total repos across `dirs`, using only fresh cache entries.
    func totalRepos(in dirs: [String]) -> Int {
        dirs.reduce(0) { $0 + (cachedScan(for: $1)?.repos.count ?? 0) }
    }

    // MARK: - Internal

    private func storeResult(_ scan: CachedDirScan, for key: String) {
        lock.lock()
        _scans[key] = scan
        lock.unlock()
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func persist() {
        lock.lock()
        let snapshot = _scans
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            store.set(data, forKey: Self.storeKey)
        }
    }

    private static func expand(_ p: String) -> String {
        NSString(string: p).expandingTildeInPath
    }

    private static func load(from store: UserDefaults) -> [String: CachedDirScan] {
        guard let data = store.data(forKey: storeKey),
              let dict = try? JSONDecoder().decode([String: CachedDirScan].self, from: data)
        else { return [:] }
        return dict
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter RepoScanCacheTests 2>&1 | tail -20`
Expected: 4 个测试全 PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/Utils/RepoScanCache.swift Tests/RepoScanCacheTests.swift
git commit -m "feat: shared persisted RepoScanCache with aider markers"
```

---

### Task 3: AiderIntegration 改读缓存

**Files:**
- Modify: `Sources/Integrations/AiderIntegration.swift`
- Create: `Tests/AiderIntegrationTests.swift`

**Interfaces:**
- Consumes: `RepoScanCache`（Task 2）。
- Produces: `AiderIntegration.init(cache: RepoScanCache = .shared)`（`IntegrationRegistry.all` 里 `AiderIntegration()` 构造保持不变）。

- [ ] **Step 1: 写失败测试**

创建 `Tests/AiderIntegrationTests.swift`：

```swift
import XCTest
@testable import AIPulse

final class AiderIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var cache: RepoScanCache!
    private let dirsKey = "repo_search_dirs"
    private var savedDirs: [String]?

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AiderIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        cache = RepoScanCache(store: UserDefaults(suiteName: "AiderIntegrationTests-\(UUID().uuidString)")!)
        savedDirs = UserDefaults.standard.stringArray(forKey: dirsKey)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        if let saved = savedDirs { UserDefaults.standard.set(saved, forKey: dirsKey) }
        else { UserDefaults.standard.removeObject(forKey: dirsKey) }
        cache = nil
    }

    private func makeRepo(_ rel: String, aider: Bool = false) {
        let r = tempDir.appendingPathComponent(rel)
        try! FileManager.default.createDirectory(
            at: r.appendingPathComponent(".git"), withIntermediateDirectories: true)
        if aider {
            FileManager.default.createFile(
                atPath: r.appendingPathComponent(".aider.chat.history.md").path, contents: Data())
        }
    }

    func testDetectsAiderFromCache() async {
        makeRepo("with-aider", aider: true)
        makeRepo("without")
        await cache.scan(dir: tempDir.path)
        UserDefaults.standard.set([tempDir.path], forKey: dirsKey)

        let result = AiderIntegration(cache: cache).detect()
        XCTAssertTrue(result.found)
    }

    func testNoMarkersNotDetected() async {
        makeRepo("without")
        await cache.scan(dir: tempDir.path)
        UserDefaults.standard.set([tempDir.path], forKey: dirsKey)

        let result = AiderIntegration(cache: cache).detect()
        XCTAssertFalse(result.found)
    }
}
```

- [ ] **Step 2: 运行测试，确认失败（编译失败也算失败）**

Run: `swift test --filter AiderIntegrationTests 2>&1 | tail -20`
Expected: 编译失败——`AiderIntegration.init(cache:)` 不存在。

- [ ] **Step 3: 实现**

用以下内容替换 `Sources/Integrations/AiderIntegration.swift` 中 `struct AiderIntegration` 的声明与 `detect()`（文件其余注释可保留）：

```swift
struct AiderIntegration: Detectable {
    let id = "aider"
    let displayName = "aider"
    var costSources: [CostSource] { [] }

    private let cache: RepoScanCache

    init(cache: RepoScanCache = .shared) {
        self.cache = cache
    }

    func detect() -> DetectionResult {
        let dirs = UserDefaults.standard.stringArray(forKey: "repo_search_dirs")
            ?? ["~/dev", "~/projects", "~/code"]
        var count = 0
        for d in dirs {
            if let scan = cache.cachedScan(for: d) {
                count += scan.repos.filter(\.hasAiderMarkers).count
            } else {
                // No fresh scan yet — warm the cache in the background so a
                // later detect() (or the live-updating onboarding page) is right.
                Task { await cache.scan(dir: d) }
            }
        }
        return DetectionResult(
            found: count > 0,
            summary: count > 0
                ? String(format: I18n.t("detect.aider_found"), count)
                : I18n.t("detect.aider_not_found")
        )
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter AiderIntegrationTests 2>&1 | tail -20`
Expected: 2 个测试全 PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/Integrations/AiderIntegration.swift Tests/AiderIntegrationTests.swift
git commit -m "feat: aider detection reads RepoScanCache instead of re-walking trees"
```

---

### Task 4: 新增 i18n 文案

**Files:**
- Modify: `Sources/Localizable.xcstrings`

新增 6 个 key：`onboarding.authorize_title`、`onboarding.authorize_desc`、`onboarding.authorize_home_title`、`onboarding.authorize_dev_title`、`onboarding.authorize_dev_desc`、`onboarding.repos_found`。开发目录行的描述复用已有 `onboarding.grant_home_hint`（主目录行）——无需新增。

- [ ] **Step 1: 用脚本把 6 个 key 写入 String Catalog**

Run（在仓库根目录执行；脚本对现有 xcstrings 做读-改-写，已测试不破坏结构）：

```bash
python3 - <<'PYEOF'
import json, collections

path = "Sources/Localizable.xcstrings"
with open(path) as f:
    d = json.load(f, object_pairs_hook=collections.OrderedDict)

L = ["en","zh-Hans","zh-Hant-TW","zh-Hant-HK","ja","ko","de","fr","es","pt-BR"]
def add(key, values):
    assert set(values) == set(L), key
    entry = {
        "extractionState": "manual",
        "localizations": {
            lang: {"stringUnit": {"state": "translated", "value": values[lang]}}
            for lang in L
        },
    }
    d["strings"][key] = entry

add("onboarding.authorize_title", {
 "en": "Authorize access", "zh-Hans": "授权访问", "zh-Hant-TW": "授權存取", "zh-Hant-HK": "授權存取",
 "ja": "アクセスを許可", "ko": "접근 권한 부여", "de": "Zugriff autorisieren",
 "fr": "Autoriser l'accès", "es": "Autorizar acceso", "pt-BR": "Autorizar acesso",
})
add("onboarding.authorize_desc", {
 "en": "Grant read access so AI Pulse can detect your coding tools and repositories.",
 "zh-Hans": "授予读取权限，以便 AI Pulse 检测你的开发工具和代码仓库。",
 "zh-Hant-TW": "授予讀取權限，以便 AI Pulse 偵測你的開發工具和程式碼儲存庫。",
 "zh-Hant-HK": "授予讀取權限，以便 AI Pulse 偵測你的開發工具和程式碼儲存庫。",
 "ja": "AI Pulse が開発ツールとリポジトリを検出できるよう読み取りアクセスを許可します。",
 "ko": "AI Pulse가 개발 도구와 저장소를 감지할 수 있도록 읽기 권한을 부여하세요.",
 "de": "Gewähren Sie Lesezugriff, damit AI Pulse Ihre Tools und Repos erkennt.",
 "fr": "Autorisez l'accès en lecture pour permettre à AI Pulse de détecter vos outils et dépôts.",
 "es": "Conceda acceso de lectura para que AI Pulse detecte sus herramientas y repositorios.",
 "pt-BR": "Conceda acesso de leitura para que o AI Pulse detecte suas ferramentas e repositórios.",
})
add("onboarding.authorize_home_title", {
 "en": "Home folder", "zh-Hans": "主目录", "zh-Hant-TW": "主目錄", "zh-Hant-HK": "主目錄",
 "ja": "ホームフォルダ", "ko": "홈 폴더", "de": "Home-Ordner",
 "fr": "Dossier personnel", "es": "Carpeta de inicio", "pt-BR": "Pasta pessoal",
})
add("onboarding.authorize_dev_title", {
 "en": "Development folder", "zh-Hans": "开发目录", "zh-Hant-TW": "開發目錄", "zh-Hant-HK": "開發目錄",
 "ja": "開発フォルダ", "ko": "개발 폴더", "de": "Entwicklungsordner",
 "fr": "Dossier de développement", "es": "Carpeta de desarrollo", "pt-BR": "Pasta de desenvolvimento",
})
add("onboarding.authorize_dev_desc", {
 "en": "Where your code lives. Enables repo scanning and aider detection.",
 "zh-Hans": "存放代码仓库的位置，用于仓库扫描与 aider 检测。",
 "zh-Hant-TW": "存放程式碼儲存庫的位置，用於儲存庫掃描與 aider 偵測。",
 "zh-Hant-HK": "存放程式碼儲存庫嘅位置，用於儲存庫掃描同 aider 偵測。",
 "ja": "コードがある場所。リポジトリスキャンと aider 検出に使われます。",
 "ko": "코드가 있는 위치입니다. 저장소 스캔과 aider 감지에 사용됩니다.",
 "de": "Wo Ihr Code liegt. Ermöglicht Repo-Scans und aider-Erkennung.",
 "fr": "Où se trouve votre code. Permet l'analyse des dépôts et la détection d'aider.",
 "es": "Donde vive su código. Permite el escaneo de repositorios y la detección de aider.",
 "pt-BR": "Onde seu código fica. Permite a varredura de repositórios e a detecção do aider.",
})
add("onboarding.repos_found", {
 "en": "%d repos found", "zh-Hans": "已找到 %d 个仓库", "zh-Hant-TW": "已找到 %d 個儲存庫", "zh-Hant-HK": "已找到 %d 個儲存庫",
 "ja": "%d 個のリポジトリを検出", "ko": "저장소 %d개 발견", "de": "%d Repos gefunden",
 "fr": "%d dépôts trouvés", "es": "%d repositorios encontrados", "pt-BR": "%d repositórios encontrados",
})

with open(path, "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("added 6 keys; total now", len(d["strings"]))
PYEOF
```

- [ ] **Step 2: 校验 xcstrings 未损坏**

Run: `python3 -c "import json; d=json.load(open('Sources/Localizable.xcstrings')); print(len(d['strings']))"`
Expected: 输出 296（290 + 6），且无异常。

- [ ] **Step 3: 构建验证**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`（xcstrings 被编译进 bundle，构建即校验其结构合法）。

- [ ] **Step 4: 提交**

```bash
git add Sources/Localizable.xcstrings
git commit -m "feat(i18n): onboarding authorize-page strings"
```

---

### Task 5: OnboardingView 重构——授权页先于检测、移除仓库确认页

**Files:**
- Modify: `Sources/UI/Onboarding/OnboardingView.swift`

**Interfaces:**
- Consumes: `BookmarkManager.requestAccess(message:defaultDirectory:)`、`BookmarkManager.homeDirPath`、`RepoScanCache.shared`（Task 2）、`I18n.t` 新 key（Task 4）。
- Produces: 新 4 步流程——`0 欢迎 → 1 授权页 → 2 检测与配置（dev 工具 + 实时仓库数）→ 3 API 提供方 → 4 完成`。

- [ ] **Step 1: 改 State 属性与步骤路由**

在 `OnboardingView` 中：
- 删除 `@State private var dirEntries: [DirEntry] = []`，新增 `@State private var selectedDevDir: String? = nil`。
- `body` 的 switch 改为：

```swift
switch step {
case 0: welcomeStep
case 1: authorizeStep
case 2: devToolsStep
case 3: apiProvidersStep
default: doneStep
}
```

- 底部导航改为（删除 repos 步骤专用的 skip 按钮与 `saveRepos()` 调用）：

```swift
HStack {
    if step == 0 {
        Button(I18n.t("demo.skip_welcome")) {
            DemoData.isManual = true
            close()
        }
    } else if step > 0 {
        Button(I18n.t("onboarding.back")) { step -= 1 }
    }
    Spacer()
    if step < 4 {
        Button(I18n.t("onboarding.next")) { step += 1 }
    } else {
        Button(I18n.t("onboarding.close")) { close() }
    }
}
.padding(.horizontal, 24).padding(.bottom, 16)
```

- [ ] **Step 2: 新增 `authorizeStep` 视图与 `selectDevDir` / `repoCountView`**

在 `// MARK: - Step 1: Detection results` 之前插入：

```swift
// MARK: - Step 1: Authorize (home + dev dir)

var authorizeStep: some View {
    VStack(alignment: .leading, spacing: 16) {
        Text(I18n.t("onboarding.authorize_title")).font(.title3).fontWeight(.semibold)
        Text(I18n.t("onboarding.authorize_desc"))
            .font(.caption).foregroundColor(.secondary)

        // Home folder access (gates ~/.claude, ~/.codex, ~/.qwen detection)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: homeGranted ? "checkmark.circle.fill" : "folder.badge.person.crop")
                    .foregroundColor(homeGranted ? .green : .accentColor)
                Text(I18n.t("onboarding.authorize_home_title")).font(.body).fontWeight(.medium)
                Spacer()
                if !homeGranted {
                    Button(I18n.t("bookmark.grant_to_detect")) { grantHomeAndRedetect() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            Text(I18n.t("onboarding.grant_home_hint"))
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

        // Development folder (repo scanning + aider detection)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundColor(.accentColor)
                Text(I18n.t("onboarding.authorize_dev_title")).font(.body).fontWeight(.medium)
                Spacer()
                Button(I18n.t("bookmark.grant")) { selectDevDir() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Text(I18n.t("onboarding.authorize_dev_desc"))
                .font(.caption2).foregroundColor(.secondary)
            if let dev = selectedDevDir {
                Text(dev).font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
    .padding(.horizontal, 24)
}

private var homeGranted: Bool {
    !BookmarkManager.isSandboxed || BookmarkManager.hasHomeAccess
}

/// Pick one dev directory, persist it to repo_search_dirs, kick a background
/// fast scan, and re-detect so aider (dev-dir based) updates on the next page.
private func selectDevDir() {
    guard let url = BookmarkManager.requestAccess(
        message: I18n.t("bookmark.repos_message"),
        defaultDirectory: BookmarkManager.homeDirPath
    ) else { return }
    let p = url.path
    selectedDevDir = p
    var dirs = UserDefaults.standard.stringArray(forKey: repoDirsKey) ?? []
    let expanded = NSString(string: p).expandingTildeInPath
    if !dirs.contains(expanded) { dirs.append(expanded) }
    UserDefaults.standard.set(dirs, forKey: repoDirsKey)
    Task { await RepoScanCache.shared.scan(dir: p) }
    runDetection()
}
```

- [ ] **Step 3: 重写 `devToolsStep`（去掉授权横幅，加实时仓库数 + 监听缓存）**

用以下内容替换现有 `var devToolsStep`：

```swift
/// Step 2: Dev tools — every supported tool (log/subscription). Home-based
/// tools report immediately; aider reads the shared scan cache. The live repo
/// count reflects the background fast scan of the dev directory.
var devToolsStep: some View {
    let items = detectionResults.filter {
        IntegrationCategory.category(for: $0.0) == .devTools
    }
    return VStack(alignment: .leading, spacing: 12) {
        Text(I18n.t("settings.integrations_devtools")).font(.title3).fontWeight(.semibold)
        Text(I18n.t("integrations.group_editors_desc"))
            .font(.caption).foregroundColor(.secondary)

        repoCountView

        ScrollView {
            VStack(spacing: 12) {
                ForEach(items, id: \.0.id) { (integration, result) in
                    IntegrationRow(integration: integration, detected: result)
                }
                if items.isEmpty {
                    Text(I18n.t("onboarding.no_tools"))
                        .foregroundColor(.secondary).padding()
                }
            }
        }
    }
    .padding(.horizontal, 24)
    .onReceive(NotificationCenter.default.publisher(for: RepoScanCache.didChange)) { _ in
        runDetection()   // re-evaluate aider once the fast scan lands
    }
}

@ViewBuilder
private var repoCountView: some View {
    let total = RepoScanCache.shared.totalRepos(
        in: UserDefaults.standard.stringArray(forKey: repoDirsKey) ?? [])
    if total > 0 {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            Text(String(format: I18n.t("onboarding.repos_found"), total))
                .font(.caption)
            Spacer()
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    } else if selectedDevDir != nil {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(I18n.t("onboarding.repos_scanning")).font(.caption)
            Spacer()
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 4: 改 `doneStep` 的仓库计数**

把 `doneStep` 开头的

```swift
let totalCheckedRepos = dirEntries.filter(\.isChecked).reduce(0) { $0 + $1.repoCount }
let hasAnyConfig = !enabledIds.isEmpty || totalCheckedRepos > 0
```

替换为

```swift
let totalRepos = RepoScanCache.shared.totalRepos(
    in: UserDefaults.standard.stringArray(forKey: repoDirsKey) ?? [])
let hasAnyConfig = !enabledIds.isEmpty || totalRepos > 0
```

并把函数体内 `totalCheckedRepos` 的两处引用改为 `totalRepos`（`if totalCheckedRepos > 0 { Text(String(format: I18n.t("onboarding.done_repos_count"), totalCheckedRepos)) ... }` → 对应 `totalRepos`）。

- [ ] **Step 5: 删除仓库确认页及其扫描代码**

在 `OnboardingView` 中删除：
- 整个 `var reposStep: some View`（`// MARK: - Step 2: Repo directories` 块）
- `private func pickDir()`（onboarding 版）
- `func startScan()`、`func scanOne(at:)`、`func saveRepos()`
- `@State private var dirEntries`（已在 Step 1 删）

**保留**：文件顶部 `struct DirEntry`（设置页仍使用，勿删）、`repoDirsKey` 常量、`runDetection`、`grantHomeAndRedetect`、`finish`、`close`。

- [ ] **Step 6: 构建验证**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`。若报 `cannot find 'RepoScanCache'` / `'CachedDirScan'` 之类，先确认 Task 2 已合入。

- [ ] **Step 7: 提交**

```bash
git add Sources/UI/Onboarding/OnboardingView.swift
git commit -m "feat(onboarding): authorize page before detection, drop repos page"
```

---

### Task 6: SettingsView ReposTab 改读共享缓存、只显示数量

**Files:**
- Modify: `Sources/UI/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `RepoScanCache.shared`（Task 2）、`DirEntry`（仍定义在 `OnboardingView.swift`，Task 5 保留）、`I18n.t("repos.*")` 已有 key。
- Produces: 无新类型（删除 SettingsView 私有全局 `repoScanCache` / `repoScanCacheTTL` 与内联 `scanOne`）。

- [ ] **Step 1: 删除私有内存缓存全局变量**

删除 `Sources/UI/Settings/SettingsView.swift` 中：

```swift
// In-memory cache for repo scans (avoids full filesystem enumeration
// every time the Repos tab is opened). Invalidated on directory add/remove.
private nonisolated(unsafe) var repoScanCache: [String: (timestamp: Date, repos: [String])] = [:]
private let repoScanCacheTTL: TimeInterval = 300 // 5 minutes
```

（保留 `private let repoDirsKey = "repo_search_dirs"`。）

- [ ] **Step 2: 重写 `ReposTab` 主体（只显示数量，去展开）**

用以下内容替换整个 `struct ReposTab` 的 `body` 与 `// MARK: - Scanning` 以下部分（即 `startScan` / `pickDir` / `save` / `scanOne` 全部替换）：

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(I18n.t("repos.title")).font(.title3).fontWeight(.semibold)

            ScrollView {
                VStack(spacing: 4) {
                    if dirEntries.isEmpty {
                        Text(I18n.t("repos.grant_empty"))
                            .font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    ForEach($dirEntries) { $entry in
                        HStack(spacing: 6) {
                            Image(systemName: "folder").foregroundColor(.accentColor)
                            Text(entry.path).font(.body).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let scan = RepoScanCache.shared.cachedScan(for: entry.path) {
                                Text("\(scan.repos.count)")
                                    .font(.caption2).foregroundColor(.secondary)
                                    .padding(.horizontal, 5)
                                    .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
                            } else {
                                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                            }
                            Button { deleteTarget = entry.path; showDelete = true } label: {
                                Image(systemName: "xmark.circle").font(.caption).foregroundColor(.secondary)
                            }.buttonStyle(.plain)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 8)
                    }
                }
            }

            HStack {
                Button(action: pickDir) {
                    Label(I18n.t("repos.add"), systemImage: "plus.circle").font(.caption)
                }
                Spacer()
            }

            let totalRepos = dirEntries.reduce(0) {
                $0 + (RepoScanCache.shared.cachedScan(for: $1.path)?.repos.count ?? 0)
            }
            Text(String(format: I18n.t("repos.summary"), dirEntries.count, totalRepos))
                .font(.caption2).foregroundColor(.secondary)
        }
        .onAppear { loadAndScan() }
        .onReceive(NotificationCenter.default.publisher(for: RepoScanCache.didChange)) { _ in }
        .alert(I18n.t("repos.delete_title"), isPresented: $showDelete) {
            Button(I18n.t("repos.cancel"), role: .cancel) {}
            Button(I18n.t("repos.remove"), role: .destructive) {
                if let d = deleteTarget {
                    dirEntries.removeAll { $0.path == d }
                    RepoScanCache.shared.invalidate(dir: d)
                    save()
                }
            }
        } message: { Text(String(format: I18n.t("repos.delete_msg"), deleteTarget ?? "")) }
    }

    // MARK: - Scanning

    private func loadAndScan() {
        let dirs = UserDefaults.standard.stringArray(forKey: repoDirsKey) ?? []
        if dirs.isEmpty {
            // Under sandbox, unauthorized guessed defaults can't be read; show an
            // empty state + Add button instead of persisting/scanning unreadable dirs.
            if BookmarkManager.isSandboxed {
                dirEntries = []
            } else {
                let defaults = ["~/dev", "~/projects", "~/code"]
                UserDefaults.standard.set(defaults, forKey: repoDirsKey)
                dirEntries = defaults.map { DirEntry(path: $0) }
            }
        } else {
            dirEntries = dirs.map { DirEntry(path: $0) }
        }
        // Background-scan any dir without a fresh cache entry; results post
        // RepoScanCache.didChange and the rows update live.
        for entry in dirEntries where RepoScanCache.shared.cachedScan(for: entry.path) == nil {
            Task { await RepoScanCache.shared.scan(dir: entry.path) }
        }
    }

    private func pickDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = I18n.t("bookmark.grant")
        panel.message = I18n.t("bookmark.repos_message")
        panel.directoryURL = FileManager.default.realHomeDirectory
        if panel.runModal() == .OK, let url = panel.url {
            BookmarkManager.createAndSave(for: url)
            let p = url.path
            guard !dirEntries.contains(where: { $0.path == p }) else { return }
            dirEntries.append(DirEntry(path: p))
            save()
            Task { await RepoScanCache.shared.scan(dir: p) }
            LogWatcher.shared.start()
            DataRefreshCoordinator.shared.triggerIngest()
        }
    }

    private func save() {
        UserDefaults.standard.set(dirEntries.map(\.path), forKey: repoDirsKey)
    }
```

注意：`ReposTab` 的 `@State` 声明（`dirEntries`、`deleteTarget`、`showDelete`）保持不变；删除的旧 `startScan` / `scanOne` 中的 `repoScanCache` 引用随之消失。

- [ ] **Step 3: 构建验证**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: 全量测试回归**

Run: `swift test 2>&1 | tail -20`
Expected: 全量 PASS（含既有 91 项 + 本分支新增）。

- [ ] **Step 5: 提交**

```bash
git add Sources/UI/Settings/SettingsView.swift
git commit -m "feat(settings): repos tab reads shared cache, count-only rows"
```

---

### Task 7: 端到端核对

**Files:** 无代码改动。

- [ ] **Step 1: 核对 Spec 覆盖**

对照 `docs/superpowers/specs/2026-08-04-onboarding-scan-cache-design.md` 逐条确认：
- 授权先于检测（Task 5 step1-2）✅
- 快速扫描三规则（Task 1）✅
- 共享缓存 + UserDefaults 持久化 + aider 标记随扫描采集（Task 2）✅
- aider 读缓存（Task 3）✅
- onboarding 只选一个开发目录、无仓库确认页、非阻塞（Task 5）✅
- 设置页多目录、只显示数量、去展开（Task 6）✅

- [ ] **Step 2: 全量测试 + 构建**

Run: `swift test 2>&1 | tail -20 && swift build 2>&1 | tail -5`
Expected: 全量 PASS + `Build complete!`。

- [ ] **Step 3: 人工冒烟（可选，需 GUI 环境）**

`swift run AIPulse` 后：首次启动走 onboarding，第 1 步授权开发目录后第 2 步应显示"已找到 N 个仓库"且 aider 出现检测结果；设置 → 仓库页每目录只显示数量。

- [ ] **Step 4: 收尾提交（如有改动）**

```bash
git add -A
git commit -m "chore: onboarding scan cache verification"
```
（若 Step 2/3 无改动则跳过。）

---

## Self-Review

- **Spec coverage**：Spec 六节（修复时序 / 快速扫描 / 统一缓存 / onboarding 简化 / 设置页 / 消费方改造）全部落到 Task 1-6；边界（时间预算、缓存过期、沙盒、波浪线）覆盖于 Task 1 deadline 测试、Task 2 TTL 测试与实现注释。
- **Placeholder scan**：所有代码步骤含完整内容；i18n 以脚本形式给出全部 6 key × 11 语言。
- **Type consistency**：`RepoScanCache`（Task 2）的 `cachedScan(for:)` / `scan(dir:)` / `invalidate(dir:)` / `totalRepos(in:)` 在 Task 3/5/6 中的调用签名一致；`GitRepoScanner.enumerate(in:deadline:_:)` 的 `deadline` 默认参数保证 Task 1 后既有调用方（LogWatcher / RepoDiscovery / AiderIntegration 旧路径）零改动。
- **线程安全**：`RepoScanCache` 内部字典统一用 `NSLock` 保护（Task 2 实现）；UI 刷新走 `RepoScanCache.didChange` 通知（`onReceive(NotificationCenter...)`），与代码库既有 `.dataDidChange` 模式一致；Task 5/6 的 `onReceive` 均指同一通知。
