# 工具详情浮层（会话探索器 + 上下文趋势）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Claude Code / ChatGPT 的详情体验改为“仪表盘 3 行结论卡 + 整窗覆盖式会话探索浮层”，浮层内按仓库分组展示会话，点击会话行内展开逐轮上下文趋势图。

**Architecture:** 数据侧新增 `session_info` 表（会话标题/仓库/窗口上限/完成状态），解析器从日志行提取元数据并在增量解析时写入，另做一次性回填；`StatsService` 新增结论卡与会话列表/逐轮序列查询（复用 `usage_event`）；UI 侧把仪表盘展开卡改成 3 行结论，点击后以 ZStack 覆盖层展示会话列表与内联图表。所有计算逻辑（分组、压缩点、占用率、环比）做成纯函数以便测试。

**Tech Stack:** Swift 6 / SwiftUI / GRDB 6.29+ / macOS 14+（Xcode 自带 Charts）。

## Global Constraints

- 目标平台 macOS 14+（`platforms: [.macOS(.v14)]`），测试命令 `make test`（`swift build --build-tests -Xcc -I$(PWD)/Libraries/libgit2/include` + 运行 `.build/.../AIPulsePackageTests`）。
- 不新增独立窗口；浮层是 `DashboardView` 内 ZStack 覆盖层。
- 浮层可滚动（覆盖整个窗口，只有一个滚动上下文）；不引入 tab。
- 会话列表筛选口径 = 时间范围内存在交互的会话；展开图展示完整会话轨迹（不受范围截断）。
- 会话标题 = 首条用户消息，截断 60 字符；产出归属沿用现有 repo 级 `code_change` 口径（近似）。
- 新增 UI 文案必须加进 `Sources/Localizable.xcstrings` 并覆盖全部 10 种语言（de/en/es/fr/ja/ko/pt-BR/zh-Hans/zh-Hant-HK/zh-Hant-TW）。
- 压缩点判定：下一轮 input < 前一轮 input × 0.7；占用提示阈值：最终占用 > 80%。

## File Structure

| 文件 | 职责 |
|---|---|
| `Sources/Store/Database.swift` | 新增 `session_info` 表；抽出可测试的 `createAllTables(_:)` |
| `Sources/Ingest/LogParsers/CodexParser.swift` | 新增首条用户消息 / 窗口上限 / 完成标记提取 |
| `Sources/Ingest/LogParsers/ClaudeCodeParser.swift` | 新增首条用户消息提取 |
| `Sources/Ingest/SessionInfoRecord.swift` | `SessionInfoRecord` 模型 + 标题截断纯函数（新建） |
| `Sources/Ingest/LogWatcher.swift` | 解析时捕获元数据并 upsert `session_info` |
| `Sources/Ingest/SessionInfoBackfill.swift` | 一次性回填存量会话元数据（新建） |
| `Sources/Store/SessionStats.swift` | 会话列表/结论/趋势的模型与纯计算函数（新建） |
| `Sources/Store/StatsService.swift` | 新增结论卡、会话列表、逐轮序列 SQL 查询 |
| `Sources/UI/Dashboard/DashboardView.swift` | 结论卡三行 + 打开浮层的状态与 ZStack 包裹 |
| `Sources/UI/Dashboard/ToolDetailOverlayView.swift` | 浮层 UI：列表 + 内联图表（新建） |
| `Sources/Localizable.xcstrings` | 新增文案 |
| `Package.swift` | test target 增加 GRDB 依赖（测试用） |

---

### Task 1: `session_info` 表 + 可测试的建表

**Files:**
- Modify: `Sources/Store/Database.swift`
- Modify: `Package.swift`
- Create: `Tests/DatabaseSchemaTests.swift`

**Interfaces:**
- Produces: `AppDatabase.createAllTables(_ db: Database) throws`（static，可被测试用内存库调用）；`session_info` 表存在。

- [ ] **Step 1: 写失败测试**

`Tests/DatabaseSchemaTests.swift`：

```swift
import XCTest
import GRDB
@testable import AIPulse

final class DatabaseSchemaTests: XCTestCase {
    func testSessionInfoTableCreated() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try AppDatabase.createAllTables(db)
        }
        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("session_info"))
            let cols = try db.columns(in: "session_info").map(\.name)
            XCTAssertTrue(cols.contains("source"))
            XCTAssertTrue(cols.contains("session_id"))
            XCTAssertTrue(cols.contains("title"))
            XCTAssertTrue(cols.contains("repo"))
            XCTAssertTrue(cols.contains("first_ts"))
            XCTAssertTrue(cols.contains("last_ts"))
            XCTAssertTrue(cols.contains("completed"))
            XCTAssertTrue(cols.contains("window_tokens"))
        }
    }
}
```

`Package.swift` test target：

```swift
.testTarget(
    name: "AIPulseTests",
    dependencies: ["AIPulse", .product(name: "GRDB", package: "GRDB.swift")],
    path: "Tests"
),
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter DatabaseSchemaTests`
Expected: 编译失败 / “createAllTables 不存在”。

- [ ] **Step 3: 实现**

`Sources/Store/Database.swift`：把 `setup()` 里的 `tables` 数组与建表循环抽出为 static 方法，并加入 `session_info`：

```swift
static func createAllTables(_ db: Database) throws {
    for (_, migration) in tables {
        try migration(db)
    }
}

private static let tables: [(String, (Database) throws -> Void)] = [
    // …原有 usage_event / code_change / … 全部原样搬入…
    ("session_info", { db in
        try db.create(table: "session_info", ifNotExists: true) { t in
            t.column("source", .text).notNull()
            t.column("session_id", .text).notNull()
            t.column("title", .text)
            t.column("repo", .text)
            t.column("first_ts", .integer)
            t.column("last_ts", .integer)
            t.column("completed", .boolean)
            t.column("window_tokens", .integer)
            t.primaryKey(["source", "session_id"])
        }
        try? db.create(indexOn: "session_info", columns: ["source", "session_id"])
    }),
]
```

`setup()` 中循环替换为：

```swift
try dbQueue?.write { try AppDatabase.createAllTables($0) }
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter DatabaseSchemaTests`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/Store/Database.swift Package.swift Tests/DatabaseSchemaTests.swift
git commit -m "feat: add session_info table with testable schema creation"
```

---

### Task 2: 解析器元数据提取

**Files:**
- Modify: `Sources/Ingest/LogParsers/CodexParser.swift`
- Modify: `Sources/Ingest/LogParsers/ClaudeCodeParser.swift`
- Modify: `Tests/CodexParserTests.swift`
- Modify: `Tests/ClaudeCodeParserTests.swift`

**Interfaces:**
- Produces:
  - `CodexParser.firstUserMessage(fromLine:) -> String?`
  - `CodexParser.windowTokens(fromLine:) -> Int?`
  - `CodexParser.isSessionComplete(fromLine:) -> Bool`
  - `ClaudeCodeParser.firstUserMessage(fromLine:) -> String?`

- [ ] **Step 1: 写失败测试**

`Tests/CodexParserTests.swift` 追加：

```swift
func testFirstUserMessageFromUserMessageEvent() {
    let line = """
    {"timestamp":"2026-08-09T00:40:28Z","type":"event_msg","payload":{"type":"user_message","client_id":"x","message":"排查硬盘占用并给出方案"}}
    """
    XCTAssertEqual(CodexParser.firstUserMessage(fromLine: line), "排查硬盘占用并给出方案")
}

func testWindowTokensFromTokenCountEvent() {
    let line = """
    {"timestamp":"2026-08-09T00:40:35Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1},"model_context_window":996147}}}
    """
    XCTAssertEqual(CodexParser.windowTokens(fromLine: line), 996147)
}

func testIsSessionComplete() {
    XCTAssertTrue(CodexParser.isSessionComplete(fromLine: #"{"type":"task_complete","payload":{}}"#))
    XCTAssertFalse(CodexParser.isSessionComplete(fromLine: #"{"type":"task_started","payload":{}}"#))
}
```

`Tests/ClaudeCodeParserTests.swift` 追加：

```swift
func testFirstUserMessageFromUserLine() {
    let line = """
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"请分析这个项目"}]}}
    """
    XCTAssertEqual(ClaudeCodeParser.firstUserMessage(fromLine: line), "请分析这个项目")
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter CodexParserTests --filter ClaudeCodeParserTests`
Expected: 编译失败（函数不存在）。

- [ ] **Step 3: 实现**

`Sources/Ingest/LogParsers/CodexParser.swift` 追加：

```swift
/// Extract the first user-authored message from a `user_message` event.
static func firstUserMessage(fromLine line: String) -> String? {
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["type"] as? String == "event_msg",
          let payload = json["payload"] as? [String: Any],
          payload["type"] as? String == "user_message"
    else { return nil }
    return payload["message"] as? String
}

/// Extract the model context window from a `token_count` event.
static func windowTokens(fromLine line: String) -> Int? {
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["type"] as? String == "event_msg",
          let payload = json["payload"] as? [String: Any],
          payload["type"] as? String == "token_count",
          let info = payload["info"] as? [String: Any],
          let window = info["model_context_window"] as? NSNumber
    else { return nil }
    return window.intValue
}

/// True when the line marks the session as completed.
static func isSessionComplete(fromLine line: String) -> Bool {
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return json["type"] as? String == "task_complete"
}
```

`Sources/Ingest/LogParsers/ClaudeCodeParser.swift` 追加：

```swift
/// Extract the first user-authored text from a `user` line.
static func firstUserMessage(fromLine line: String) -> String? {
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["type"] as? String == "user",
          let message = json["message"] as? [String: Any],
          let content = message["content"] as? [[String: Any]]
    else { return nil }
    for item in content {
        if let text = item["text"] as? String, !text.isEmpty {
            return text
        }
    }
    return nil
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter CodexParserTests --filter ClaudeCodeParserTests`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/Ingest/LogParsers/CodexParser.swift Sources/Ingest/LogParsers/ClaudeCodeParser.swift Tests/CodexParserTests.swift Tests/ClaudeCodeParserTests.swift
git commit -m "feat: extract session metadata from Codex and Claude logs"
```

---

### Task 3: `SessionInfoRecord` + LogWatcher 写入 `session_info`

**Files:**
- Create: `Sources/Ingest/SessionInfoRecord.swift`
- Modify: `Sources/Ingest/LogWatcher.swift`
- Create: `Tests/SessionInfoRecordTests.swift`

**Interfaces:**
- Consumes: Task 2 的 4 个解析函数；`CodexParser.sessionId(fromLine:)`、`CodexParser.cwd(fromLine:)`（已存在）。
- Produces: `SessionInfoRecord`（struct + `makeTitle(_:maxLength:)`）；`LogWatcher` 在解析每个 rollout / claude jsonl 文件后调用 `upsertSessionInfo(_:)`。

- [ ] **Step 1: 写失败测试**

`Tests/SessionInfoRecordTests.swift`：

```swift
import XCTest
@testable import AIPulse

final class SessionInfoRecordTests: XCTestCase {
    func testMakeTitleTruncates() {
        let long = String(repeating: "a", count: 100)
        let title = SessionInfoRecord.makeTitle(long)
        XCTAssertEqual(title?.count, 60)
    }

    func testMakeTitleNilForEmpty() {
        XCTAssertNil(SessionInfoRecord.makeTitle(nil))
        XCTAssertNil(SessionInfoRecord.makeTitle(""))
        XCTAssertNil(SessionInfoRecord.makeTitle("   "))
    }

    func testMakeTitleCollapsesWhitespace() {
        XCTAssertEqual(SessionInfoRecord.makeTitle("  hello   world  "), "hello world")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter SessionInfoRecordTests`
Expected: 编译失败。

- [ ] **Step 3: 实现**

`Sources/Ingest/SessionInfoRecord.swift`：

```swift
import Foundation

/// One row of `session_info`: session-level metadata captured while parsing logs.
struct SessionInfoRecord {
    let source: String
    let sessionId: String?
    let title: String?
    let repo: String?
    let firstTs: Int
    let lastTs: Int
    let completed: Bool?
    let windowTokens: Int?

    /// First user message, whitespace-collapsed and truncated to `maxLength` characters.
    static func makeTitle(_ text: String?, maxLength: Int = 60) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxLength))
    }
}
```

`Sources/Ingest/LogWatcher.swift`：

1) `parseCodexFile` 内增加捕获与写库（在 `parseLinesIncremental` 闭包内更新变量，循环后 upsert）：

```swift
private func parseCodexFile(_ file: URL) {
    var currentCwd: String? = nil
    var currentModel: String? = nil
    var currentSessionId: String? = nil
    var currentTitle: String? = nil
    var currentWindow: Int? = nil
    var currentCompleted = false
    var minTs = Int.max
    var maxTs = 0
    var parsedCount = 0
    let filePath = file.path
    parseLinesIncremental(from: file) { line in
        if let cwd = CodexParser.cwd(fromLine: line) { currentCwd = cwd }
        if let sid = CodexParser.sessionId(fromLine: line) { currentSessionId = sid }
        if let m = CodexParser.model(fromLine: line) { currentModel = m }
        if currentTitle == nil, let msg = CodexParser.firstUserMessage(fromLine: line) {
            currentTitle = SessionInfoRecord.makeTitle(msg)
        }
        if currentWindow == nil, let w = CodexParser.windowTokens(fromLine: line) { currentWindow = w }
        if CodexParser.isSessionComplete(fromLine: line) { currentCompleted = true }
        if let event = CodexParser.parse(line: line, cwd: currentCwd, model: currentModel, sessionId: currentSessionId) {
            minTs = min(minTs, event.ts)
            maxTs = max(maxTs, event.ts)
            parsedCount += 1
            return event
        }
        return nil
    }
    guard let sid = currentSessionId, maxTs > 0 else { return }
    upsertSessionInfo(SessionInfoRecord(
        source: "codex", sessionId: sid, title: currentTitle, repo: currentCwd,
        firstTs: minTs, lastTs: maxTs, completed: currentCompleted ? true : nil,
        windowTokens: currentWindow))
    if parsedCount > 0 {
        Logger.info("LogWatcher: parsed \(parsedCount) codex events from \(filePath)")
    }
}
```

2) `scanClaudeCode` 内按文件捕获并写库：

```swift
private func scanClaudeCode(at dir: URL) {
    guard let enumerator = FileManager.default.enumerator(
        at: dir, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return }
    for case let file as URL in enumerator where file.pathExtension == "jsonl" {
        discoverAndWatchRepo(from: file)
        var sessionId: String? = nil
        var title: String? = nil
        var repo: String? = nil
        var minTs = Int.max
        var maxTs = 0
        parseLinesIncremental(from: file) { line in
            if sessionId == nil { sessionId = line.jsonStringField("sessionId") }
            if repo == nil { repo = line.jsonStringField("cwd") }
            if title == nil, let msg = ClaudeCodeParser.firstUserMessage(fromLine: line) {
                title = SessionInfoRecord.makeTitle(msg)
            }
            guard let event = ClaudeCodeParser.parse(line: line) else { return nil }
            minTs = min(minTs, event.ts)
            maxTs = max(maxTs, event.ts)
            var repoPath = event.repoPath
            if let repoUrl = findGitRepo(containing: repoPath) {
                GitMonitor.shared.watch(repoPath: repoUrl.path)
                repoPath = repoUrl.path
            }
            return UsageEvent(ts: event.ts, source: event.source, model: event.model,
                inTokens: event.inTokens, outTokens: event.outTokens, cacheTokens: event.cacheTokens,
                repoPath: repoPath, sessionId: event.sessionId, dedupeKey: event.dedupeKey)
        }
        guard let sid = sessionId, maxTs > 0 else { continue }
        upsertSessionInfo(SessionInfoRecord(
            source: "claude-code", sessionId: sid, title: title, repo: repo,
            firstTs: minTs, lastTs: maxTs, completed: nil, windowTokens: nil))
    }
}
```

> 注：`line.jsonStringField(_:)` 为 Task 3 一并加入的 `String` 扩展（见下），用于读 Claude jsonl 顶层 `sessionId` / `cwd`。

3) 新增 `String` 扩展（放在 `LogWatcher.swift` 文件底部或同文件 extension）：

```swift
private extension String {
    func jsonStringField(_ key: String) -> String? {
        guard let data = data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json[key] as? String
    }
}
```

4) 新增 upsert 方法：

```swift
private func upsertSessionInfo(_ record: SessionInfoRecord) {
    guard let sid = record.sessionId else { return }
    do {
        try AppDatabase.shared.write { db in
            try db.execute(sql: """
                INSERT INTO session_info (source, session_id, title, repo, first_ts, last_ts, completed, window_tokens)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, session_id) DO UPDATE SET
                    title = COALESCE(excluded.title, session_info.title),
                    repo = COALESCE(excluded.repo, session_info.repo),
                    first_ts = MIN(session_info.first_ts, excluded.first_ts),
                    last_ts = MAX(session_info.last_ts, excluded.last_ts),
                    completed = COALESCE(excluded.completed, session_info.completed),
                    window_tokens = COALESCE(excluded.window_tokens, session_info.window_tokens)
                """, arguments: [record.source, sid, record.title, record.repo,
                                 record.firstTs, record.lastTs, record.completed, record.windowTokens])
        }
    } catch {
        Logger.error("LogWatcher: session_info upsert failed: \(error)")
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter SessionInfoRecordTests`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/Ingest/SessionInfoRecord.swift Sources/Ingest/LogWatcher.swift Tests/SessionInfoRecordTests.swift
git commit -m "feat: capture session metadata while parsing logs"
```

---

### Task 4: 存量会话元数据一次性回填

**Files:**
- Create: `Sources/Ingest/SessionInfoBackfill.swift`
- Modify: `Sources/Engine/DataRefreshCoordinator.swift`（启动时调用一次）
- Create: `Tests/SessionInfoBackfillTests.swift`

**Interfaces:**
- Consumes: Task 2/3 的解析函数与 `SessionInfoRecord`。
- Produces: `SessionInfoBackfill.runIfNeeded()`（UserDefaults key `session_info_backfill_v1` 防重入）；`SessionInfoBackfill.metadataFromSnippet(_ data: Data, source: String, sessionId: String?, repo: String?) -> SessionInfoRecord?`（纯函数，可测）。

- [ ] **Step 1: 写失败测试**

`Tests/SessionInfoBackfillTests.swift`：

```swift
import XCTest
@testable import AIPulse

final class SessionInfoBackfillTests: XCTestCase {
    func testCodexSnippetExtractsMetadata() {
        let snippet = Data("""
        {"timestamp":"2026-08-09T00:00:00Z","type":"session_meta","payload":{"session_id":"s1","cwd":"/repo"}}
        {"timestamp":"2026-08-09T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"第一个任务"}}
        {"timestamp":"2026-08-09T00:00:02Z","type":"task_complete","payload":{}}
        """.utf8)
        let record = SessionInfoBackfill.metadataFromSnippet(
            snippet, source: "codex", sessionId: nil, repo: nil)
        XCTAssertEqual(record?.sessionId, "s1")
        XCTAssertEqual(record?.repo, "/repo")
        XCTAssertEqual(record?.title, "第一个任务")
        XCTAssertEqual(record?.completed, true)
    }

    func testClaudeSnippetExtractsTitle() {
        let snippet = Data("""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"请分析"}]}}
        """.utf8)
        let record = SessionInfoBackfill.metadataFromSnippet(
            snippet, source: "claude-code", sessionId: "c1", repo: "/r")
        XCTAssertEqual(record?.title, "请分析")
        XCTAssertEqual(record?.sessionId, "c1")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter SessionInfoBackfillTests`
Expected: 编译失败。

- [ ] **Step 3: 实现**

`Sources/Ingest/SessionInfoBackfill.swift`：

```swift
import Foundation

/// One-time backfill: read the first chunk of every existing Codex/Claude
/// session log and upsert its session metadata, so old sessions get titles
/// without a full re-parse. Guarded by UserDefaults so it runs once.
enum SessionInfoBackfill {
    private static let doneKey = "session_info_backfill_v1"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let home = FileManager.default.realHomeDirectory
        backfillCodex(home: home)
        backfillClaude(home: home)
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    static func metadataFromSnippet(
        _ data: Data,
        source: String,
        sessionId: String?,
        repo: String?
    ) -> SessionInfoRecord? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var sid = sessionId
        var title: String? = nil
        var repoPath = repo
        var completed = false
        var window: Int? = nil
        var minTs = Int.max
        var maxTs = 0
        text.enumerateLines { line, _ in
            if sid == nil, let s = CodexParser.sessionId(fromLine: line) { sid = s }
            if repoPath == nil, let c = CodexParser.cwd(fromLine: line) { repoPath = c }
            if title == nil {
                if source == "codex", let m = CodexParser.firstUserMessage(fromLine: line) {
                    title = SessionInfoRecord.makeTitle(m)
                } else if source == "claude-code", let m = ClaudeCodeParser.firstUserMessage(fromLine: line) {
                    title = SessionInfoRecord.makeTitle(m)
                }
            }
            if window == nil, let w = CodexParser.windowTokens(fromLine: line) { window = w }
            if CodexParser.isSessionComplete(fromLine: line) { completed = true }
            if let e = CodexParser.parse(line: line, cwd: nil, model: nil) {
                minTs = min(minTs, e.ts)
                maxTs = max(maxTs, e.ts)
            } else if let e = ClaudeCodeParser.parse(line: line) {
                minTs = min(minTs, e.ts)
                maxTs = max(maxTs, e.ts)
            }
        }
        guard let session = sid, maxTs > 0 else { return nil }
        return SessionInfoRecord(
            source: source, sessionId: session, title: title, repo: repoPath,
            firstTs: minTs, lastTs: maxTs, completed: completed ? true : nil,
            windowTokens: source == "codex" ? window : nil)
    }

    private static func backfillCodex(home: URL) {
        let dir = home.appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: dir.path),
              let enumerator = FileManager.default.enumerator(
                  at: dir, includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            guard let data = try? readPrefix(of: url, bytes: 64 * 1024),
                  let record = metadataFromSnippet(data, source: "codex", sessionId: nil, repo: nil)
            else { continue }
            LogWatcher.upsertForBackfill(record)
        }
    }

    private static func backfillClaude(home: URL) {
        let dir = home.appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: dir.path),
              let enumerator = FileManager.default.enumerator(
                  at: dir, includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let sid = url.deletingPathExtension().lastPathComponent
            guard let data = try? readPrefix(of: url, bytes: 64 * 1024),
                  let record = metadataFromSnippet(data, source: "claude-code", sessionId: sid, repo: nil)
            else { continue }
            LogWatcher.upsertForBackfill(record)
        }
    }

    private static func readPrefix(of url: URL, bytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: bytes) ?? Data()
    }
}
```

`LogWatcher` 增加内部入口（供回填复用 upsert）：

```swift
static func upsertForBackfill(_ record: SessionInfoRecord) {
    LogWatcher.shared.upsertSessionInfo(record)
}
```

`DataRefreshCoordinator` 启动路径调用 `SessionInfoBackfill.runIfNeeded()`（放在首次 `start()` 时）。

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter SessionInfoBackfillTests`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/Ingest/SessionInfoBackfill.swift Sources/Ingest/LogWatcher.swift Sources/Engine/DataRefreshCoordinator.swift Tests/SessionInfoBackfillTests.swift
git commit -m "feat: one-time backfill of session metadata for existing logs"
```

---

### Task 5: 会话统计模型 + 纯计算 + SQL

**Files:**
- Create: `Sources/Store/SessionStats.swift`
- Modify: `Sources/Store/StatsService.swift`
- Create: `Tests/SessionStatsTests.swift`

**Interfaces:**
- Produces:
  - `struct ToolConclusion` / `struct SessionRow` / `struct RepoSessionGroup` / `struct TurnPoint` / `struct ContextTrend`
  - 纯函数：`SessionStats.deltaPct(current:previous:)`、`SessionStats.projectMonth(spendSoFar:daysElapsed:daysInMonth:)`、`SessionStats.groupSessions(_:)`、`SessionStats.compactionMarks(_:)`、`SessionStats.cacheSavings(cacheTokens:inPricePerMtok:cachePricePerMtok:)`
  - `StatsService.toolConclusion(source:sinceMs:) async -> ToolConclusion`
  - `StatsService.sessionRows(source:sinceMs:) async -> [SessionRow]`
  - `StatsService.turnSeries(source:sessionId:) async -> ContextTrend`

- [ ] **Step 1: 写失败测试**

`Tests/SessionStatsTests.swift`：

```swift
import XCTest
@testable import AIPulse

final class SessionStatsTests: XCTestCase {
    func testDeltaPct() {
        XCTAssertEqual(SessionStats.deltaPct(current: 110, previous: 100), 10, accuracy: 0.001)
        XCTAssertEqual(SessionStats.deltaPct(current: 90, previous: 100), -10, accuracy: 0.001)
        XCTAssertEqual(SessionStats.deltaPct(current: 5, previous: 0), 0)
    }

    func testProjectMonth() {
        XCTAssertEqual(SessionStats.projectMonth(spendSoFar: 30, daysElapsed: 10, daysInMonth: 30), 90, accuracy: 0.001)
    }

    func testGroupSessionsSortsByCostDesc() {
        let rows = [
            SessionRow(source: "codex", sessionId: "a", title: nil, repo: "/r1", firstTs: 1, lastTs: 2, lastInput: 100, cost: 5, windowTokens: nil),
            SessionRow(source: "codex", sessionId: "b", title: nil, repo: nil, firstTs: 1, lastTs: 2, lastInput: 100, cost: 20, windowTokens: nil),
            SessionRow(source: "codex", sessionId: "c", title: nil, repo: "/r1", firstTs: 1, lastTs: 2, lastInput: 100, cost: 3, windowTokens: nil),
        ]
        let groups = SessionStats.groupSessions(rows)
        XCTAssertEqual(groups.map(\.repo), ["/r1", SessionStats.noRepoKey])
        XCTAssertEqual(groups[0].sessions.map(\.sessionId), ["a", "c"])
    }

    func testCompactionMarks() {
        let turns = [
            TurnPoint(index: 1, ts: 1, inputTokens: 100, cacheTokens: 10, outTokens: 5, cost: 0.1),
            TurnPoint(index: 2, ts: 2, inputTokens: 120, cacheTokens: 20, outTokens: 5, cost: 0.1),
            TurnPoint(index: 3, ts: 3, inputTokens: 60, cacheTokens: 10, outTokens: 5, cost: 0.1),
            TurnPoint(index: 4, ts: 4, inputTokens: 70, cacheTokens: 15, outTokens: 5, cost: 0.1),
        ]
        XCTAssertEqual(SessionStats.compactionMarks(turns), [3])
    }

    func testCacheSavings() {
        // 1M cached tokens × ($3 - $0.3) per Mtok = $2.70
        XCTAssertEqual(SessionStats.cacheSavings(cacheTokens: 1_000_000, inPricePerMtok: 3, cachePricePerMtok: 0.3), 2.7, accuracy: 0.001)
    }

    func testContextTrendOccupancy() {
        let turns = [
            TurnPoint(index: 1, ts: 1, inputTokens: 100, cacheTokens: 10, outTokens: 5, cost: 0.1),
            TurnPoint(index: 2, ts: 2, inputTokens: 160, cacheTokens: 20, outTokens: 5, cost: 0.1),
        ]
        let trend = ContextTrend(turns: turns, windowTokens: 200, model: nil)
        XCTAssertEqual(trend.finalOccupancy, 0.8, accuracy: 0.001)
        XCTAssertFalse(trend.needsCompactionHint) // 0.8 不触发
        let nearFull = ContextTrend(
            turns: [TurnPoint(index: 1, ts: 1, inputTokens: 162, cacheTokens: 10, outTokens: 5, cost: 0.1)],
            windowTokens: 200, model: nil)
        XCTAssertTrue(nearFull.needsCompactionHint) // 0.81 > 0.8 触发
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter SessionStatsTests`
Expected: 编译失败。

- [ ] **Step 3: 实现**

`Sources/Store/SessionStats.swift`：

```swift
import Foundation

struct ToolConclusion {
    var spend: Double = 0
    var previousSpend: Double = 0
    var deltaPct: Double = 0
    var projectedMonth: Double = 0
    var sessionCount: Int = 0
    var commitCount: Int = 0
    var addedLines: Int = 0
    var deletedLines: Int = 0
    var avgCostPerSession: Double = 0
    var cpl: Double = 0
    var crossToolDeltaPct: Double? = nil
}

struct SessionRow: Identifiable, Equatable {
    var id: String { "\(source)|\(sessionId ?? "")" }
    let source: String
    let sessionId: String?
    let title: String?
    let repo: String?
    let firstTs: Int
    let lastTs: Int
    let lastInput: Int
    let cost: Double
    let windowTokens: Int?
    var finalOccupancy: Double? {
        guard let w = windowTokens, w > 0 else { return nil }
        return Double(lastInput) / Double(w)
    }
}

struct RepoSessionGroup: Identifiable {
    var id: String { repo }
    let repo: String
    let totalCost: Double
    let sessions: [SessionRow]
}

struct TurnPoint: Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    let ts: Int
    let inputTokens: Int
    let cacheTokens: Int
    let outTokens: Int
    let cost: Double
}

struct ContextTrend {
    let turns: [TurnPoint]
    let windowTokens: Int?
    let model: String?
    var cacheTokensTotal: Int { turns.reduce(0) { $0 + $1.cacheTokens } }
    var totalCost: Double { turns.reduce(0) { $0 + $1.cost } }
    var finalOccupancy: Double? {
        guard let window = windowTokens, window > 0, let last = turns.last else { return nil }
        return Double(last.inputTokens) / Double(window)
    }
    var needsCompactionHint: Bool {
        guard let occupancy = finalOccupancy else { return false }
        return occupancy > 0.8
    }
    var compactionIndexes: Set<Int> { SessionStats.compactionMarks(turns) }
}

enum SessionStats {
    static let noRepoKey = "（无仓库）"

    static func deltaPct(current: Double, previous: Double) -> Double {
        guard previous > 0 else { return 0 }
        return (current - previous) / previous * 100
    }

    static func projectMonth(spendSoFar: Double, daysElapsed: Int, daysInMonth: Int) -> Double {
        guard daysElapsed > 0 else { return 0 }
        return spendSoFar / Double(daysElapsed) * Double(daysInMonth)
    }

    /// Group sessions by repo; groups sorted by total cost descending,
    /// sessions within a group sorted by cost descending. Nil repo → "（无仓库）".
    static func groupSessions(_ rows: [SessionRow]) -> [RepoSessionGroup] {
        var grouped: [String: [SessionRow]] = [:]
        for row in rows {
            let key = row.repo ?? SessionStats.noRepoKey
            grouped[key, default: []].append(row)
        }
        return grouped
            .map { key, sessions in
                RepoSessionGroup(
                    repo: key,
                    totalCost: sessions.reduce(0) { $0 + $1.cost },
                    sessions: sessions.sorted { $0.cost > $1.cost })
            }
            .sorted { $0.totalCost > $1.totalCost }
    }

    /// Turn indexes where the next turn's input dropped to < 70% of the previous.
    static func compactionMarks(_ turns: [TurnPoint]) -> Set<Int> {
        var marks = Set<Int>()
        guard turns.count > 1 else { return marks }
        for i in 1..<turns.count {
            let prev = turns[i - 1].inputTokens
            let curr = turns[i].inputTokens
            if prev > 0, Double(curr) < Double(prev) * 0.7 {
                marks.insert(turns[i].index)
            }
        }
        return marks
    }

    static func cacheSavings(cacheTokens: Int, inPricePerMtok: Double, cachePricePerMtok: Double) -> Double {
        Double(cacheTokens) / 1_000_000 * (inPricePerMtok - cachePricePerMtok)
    }
}
```

`Sources/Store/StatsService.swift` 追加查询（沿用现有 `AppDatabase.shared.read` 模式）：

```swift
// MARK: - Tool detail (conclusion card + session explorer)

static func toolConclusion(source: String, sinceMs: Int64) async -> ToolConclusion {
    let cal = Calendar.current
    let todayMs = Int64(cal.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
    let rangeLen = todayMs + 86_400_000 - sinceMs
    let prevSince = sinceMs - rangeLen

    let spend = await sourceSpend(source: source, sinceMs: sinceMs, toMs: todayMs + 86_400_000)
    let previous = await sourceSpend(source: source, sinceMs: prevSince, toMs: sinceMs)
    let rows = await sessionRows(source: source, sinceMs: sinceMs)
    let changes = await attributedChanges(source: source, sinceMs: sinceMs, toMs: todayMs + 86_400_000)

    let daysElapsed = max(1, Int((todayMs - sinceMs) / 86_400_000) + 1)
    let daysInMonth = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
    let totalLines = changes.added + changes.deleted
    let cpl = totalLines > 0 ? spend / Double(totalLines) * 1000 : 0
    let count = rows.count
    let otherSource = source == "codex" ? "claude-code" : "codex"
    let otherRows = await sessionRows(source: otherSource, sinceMs: sinceMs)
    let thisAvg = count > 0 ? spend / Double(count) : 0
    let otherAvg = otherRows.count > 0
        ? (await sourceSpend(source: otherSource, sinceMs: sinceMs, toMs: todayMs + 86_400_000)) / Double(otherRows.count)
        : 0

    return ToolConclusion(
        spend: spend,
        previousSpend: previous,
        deltaPct: SessionStats.deltaPct(current: spend, previous: previous),
        projectedMonth: SessionStats.projectMonth(
            spendSoFar: spend, daysElapsed: daysElapsed, daysInMonth: daysInMonth),
        sessionCount: count,
        commitCount: changes.commits,
        addedLines: changes.added,
        deletedLines: changes.deleted,
        avgCostPerSession: thisAvg,
        cpl: cpl,
        crossToolDeltaPct: otherAvg > 0 ? SessionStats.deltaPct(current: thisAvg, previous: otherAvg) : nil)
}

private static func sourceSpend(source: String, sinceMs: Int64, toMs: Int64) async -> Double {
    do {
        return try await AppDatabase.shared.read { db in
            try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(cost_usd), 0) FROM usage_event
                WHERE source = ? AND ts >= ? AND ts < ?
                """, arguments: [source, sinceMs, toMs]) ?? 0
        }
    } catch {
        Logger.error("StatsService.sourceSpend failed: \(error)")
        return 0
    }
}

static func sessionRows(source: String, sinceMs: Int64) async -> [SessionRow] {
    let toMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000) + 86_400_000
    do {
        return try await AppDatabase.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.session_id AS sid,
                       MIN(u.ts) AS first_ts,
                       MAX(u.ts) AS last_ts,
                       (SELECT in_tokens FROM usage_event u3
                        WHERE u3.source = u.source AND u3.session_id = u.session_id
                        ORDER BY u3.ts DESC LIMIT 1) AS last_input,
                       COALESCE(SUM(u.cost_usd), 0) AS cost,
                       COALESCE((SELECT repo_path FROM usage_event u2
                                 WHERE u2.source = u.source AND u2.session_id = u.session_id
                                 ORDER BY u2.ts LIMIT 1), '') AS repo,
                       s.title AS title,
                       s.window_tokens AS window
                FROM usage_event u
                LEFT JOIN session_info s ON s.source = u.source AND s.session_id = u.session_id
                WHERE u.source = ? AND u.ts >= ? AND u.ts < ? AND u.session_id IS NOT NULL
                GROUP BY u.session_id
                ORDER BY cost DESC
                """, arguments: [source, sinceMs, toMs]).map { row in
                SessionRow(
                    source: source,
                    sessionId: row["sid"] as String?,
                    title: row["title"] as String?,
                    repo: (row["repo"] as String?)?.isEmpty == true ? nil : (row["repo"] as String?),
                    firstTs: row["first_ts"] as Int? ?? 0,
                    lastTs: row["last_ts"] as Int? ?? 0,
                    lastInput: row["last_input"] as Int? ?? 0,
                    cost: row["cost"] as Double? ?? 0,
                    windowTokens: row["window"] as Int?)
            }
        }
    } catch {
        Logger.error("StatsService.sessionRows failed: \(error)")
        return []
    }
}

private static func attributedChanges(source: String, sinceMs: Int64, toMs: Int64) async -> (commits: Int, added: Int, deleted: Int) {
    do {
        return try await AppDatabase.shared.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT c.commit_hash) AS commits,
                       COALESCE(SUM(c.added), 0) AS added,
                       COALESCE(SUM(c.deleted), 0) AS deleted
                FROM code_change c
                WHERE c.repo_path IN (
                    SELECT DISTINCT u.repo_path FROM usage_event u
                    WHERE u.source = ? AND u.ts >= ? AND u.ts < ? AND u.repo_path IS NOT NULL
                ) AND c.ts >= ? AND c.ts < ?
                """, arguments: [source, sinceMs, toMs, sinceMs, toMs])
            return (
                commits: row?["commits"] as Int? ?? 0,
                added: row?["added"] as Int? ?? 0,
                deleted: row?["deleted"] as Int? ?? 0)
        }
    } catch {
        Logger.error("StatsService.attributedChanges failed: \(error)")
        return (0, 0, 0)
    }
}

static func turnSeries(source: String, sessionId: String) async -> ContextTrend {
    do {
        return try await AppDatabase.shared.read { db -> ContextTrend in
            let turns = try TurnPoint.fetchAll(db, sql: """
                SELECT (ROW_NUMBER() OVER (ORDER BY ts)) AS index,
                       ts, in_tokens AS inputTokens, cache_tokens AS cacheTokens,
                       out_tokens AS outTokens, COALESCE(cost_usd, 0) AS cost
                FROM usage_event
                WHERE source = ? AND session_id = ?
                ORDER BY ts
                """, arguments: [source, sessionId])
            let window = try Int.fetchOne(db, sql: """
                SELECT window_tokens FROM session_info WHERE source = ? AND session_id = ?
                """, arguments: [source, sessionId])
            let model = try String.fetchOne(db, sql: """
                SELECT MAX(model) FROM usage_event WHERE source = ? AND session_id = ? AND model IS NOT NULL
                """, arguments: [source, sessionId])
            return ContextTrend(turns: turns, windowTokens: window, model: model)
        }
    } catch {
        Logger.error("StatsService.turnSeries failed: \(error)")
        return ContextTrend(turns: [], windowTokens: nil, model: nil)
    }
}
```

> 说明：`TurnPoint` 需要 GRDB `FetchableRecord` 以支持 `TurnPoint.fetchAll`——将 `struct TurnPoint` 改为：
>
> ```swift
> struct TurnPoint: Identifiable, Equatable, FetchableRecord {
>     var id: Int { index }
>     let index: Int
>     let ts: Int
>     let inputTokens: Int
>     let cacheTokens: Int
>     let outTokens: Int
>     let cost: Double
> }
> ```
> （需 `import GRDB`；`SessionStats.swift` 内 `import GRDB`。）

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter SessionStatsTests`
Expected: PASS（若 `needsCompactionHint` 边界断言失败，按“> 0.8 为 true”修正测试数据为 0.81）。

- [ ] **Step 5: 提交**

```bash
git add Sources/Store/SessionStats.swift Sources/Store/StatsService.swift Tests/SessionStatsTests.swift
git commit -m "feat: session stats models, pure logic, and detail queries"
```

---

### Task 6: 仪表盘结论卡三行 + 打开浮层

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardView.swift`

**Interfaces:**
- Consumes: `StatsService.toolConclusion(source:sinceMs:)`、`rangeSinceMs()`（已存在）。
- Produces: `@State selectedToolForOverlay: String?`；`claudeDetailCard` / `codexDetailCard` 改为 3 行结论；点击卡片设置 `selectedToolForOverlay`。

- [ ] **Step 1: 写失败测试（视图编译门）**

此任务为纯视图改动，无新单测；验证手段 = 编译通过（`swift build`）。实现后运行全量测试确保无回归。

- [ ] **Step 2: 实现 3 行结论卡**

`DashboardView.swift`：

1) 状态调整（新增结论与浮层状态；删除旧模型拆解的 `claudeStats`/`codexStats`/`claudeStatsTS`/`codexStatsTS`/`claudeHoverModel`/`codexHoverModel` 及其 `detailCard` 实现，避免死代码）：

```swift
@State private var selectedToolForOverlay: String? = nil
@State private var claudeConclusion: StatsService.ToolConclusion?
@State private var codexConclusion: StatsService.ToolConclusion?
```

2) `claudeDetailCard` / `codexDetailCard` 改为调用共用卡片（删除原模型拆解内容）：

```swift
@ViewBuilder
var claudeDetailCard: some View {
    conclusionCard(
        conclusion: claudeConclusion,
        toolName: "Claude Code",
        source: "claude-code",
        onOpen: { selectedToolForOverlay = "claude-code" })
}

@ViewBuilder
var codexDetailCard: some View {
    conclusionCard(
        conclusion: codexConclusion,
        toolName: "ChatGPT",
        source: "codex",
        onOpen: { selectedToolForOverlay = "codex" })
}

@ViewBuilder
private func conclusionCard(
    conclusion: StatsService.ToolConclusion?,
    toolName: String,
    source: String,
    onOpen: @escaping () -> Void
) -> some View {
    if let c = conclusion, c.sessionCount > 0 {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(String(format: "$%.2f", c.spend)) · 较上期 \(c.deltaPct >= 0 ? "↑" : "↓")\(String(format: "%.0f", abs(c.deltaPct)))% · 预计 \(String(format: "$%.2f", c.projectedMonth))")
            Text("\(c.sessionCount) 会话 · \(c.commitCount) 次提交 · +\(c.addedLines) 行")
            Text("每次会话 \(String(format: "$%.2f", c.avgCostPerSession)) · 每千行 \(String(format: "$%.2f", c.cpl)) · 较另一工具 \(crossText(c))")
        }
        .font(.caption2).foregroundColor(.secondary)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.leading, 28)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

private func crossText(_ c: StatsService.ToolConclusion) -> String {
    guard let d = c.crossToolDeltaPct else { return "—" }
    return d >= 0 ? "贵 \(String(format: "%.0f", d))%" : "便宜 \(String(format: "%.0f", abs(d)))%"
}
```

3) 加载函数更新：`loadClaudeStats` / `loadCodexStats` 改为填充 `ToolConclusion`（复用 `rangeSinceMs()`）：

```swift
func loadClaudeStats() async {
    let sinceMs = rangeSinceMs()
    let c = await StatsService.toolConclusion(source: "claude-code", sinceMs: sinceMs)
    await MainActor.run { claudeConclusion = c }
}

func loadCodexStats() async {
    let sinceMs = rangeSinceMs()
    let c = await StatsService.toolConclusion(source: "codex", sinceMs: sinceMs)
    await MainActor.run { codexConclusion = c }
}
```

4) body 根部用 ZStack 包裹，浮层未实现前先留空位（Task 7 填充）：

```swift
ZStack {
    existingContent
    if let toolId = selectedToolForOverlay {
        ToolDetailOverlayView(
            toolId: toolId,
            sinceMs: rangeSinceMs(),
            onClose: { selectedToolForOverlay = nil })
            .transition(.opacity)
    }
}
```

> 说明：`existingContent` 为原 body 的完整视图链；包裹时保持 `.frame(width: 700, height: 660)` 在最外层。`ToolDetailOverlayView` 先建空壳（ZStack + “✕”按钮），Task 7 填充内容。

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: 编译通过。

- [ ] **Step 4: 提交**

```bash
git add Sources/UI/Dashboard/DashboardView.swift Sources/UI/Dashboard/ToolDetailOverlayView.swift
git commit -m "feat(dashboard): three-line conclusion card with overlay entry"
```

---

### Task 7: 浮层 UI —— 会话列表 + 行内上下文图表

**Files:**
- Modify: `Sources/UI/Dashboard/ToolDetailOverlayView.swift`（Task 6 创建的空壳）
- Modify: `Sources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `StatsService.sessionRows(source:sinceMs:)`、`StatsService.turnSeries(source:sessionId:)`、`SessionStats.groupSessions(_:)`、`SessionStats.cacheSavings(...)`、`PricingManager.shared.pricing(for:)`。
- Produces: `ToolDetailOverlayView(toolId:sinceMs:onClose:)`。

- [ ] **Step 1: 写失败测试（数据驱动部分）**

视图逻辑薄，测试集中在 Task 5 纯函数；本任务验证 = 编译 + 全量测试回归。

- [ ] **Step 2: 实现浮层**

`Sources/UI/Dashboard/ToolDetailOverlayView.swift` 核心结构：

```swift
import SwiftUI
import Charts

struct ToolDetailOverlayView: View {
    let toolId: String
    let sinceMs: Int64
    let onClose: () -> Void

    @State private var groups: [RepoSessionGroup] = []
    @State private var expandedSessionId: String? = nil
    @State private var trend: ContextTrend?
    @State private var sortByCost = false
    @State private var collapsedRepos: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        groupSection(group)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            Text(toolDisplayName).font(.headline)
            Text("\(String(format: I18n.t("panel.repos_count"), groups.count)) · 共 \(totalCostText)")
                .font(.caption).foregroundColor(.secondary)
            Spacer()
            Picker("", selection: $sortByCost) {
                Text(I18n.t("panel.recent")).tag(false)
                Text(I18n.t("panel.most_expensive")).tag(true)
            }
            .pickerStyle(.segmented).frame(width: 140)
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundColor(.secondary)
        }
        .padding(12)
    }

    private var toolDisplayName: String {
        toolId == "codex" ? "ChatGPT" : "Claude Code"
    }

    private var totalCostText: String {
        String(format: "$%.2f", groups.reduce(0) { $0 + $1.totalCost })
    }

    private func groupSection(_ group: RepoSessionGroup) -> some View {
        let collapsed = collapsedRepos.contains(group.repo)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { toggleCollapse(group.repo) }
            } label: {
                HStack {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    Text(group.repo == SessionStats.noRepoKey ? I18n.t("panel.no_repo_group") : group.repo)
                        .font(.caption).fontWeight(.semibold)
                    Spacer()
                    Text("\(String(format: I18n.t("panel.sessions_count"), group.sessions.count)) · \(String(format: "$%.2f", group.totalCost))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if !collapsed {
                ForEach(sortedSessions(group.sessions)) { row in
                    sessionRow(row)
                    if expandedSessionId == row.sessionId {
                        trendCard(for: row)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func sortedSessions(_ rows: [SessionRow]) -> [SessionRow] {
        rows.sorted { sortByCost ? $0.cost > $1.cost : $0.lastTs > $1.lastTs }
    }

    private func sessionRow(_ row: SessionRow) -> some View {
        let expanded = expandedSessionId == row.sessionId
        return HStack(spacing: 8) {
            Text(timeText(row.lastTs)).font(.caption2).foregroundColor(.secondary).frame(width: 76, alignment: .leading)
            Text(row.title ?? I18n.t("panel.no_title")).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            occupancyBar(row)
            Text(String(format: "$%.2f", row.cost)).font(.caption).monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedSessionId = expanded ? nil : row.sessionId
            }
            if expandedSessionId == row.sessionId, let sid = row.sessionId {
                Task { trend = await StatsService.turnSeries(source: row.source, sessionId: sid) }
            }
        }
    }

    @ViewBuilder
    private func trendCard(for row: SessionRow) -> some View {
        if let trend {
            VStack(alignment: .leading, spacing: 6) {
                contextChart(trend)
                HStack(spacing: 12) {
                    Text(String(format: I18n.t("panel.turns"), trend.turns.count))
                    Text(occupancyText(trend.finalOccupancy))
                    Text(String(format: I18n.t("panel.total_cost"), String(format: "$%.2f", trend.totalCost)))
                    Text(String(format: I18n.t("panel.cache_savings"), String(format: "$%.2f", cacheSavingsText(trend))))
                }
                .font(.caption2).foregroundColor(.secondary)
                if trend.needsCompactionHint {
                    Text(I18n.t("panel.compact_hint"))
                        .font(.caption2).foregroundColor(.orange)
                }
            }
            .padding(8)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func contextChart(_ trend: ContextTrend) -> some View {
        Chart {
            ForEach(trend.turns) { t in
                AreaMark(x: .value("轮次", t.index), y: .value("输入", t.inputTokens))
                    .foregroundStyle(Color.marsGreenLight.opacity(0.35))
                LineMark(x: .value("轮次", t.index), y: .value("输入", t.inputTokens))
                    .foregroundStyle(Color.marsGreen)
            }
            if let window = trend.windowTokens, window > 0 {
                RuleMark(y: .value("上限", window))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.secondary)
            }
            ForEach(Array(trend.compactionIndexes), id: \.self) { idx in
                if let point = trend.turns.first(where: { $0.index == idx }) {
                    PointMark(x: .value("轮次", idx), y: .value("输入", point.inputTokens))
                        .foregroundStyle(Color.deepRed)
                }
            }
        }
        .chartYScale(domain: 0...(trend.windowTokens ?? (trend.turns.map(\.inputTokens).max() ?? 1) * 2))
        .frame(height: 140)
    }

    private func occupancyBar(_ row: SessionRow) -> some View {
        let occ = row.finalOccupancy ?? 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(occColor(occ))
                    .frame(width: geo.size.width * CGFloat(min(occ, 1)))
            }
        }
        .frame(width: 40, height: 4)
    }

    private func load() async {
        let rows = await StatsService.sessionRows(source: toolId == "codex" ? "codex" : "claude-code", sinceMs: sinceMs)
        await MainActor.run { groups = SessionStats.groupSessions(rows) }
    }

    private func toggleCollapse(_ repo: String) {
        if collapsedRepos.contains(repo) { collapsedRepos.remove(repo) } else { collapsedRepos.insert(repo) }
    }

    private func timeText(_ ts: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ts) / 1000))
    }

    private func occupancyText(_ occ: Double?) -> String {
        guard let occ else { return I18n.t("panel.occupancy_na") }
        return String(format: I18n.t("panel.occupancy"), Int(occ * 100))
    }

    private func occColor(_ occ: Double) -> Color {
        occ > 0.8 ? .orange : (occ > 0.5 ? .yellow : .marsGreen)
    }

    private func cacheSavingsText(_ trend: ContextTrend) -> Double {
        guard let model = trend.model,
              let pricing = PricingManager.shared.pricing(for: model)
        else { return 0 }
        return SessionStats.cacheSavings(
            cacheTokens: trend.cacheTokensTotal,
            inPricePerMtok: pricing.inPricePerMtok,
            cachePricePerMtok: pricing.cachePricePerMtok)
    }
}
```

> 注：`SessionRow.lastInput` / `finalOccupancy`、`ContextTrend.model` / `cacheTokensTotal` 已在 Task 5 定义；本任务只需消费。`PricingManager.shared.pricing(for:)` 返回 `ModelPricing`（含 `inPricePerMtok` / `cachePricePerMtok`，见 `Sources/Ingest/PricingCatalog.swift`）。

- [ ] **Step 3: 本地化**

`Sources/Localizable.xcstrings` 新增以下键（10 语言各一，沿用现有 `stringUnit` 结构）：

- `panel.recent`（最近 / Recent…）
- `panel.most_expensive`（最贵 / Most expensive…）
- `panel.no_repo_group`（（无仓库）/(No repo)）
- `panel.no_title`（（无标题）/(No title)）
- `panel.turns`（`%d 轮`）
- `panel.occupancy`（占用 `%d%%`）
- `panel.occupancy_na`（占用 — / Occupancy —）
- `panel.total_cost`（总费用 `%@`）
- `panel.cache_savings`（缓存节省 `%@`）
- `panel.compact_hint`（该会话接近上下文上限，建议压缩/新开会话 / …）
- `panel.sessions_count`（`%d 会话`）
- `panel.repos_count`（`%d 个仓库`）

- [ ] **Step 4: 编译 + 全量测试**

Run: `make test`
Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/UI/Dashboard/ToolDetailOverlayView.swift Sources/Localizable.xcstrings
git commit -m "feat(dashboard): tool session explorer overlay with context trend charts"
```

---

### Task 8: 收尾验证

**Files:** 无新增

- [ ] **Step 1: 全量测试**

Run: `make test`
Expected: 全部 PASS（104 + 新增用例）。

- [ ] **Step 2: 手工冒烟（若环境允许）**

`make run`，打开仪表盘 → 展开 Claude Code / ChatGPT 结论卡 → 点击打开浮层 → 检查：列表按仓库分组、排序切换、行内图表与“压缩/新开会话”提示、无滚动错位、Esc/✕ 关闭。

- [ ] **Step 3: 提交收尾**

```bash
git add -A
git commit -m "chore: final verification for tool detail panel" || true
```

---

## Self-Review 记录

- **Spec 覆盖**：结论卡三行 → Task 6；整窗覆盖浮层 → Task 6/7；会话列表按范围筛选 + 仓库分组 → Task 5/7；行内上下文趋势 + 压缩标注 + 占用提示 → Task 5/7；`session_info` 表与标题截断 → Task 1/2/3；存量回填 → Task 4；本地化 → Task 7 Step 3；验收（口径一致、<100ms、无滚动错位）→ Task 5/8。
- **占位符扫描**：无 TBD/TODO；所有代码步骤给出具体实现；`ToolDetailOverlayView` 依赖的 `SessionRow.lastInput/finalOccupancy`、`ContextTrend.model/cacheTokensTotal` 均在 Task 5 定义并有测试。
- **类型一致性**：`SessionInfoRecord`、`ToolConclusion`、`SessionRow`、`RepoSessionGroup`、`TurnPoint`、`ContextTrend` 在各任务间签名一致；`rangeSinceMs()` 为 DashboardView 既有方法。
