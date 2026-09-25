# AI Pulse 全库代码审查报告（2026-09-24）

- 审查对象：`bc79874`（Optimize macOS refresh pipeline and repository stats）
- 审查方式：7 个并行深审（Engine/Git、Ingest、Store/Sync/Utils、UI/App、共享包与多端、测试质量、构建/CI/安全）逐文件阅读约 3.2 万行 Swift；主审对所有 P0、P1 及关键 P2 结论逐条回读源码复核，未复核条目已标注。
- 验证状态标注：✅ = 主审已亲自回读源码确认；◻️ = 子代理结论（附带精确行号，机制合理但未逐行复核）。
- 构建与测试验证：`swift build` 通过；`swift test` 全量 **443 个测试 0 失败**（4 个环境门控跳过，12 秒）。

---

## 一、总体评价

这是一个**工程质量明显高于平均水平**的代码库：

- **架构分层清晰**：采集（LogWatcher/GitMonitor/ApiPoller）→ 归一（TokenAccounting）→ 存储（GRDB 单一事实源）→ 派生（StatsService 快照）→ 分发（CloudKit + App Group + 菜单栏/仪表盘），职责边界几乎无串扰。
- **防御性设计成熟**：checkpoint 只在完整行边界推进、"空数据"与"查询失败"通过 `readFailures`/`ObservationFailures` 全链路区分、NaN/负值/溢出在入口统一钳制、dedupe key 用 FNV-1a 规避 Swift Hasher 每进程种子问题。
- **测试文化好**：443 个测试、确定性时间注入、错误注入（DB 触发器 RAISE(ABORT)、closure throw）、Swift 与 SQL 双路径对账。
- **隐私文档化取舍**：API key 存 UserDefaults、读 Copilot token 等敏感行为均有注释说明理由。

但同时存在 **1 个地基性 P0**（代码行统计全错）、**约 10 个影响核心体验的 P1**（发布脚本不可用、历史数据日期错、失败快照上云、首启卡死等），以及一条清晰的 P2 主线：**"口头约定代替类型保证"的并发模式**（`@unchecked Sendable` + `nonisolated(unsafe)` 散布多处）与**主线程磁盘 IO 热路径**。

---

## 二、P0（1 条，均已亲验）

### P0-1 ✅ `git_patch_line_stats` 参数顺序错误 → 代码行统计全错
- 位置：`Sources/Engine/GitRepo.swift:179`
- 现状：`git_patch_line_stats(&fileAdded, &fileDeleted, nil, patch)`
- 真实签名（`Libraries/libgit2/include/git2/patch.h:180-184`）：`(total_context, total_additions, total_deletions, patch)`
- 后果：`fileAdded` 实际接收**上下文行数**（≈3×hunk 数），`fileDeleted` 接收**真实新增行数**，真实删除数被 `nil` 丢弃。`code_change.added/deleted` 两列全错（删除恒 0），closing bell 的 `changedLines`、仪表盘代码变更指标全部失真；且 `GitMonitor.swift:186` 的 `stats.added > 0 || stats.deleted > 0` 准入门几乎恒真（文本 patch 上下文行 > 0）。
- 修复：改为 `git_patch_line_stats(nil, &fileAdded, &fileDeleted, patch)`；并决策存量 `code_change` 数据重算或打迁移标记（旧数据 added/deleted 语义不可信）。

---

## 三、P1（10 条）

### 发布流程（2 条，已亲验）

**P1-1 ✅ `make release` 因 scheme 名错误完全不可用**
- `scripts/release.sh:26`：`SCHEME="AIPulse"`，但 `AIPulse/AIPulse.xcodeproj` 的共享 scheme 只有 `AIPulse_macOS`（已列目录核实），不存在名为 "AIPulse" 的 scheme → `xcodebuild archive` 必报 "does not contain a scheme named 'AIPulse'"。
- 修复：`SCHEME="AIPulse_macOS"`（CONTRIBUTING.md 用的正是该名）。

**P1-2 ✅ 版本号兜底逻辑必回落 "1.0"，存在误发布风险**
- `scripts/release.sh:18`：`defaults read .../AIPulse-Info.plist CFBundleShortVersionString || echo "1.0"` —— 已核实该 plist 全文根本没有 `CFBundleShortVersionString` 键（版本由 `GENERATE_INFOPLIST_FILE` + pbxproj `MARKETING_VERSION=2.0.0` 注入）→ VERSION 恒为 "1.0"，且归档参数 `MARKETING_VERSION="$VERSION"` 会把产物版本覆盖为 1.0、命名 `AIPulse-1.0.dmg`，若进入公证/商店流程即以错误版本号发布。
- 修复：`xcodebuild -showBuildSettings -scheme AIPulse_macOS` 读取，或像 `publish-release` 目标一样强制显式传参。

### 数据正确性（2 条）

**P1-3 ✅ Aider 历史事件时间戳全部错**
- `Sources/Ingest/LogParsers/AiderParser.swift:22-26, 58-66, 119-124`
- 两个 `ISO8601DateFormatter`（`.withInternetDateTime[,.withFractionalSeconds]`）都要求带时区（Z 或 ±hh:mm），而文件头注释自述的格式就是 naive 无时区（`:9` `"timestamp":"2026-06-26T10:00:00"`，aider 用 Python `datetime.isoformat()` 产出正是此格式）→ 解析必失败 → 全部回退 `Date()`。aider 全部历史用量被堆到"扫描时刻"当天，日报/周报日期归属全错（dedupe key 含时间戳字符串，故不重复计数，但日期错）。
- 测试夹具 `Tests/AiderParserTests.swift:7` 带 "Z"，与真实产物不符，掩盖了该 bug。
- 修复：补第三级 naive 格式解析（`DateFormatter` + `en_US_POSIX`、按本地时区解释）；用真实 aider 产物重写夹具。同类模式（解析失败回退 `Date()`）散布于 `ClaudeCodeParser.swift:60`、`CodexParser.swift:57-61`、`QwenCodeParser.swift:42-46`、`OpenCodeParser.swift:28-34`、`DeepSeekHarnessParser.swift:91`，建议统一改为回退文件 mtime + 打点计数。

**P1-4 ✅ 降级快照被当新鲜数据缓存并同步上云**
- `Sources/Store/DashboardCache.swift:64-108` + `Sources/Store/StatsService.swift:584-594, 773`（已亲验全链条：`resultOrLog` 把失败降级为空 fallback → `snap.readFailures` 随快照写入 → `DashboardCache.write` 无条件落库 → `read` 只校验年龄/解码/周期等值、**不检查 readFailures** → `CloudSyncService` 原样上云）
- 后果：一次瞬时 DB 故障/繁忙锁产生的"部分失败/全空"快照被缓存整个 TTL（today 5min / week 1h / **30d 12h**），期间即使 DB 恢复也不重算（`DataRefreshCoordinator.swift:327` 时间戳在构建前写入，失败也占满周期），并同步到 iOS/watchOS。macOS 端有"部分读取失败"横幅（DashboardView.swift:2250），但 iOS 端拿到的是带失败标记的空数据且未必展示。
- 修复：`DashboardCache.write` 拒绝（或短 TTL）`readFailures` 非空的快照，read 侧同样校验；phase-4 节流改为构建成功后计时。

### 后台生命周期（1 条）

**P1-5 ✅ iOS 静默推送回调过早返回**
- `Suites/iOS/App/AIPulse_iOSApp.swift:30-33` + `Suites/iOS/App/Notifications.swift:93-102`
- `didReceiveRemoteNotification` 在 Task 里调 `NotificationService.didReceiveRemoteNotification()`（内部又 spawn 一个**不被等待**的 Task）后立刻 `completionHandler(.newData)` → 系统认为后台抓取完成、随即挂起 App → 推送触发的 `fetchAndStore/fetchCurrentPulse/checkSpendAlert` 经常没跑完：推送到了但数据不更新、支出告警不弹，随机复现。
- 修复：在同一 Task 内 `await` 全部工作完成后再调 completionHandler。

### 启动与采集稳定性（4 条）

**P1-6 ✅ 首次启动主线程卡死**
- `Sources/Engine/DataRefreshCoordinator.swift:100`（`start()` ← `applicationDidFinishLaunching` 主线程）同步调用 `SessionInfoBackfill.runIfNeeded()`（`Sources/Ingest/SessionInfoBackfill.swift:10-15`）：主线程枚举 `~/.codex/sessions`、`~/.claude/projects` 全树、逐文件读 64KB + 逐行 JSON 解析。数千历史会话时首启卡死数秒到数十秒，且发生在任何窗口出现前。
- 修复：挪后台 Task，完成后补一次 `notifyDataChange()`。

**P1-7 ✅ 沙盒书签无自愈，授权链静默停摆**
- `Sources/Engine/BookmarkManager.swift:212-227`：`resolveAll` 的 `var isStale = false` 填充后**从未读取**——stale bookmark 不重建不回写；`:196-201`：`createAndSave` 的 `try? bookmarkData` 失败直接 return，无日志、无健康上报，调用方仍当成功。
- 后果：书签失效（系统更新/目录移动）是沙盒应用常态，一旦 stale 不自愈，`~/.claude`、`~/.codex` 等路径访问滑向 `.expired`，日志/git/余额采集全部静默停摆，用户看不到原因（本仓库对家目录的读取全依赖这条授权链）。
- 修复：`isStale == true` 时重建并 save；失败时 `reportIngestError` + UI 提示。

**P1-8 ✅ 主线程磁盘探测热路径（一组同根问题）**
- `Sources/UI/MenuBar/StatusItemController.swift:97`：每次 `.dataDidChange`/`BookmarkManager.didChange` 都在主线程同步调 `LocalDataStatus.current()`（9 个日志路径 stat + 每缓存仓库 2 次 stat + UserDefaults JSON 解码）。
- `Sources/UI/Dashboard/DashboardView.swift:596-600`、`Sources/UI/Settings/DataAndSyncTab.swift:82`：`.onReceive(Timer.publish(every: 30))` 无可见性守卫——窗口关闭仅 orderOut，隐藏后仍每 30 秒主线程跑磁盘探测；且 body 内联 Timer 每次重绘被重建。
- `Sources/UI/Settings/SettingsView.swift:299-307`：`AccountAndCostsTab` 在 body 的 `ForEach` 内直接 `integration.detect()`（ClaudeCode 检测含 `contentsOfDirectory(~/.claude/projects)`）——每次父视图重渲染都枚举目录。
- 修复：`LocalDataStatus.current()` 加短 TTL 缓存或移后台；定时器加可见性守卫；detect 结果进 `@State`（同文件 DevToolsTab 已有正确范式）。

**P1-9 ✅ Claude 日志每 30 秒全量重读前缀（常驻 CPU/IO）**
- `Sources/Ingest/LogWatcher.swift:229-231`：`scanClaudeCode` 对**每个** jsonl **每次扫描**（30s 节奏）无条件执行 `discoverAndWatchRepo(from:)`（重读 4KB）+ `SessionInfoBackfill.claudePrefixMetadata(from:)`（重读 4KB，对前缀每行最多 8 次 `JSONSerialization`），与 checkpoint 增量设计相悖。几百个会话文件时每 tick 数千次 4KB 读 + 数十万次 JSON 解码，全部压在串行 scanQueue 上，拖慢所有 provider 摄入并常驻耗电。
- 修复：给前缀元数据加 (size, mtime, fileNumber) fingerprint 缓存（`insertOpenCodeFile` 已有正确范式），或只在文件首次见到/无 checkpoint 时读前缀。

**P1-10 ◻️ GitMonitor 首扫全历史遍历 + 每 commit 重开仓库**
- `Sources/GitMonitor/GitMonitor.swift:170-177` + `Sources/Engine/GitRepo.swift:52-103, 125-127`：首扫（lastHash=nil）或游标失效（rebase）时 revwalk 只 push HEAD、遍历全部可达历史，仅靠循环内 `timestamp >= since`（`:91`）过滤 29 天；`diffTree` 每 commit 重新 `git_repository_open`；`verifiedWorkingRoot`（GitRepo.swift:40-41）每次一对 `git_libgit2_init/shutdown` 被逐目录调用。
- 后果：老仓库（数万 commit）首扫阻塞 gitOpQueue 使 5min 轮询堆积。
- 修复：为 29 天边界补 hide 锚点或按时间提前终止；GitRepo 改为持有句柄的批量 API。

---

## 四、P2 精选（18 条）

### 数据正确性 / 存储

| # | 状态 | 位置 | 问题 |
|---|---|---|---|
| P2-1 | ✅ | `Packages/.../SpendAlertRules.swift:53-61, 68-77` | `baseline == 0` 时倍数条件恒真，等级完全由绝对 floor 决定：新用户首日支出 $10 即触发 critical（`10 >= rateFloorL3(10) && 10 >= 0`）——"基线越低告警越狠"，与倍数激增语义相悖。连带：`median` 不过滤 NaN → NaN 基线使所有比较为 false → 告警静默失效。修复：要求 `baseline > 0` 才启用倍数比较，入口过滤 `isFinite` |
| P2-2 | ✅ | `AppHealthMonitor.swift:158-160` vs `UsageMonitor.swift:163,177,188` | API 错误恢复按 `"copilot-usage:"` 前缀删消息，但 UsageMonitor 存的是 `"Copilot usage: ..."`（ApiPoller 路径带前缀不受影响）→ Copilot 恢复后错误横幅残留，直到被 20 条上限挤出。修复：reportAPIError 统一加前缀或结构化存储 |
| P2-3 | ✅ | `Database.swift:403-415` | `addColumnIfMissing` 吞掉迁移错误只打日志，`setup()` 照常返回成功——若 `reasoning_tokens` 加列失败，引用该列的全部聚合查询持续 throw，仪表盘整体不可用且无自愈信号。修复：失败上抛或启动末尾 schema 断言 |
| P2-4 | ◻️ | `Database.swift:64` | `DatabaseQueue(path:)` 默认配置，未开 WAL（GRDB 7 默认 DELETE journal）——本应用写事务频繁（游标 checkpoint、批插、5min 缓存重写），DELETE 模式每事务 journal 创建/删除 + fsync。建议 `config.journalMode = .wal` |
| P2-5 | ✅ | `Database.swift:150-172` | `backfillKnownProviderAttribution` 无一次性开关：凡存在"model 非空但目录归类失败"的行，每次启动全表 SELECT + 逐行 UPDATE（同值）+ `DELETE FROM dashboard_cache`（清空全部派生缓存 → 三档快照整体重建）。修复：包 UserDefaults 一次性 key（同文件 :92-134 已有先例） |
| P2-6 | ◻️ | `CloudSyncService.swift:139-149, 186-197, 220-234` | 三处 CloudKit 写均 `savePolicy: .allKeys`、无 `CKError.serverRecordChanged` 冲突处理、无重试/退避/网络可用性判断；失败靠下个 5min 周期隐式重试。当前单写者下概率低，但多 Mac 场景 last-writer-wins、iOS 一旦开始写同名 record 将永久失败 |
| P2-7 | ✅ | `DataRefreshCoordinator.swift:310-336` | `runPhase4` 每 5min 无条件 `Task.detached` 无 in-flight 去重（上一轮超 5min 时两轮并发全量快照）；且 `:327` 在快照成功**前**写 `cache_refresh_*` 节流时间戳，失败刷新被吞一轮（与 P1-4 复合） |

### Ingest 稳定性

| # | 状态 | 位置 | 问题 |
|---|---|---|---|
| P2-8 | ✅ | `LogWatcher.swift:746-751` | `url.lastPathComponent.hasPrefix("chats")` 会匹配 `chats` **目录本身** → 当日志文件传入 FileHandle → 抛错被 catch → 每 30s 每目录记一次 error 并上报健康监控，checkpoint 永不推进、错误永不清除。装了 Qwen Code 的用户持续刷告警噪音 |
| P2-9 | ◻️ | `LogWatcher.swift:206-218, 306-318` | kqueue `DispatchSourceFileSystemObject` 只监视被 open 目录的直接子项增删改名；Claude 写 `projects/<proj>/*.jsonl`、Codex 写 `sessions/Y/M/D/*.jsonl` 的**追加**几乎不触发事件——watcher 形同虚设，实时性实际全靠 30s 轮询（不丢数据，但名不副实+无效唤醒）。按文件粒度监视或删除 |
| P2-10 | ◻️ | `LogWatcher.swift:504-531` | DSH zstd 策略"size 变了就整文件从 0 重解压+全事件重放"：活跃会话每 30s 完整解压一遍 + 全事件 EXISTS/INSERT；失败路径无冷却期——损坏的 500MB 日志每 30s 无限重试全量解压，可长期拖住 scanQueue。建议流内按已重放行数跳过 + mtime 冷却期 |

### 并发（"口头约定代替类型保证"主线）

| # | 状态 | 位置 | 问题 |
|---|---|---|---|
| P2-11 | ✅ | `CodexThreadTitles.swift:12-15` | `title(for:)` 调完锁内 `loadIfNeeded()` 后在**锁外**读 `nonisolated(unsafe) static var cache`，与另一队列锁内写构成数据竞争；附带：打开库失败 `cache = [:]` 被永久缓存不再重试 |
| P2-12 | ◻️ | `ApiPoller.swift:146-166` vs `68-137, 348-358` | `fetchOpenAIUsage` 的 `Task{}` 在全局执行器上直接调 `cacheBalance/saveBalanceCache`（UserDefaults 读-改-写），与固定切主线程的 fetchSimple 路径可并发 → 同时配置多 key 时缓存互相覆盖丢失更新。收敛到单一串行执行器/actor |
| P2-13 | ◻️ | `IntegrationRegistry.swift:58, 64-66` | `nonisolated(unsafe) var storefrontCountryCode` 无同步跨线程写（String 赋值非原子） |
| P2-14 | ✅ | `DataRefreshCoordinator.swift:52`、`Database.swift:4-7` | `@unchecked Sendable` + 无锁可变状态全靠"调用方都在主线程/先 setup 后使用"的口头约定，编译器不设防。建议 `@MainActor` 化 / 构造注入 let（另见 `MenuBarController.swift:6-9`、`OnboardingView.swift:158-160` 的窗口管理单例） |

### 安全 / 隐私 / 供应链

| # | 状态 | 位置 | 问题 |
|---|---|---|---|
| P2-15 | ✅ | `ApiKeyManager.swift:11-22`（取舍已注释）+ `PasteableTextField.swift:35-43`（UI 代理） | API key 明文存 UserDefaults（容器 plist 可被同用户进程 `defaults read`、随容器备份）；`maskedVersion` 未聚焦时**明文显示前 8 个字符**（对前缀非标准化的服务商属有效熵泄露）。短期改"前 3 后 4"显示；长期评估 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` Keychain |
| P2-16 | ✅ | `Sources/Utils/Logger.swift:92-96` + `GitMonitor.swift:122, 209-222` | Release 下 error 级日志以 `%{public}@` 公开写入统一日志（其余级别/平台默认 `%{private}`），而 GitMonitor 把含用户家目录的完整 repo 路径写进 health 消息经 Logger.warning/error 输出 → 路径/用户名公开持久化。脱敏或 `%{private}` |
| P2-17 | ✅ | `.github/workflows/cla.yml:9-13, 26` | `pull_request_target` + `issue_comment` 触发、workflow 级 `contents: write`，第三方 action `contributor-assistant/github-action@v2.6.1` 按可移动 tag 引用——上游 tag 被劫持时任意 PR 评论者可触发携带写权限 token 的代码执行（当前 action 未 checkout PR head，无直接 RCE，属防御缺失）。pin 到 commit SHA + 权限收窄到 job |
| P2-18 | ✅ | `.github/workflows/ci.yml`、`release.yml`（全文件） | 均无 `permissions:` 块（GITHUB_TOKEN 取仓库默认权限）；`actions/checkout@v5`、`softprops/action-gh-release@v2` 均按 tag 引用。CI 只需 `contents: read`、release 只需 `contents: write`，显式声明并 pin SHA。另注：CI 只做 `swiftc -parse` + 脚本校验，**不构建不测试应用**，签名产物完全脱离 CI 可重复性 |

### 多端 / UI

| # | 状态 | 位置 | 问题 |
|---|---|---|---|
| P2-19 | ◻️ | `AIPulse/AIPulseMacWidget/MacWidgetData.swift:269-273` + `MacWidgetView.swift:280-294` | `shouldOpenApp` 在 `loadStatus != .available` 时也返回 true，导致 `.waitingForRefresh/.noData/.failed` 三个状态分支不可达——无数据/失败一律显示"打开仪表盘"CTA，状态语义丢失 + 死代码误导 |
| P2-20 | ◻️ | 跨 target 重复实现群 | 同一段 I18n 逻辑 4 份（`Suites/Shared/I18n/I18n.swift:48-55`、`WidgetViews.swift:5-16`、`AIPulseWatchWidget.swift:7-17`、`MacWidgetView.swift:5-16`，已现 `hasPrefix("en")` vs `lang == "en"` 分歧）；PulseTier 文案 switch 3 份；环形进度视图 4 份（共享 `ActivityRing.swift` 反而零调用，Mac 版已漂移缺弧端亮点）；App Group id 与缓存文件名 3 处硬编码——单侧改名小组件静默变"无数据"。全部下沉 AIPulseShared |
| P2-21 | ◻️ | `Suites/iOS/UI/DashboardView.swift:196-225` | 440pt 固定设计 scaleEffect 等比缩放 + 全部 `.font(.system(size:))` 固定磅值，完全忽略 Dynamic Type（watch 端正确用了 `@ScaledMetric`）——大字号用户在 iPhone 上无法阅读 |
| P2-22 | ◻️ | `Sources/UI/Settings/GeneralAndNotificationsTabs.swift:250-262` | 免打扰时段 TextField 每键击 `.onChange` 直写 UserDefaults 且无格式校验/回弹（`CoinSound.parseHM` 解析失败静默不生效）——输入 "9am" 坏值被持久化、免打扰静默失效。失焦校验 + 恢复合法值 |
| P2-23 | ◻️ | `Tests/GitMonitorTests.swift:95-102`、`Tests/UsageMonitorTests.swift:72-87` | 同义反复/名不符实测试：断言测试自己代码的整数减法、名为 max 选择实际只断言字段回显——生产逻辑回归不会红，制造假覆盖 |

---

## 五、P3 汇总（43 条，按主题归组）

**正确性/防御性**
- 解析器时间戳失败统一回退 `Date()`（5 处，见 P1-3）；Codex/Qwen 只配 `.withFractionalSeconds` 单格式（`CodexParser.swift:17-21,57`、`QwenCodeParser.swift:10-14,42`）
- `CopilotChatParser.swift:44-47, 201-203`：浮点补丁 `integerValue == nil` 会**清空**已有 tokens 可能丢事件
- `LogWatcher.swift:1232, 1268-1286`：>64MB 超长行跳过后 checkpoint 越过未终结前缀（无计数错乱，极端行被静默肢解）
- `ApiPoller.swift:143-151`：`DateFormatter` 未设 `en_US_POSIX`/显式时区，非公历 locale 下 OpenAI 用量 3 天全失败且 `try? … continue` 全静默；`:162` `total > 0` 不区分"确认为 0"与"请求失败"，余额面板静默展示陈旧值
- `LogWatcher.swift:789-804`：OpenCode 无 usage 文件解析返回 nil 不记 fingerprint，每轮重读重解析
- `RepoDiscovery.swift:28-31`：未规范化路径对比 + 未实际插入也 `count += 1` 虚报
- `EditorDetector.swift:103-104` vs `IntegrationRegistry.swift:129`：月费反推 `*30` 与当月实际天数口径不一（二月漂移 +7.1%）
- `CopilotChatParser`/`CodexThreadTitles`：失败结果被永久缓存
- `LogWatcher.swift:825-826`：aider markdown 行闭包内每行 stat 取 mtime（应提到循环外）
- `SessionStats.swift:102`：纯逻辑层用中文文案 "（无仓库）" 作分组 key

**性能**
- `LogWatcher.swift:639-643, 696-730`：Codex 重启后从 0 重读至 lastPos 重建元数据（大文件秒级阻塞）
- `LogWatcher.swift:965-992`：每行 `SELECT EXISTS` + `INSERT ON CONFLICT` 双语句（可 `RETURNING`/`db.changes` 合并）
- `StatsService.swift:637-699`：单快照对 usage_event 同范围独立扫描约 6 次，13 路 async let 在单 DatabaseQueue 上串行且互不原子（当前量级可接受）
- `Sources/UI/Dashboard/DashboardView.swift:83-127`：根视图约 40 个 `@State`，任一变化全 body 重求值；`I18n.swift:148-150` en 回退字典不缓存每调用读盘
- `DockManager.swift:40` + `AppIconLoader.swift:119-144`：每次 beat 翻转主线程合成两张 1024² 位图（有 renderedKey 去重但无图像缓存）
- `UsageMonitor.swift:59-72`：每 30s 主线程同步读 Claude 状态缓存（文件小，影响轻）
- `GitMonitor.swift:132`：每 5min 无条件 `persistWatchedRepos()` 即使无变化
- `ApiPoller.swift:8-13`：无重试/退避/429 处理

**死代码 / 风格**
- `Sources/UI/MenuBar/MenuBarController.swift:123-441`：全仓库无实例化（grep 亲验），内含"复活即 bug"的重复建窗逻辑；同文件 `SettingsWindowManager` 是活代码应迁出
- `Sources/Engine/EditorDetector.swift`：生产路径已死（`DashboardView.swift:97` 声明从未赋值，编辑器订阅检测永不执行），且 `detect()` 为 nonisolated 却调 `NSWorkspace.shared.runningApplications`
- `DashboardView.swift` 8 个无引用成员（`hasActiveCostSources`、`smallCard` 等）；`Suites/iOS/UI/DashboardView.swift:5-12` `FrostedCard` 等 3 个零使用；`CloudDataService.swift:236-273` refresh/fetchAndMergeWeek/Month 零调用
- `CoinSound.swift:231` 函数末尾死 guard；`ClaudeCodeIntegration.swift:17`、`CGradeIntegrations.swift:16/46/76` 四处 `_ = Double(...)` 复制粘贴残留
- `StatusItemController.swift:24,32`：`start()` 内 `buildMenu()` 连调两次
- `BookmarkManager.swift:246-250`：`stopAll(_ urls:)` 参数被忽略；`:81` `NSHomeDirectory()` 与 `realHomeDirectory` 不一致
- `UsageMonitor.swift:154`：常量 `URL(string:)!` 强解包；`StatsService.swift:618,650,982`：`fetchOne(...)!` 强解包（当前 SQL 恒返回一行）

**UI/UX/无障碍**
- `DashboardView.swift:1927,1932`：关闭/设置纯图标按钮仅 tooltip（整体 `.accessibilityHidden(true)`），VoiceOver 无标签；`:612` `.id(i18nToken)` 语言切换整树重建重跑加载
- `CursorModifier.swift:7-19`：悬停中视图被移除时 cursor 卡 pointing hand（缺 `.onDisappear` 兜底）
- `ToolDetailOverlayView.swift:505-509`：DateFormatter 未固定 locale

**配置/发布/文档**
- `AIPulse/AIPulse-Info.plist:5` 等 3 处：`CloudKitAccessEnabled` 值为 `$(CODE_SIGNING_ALLOWED)` 字符串展开（语义脆弱）
- `Suites/iOS/Info.plist:48-51`：`UIRequiredDeviceCapabilities` 含 `armv7` 模板残留
- `Suites/AIPulseWatchWidgetExtension.entitlements:4-12`：widget 扩展持有 `aps-environment` 与 iCloud 服务待复核删减
- `scripts/release.sh:89-93`、`make-dmg.sh:203-207`：notarytool `--apple-id/--password` 明文传参（`ps` 可见）；建议换 App Store Connect API key；本机 `.env` 权限 0644 含真实凭据
- `Makefile:21-29`：`pkill -f "\.build/.*AIPulse"` 模式过宽；`make-dmg.sh:96` `-size 50m` 硬编码；两套 DMG 管线已漂移
- `.gitignore` 缺 `artifacts/`（untracked 含 2×16.8MB trace + 15MB 截图；本地 `refs/codex/*` 已使其 blob 驻留对象库，pack 76MB）——加 ignore + prune + gc
- `Libraries/libgit2/`：无 README/LICENSE，/tmp 本机构建的 arm64 dylib 无来源/校验和；三重名 dylib（同一 blob）+ dSYM 应清理（对照 zstd 的 README+LICENSE 正确范式）
- 文档脱节：`README.md:8,113,115` "iOS 16+" vs 实际 iOS 17（17.6）；`CONTRIBUTING.md:3` "iOS development paused" 与 2.0 全端发布矛盾；`docs/release-workflow.md` 草稿流程与 `release.yml` tag 触发互相触发重复草稿；`scripts/generate-icons.py:20,194,200` 引用已删除的 build-app.sh
- Swift 并发模型分叉：Xcode target `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` 而 `Package.swift` 无 `.defaultIsolation`——同一份 Sources 两种隔离语义（`RepoScanCache.swift:26-30` 注释自证）
- 杂项：`MacWidgetLocalPayload.swift:108` 弃用 `synchronize()`；`CloudDataService.swift:325-343` DEBUG installPreview 写真 App Group；`AIPulse_WatchApp.swift:120-124` release 也读 ProcessInfo.arguments；iOS widget displayName 仅英文（watch 均双语）；`DiagnosticJournal.swift:224-231, 306-317` 重试计数与重复列举小瑕

---

## 六、分模块小结

| 模块 | 规模 | 评价 |
|---|---|---|
| **Sources/Engine + GitMonitor + Integrations** | 29 文件 / ~4000 行 | 调度-感知核心，libgit2 资源纪律好（defer 成对 free、退出有意不 shutdown 均有注释）。承载全库唯一 P0（行统计），另有 Git 首扫性能、书签自愈两个硬伤 |
| **Sources/Ingest** | 19 文件 / ~3300 行 | 摄取唯一入口。checkpoint/幂等重放/内存防线设计是全库最扎实的部分；但 Aider 日期 bug、Claude 前缀重读风暴、Qwen 目录误判直接影响正确性与常驻开销 |
| **Sources/Store + Sync + Utils** | 18 文件 / ~3100 行 | SQL 全参数化零注入、口径单一事实源、readFailures 可观测性设计出色。短板在失败快照的缓存/同步链路、迁移吞错、无 WAL |
| **Sources/UI + App** | 26 文件 / ~5300 行 | Demo 数据隔离严格（无任何 demo→磁盘/云通路）、代次守卫与 Reduce Motion 贯彻好。主问题是 LocalDataStatus/detect 的主线程 IO 热路径、DashboardView 巨型视图、MenuBarController 死代码 |
| **Packages/AIPulseShared + Suites 多端** | 28 文件 / ~4400 行 | CloudKit 版本契约（独立 record type + 最小 envelope 探版本）、ChartMath 数值防线、Widget 刷新预算纪律好。iOS 推送回调生命周期 bug（P1-5）+ 跨 target 四重实现漂移是主要债 |
| **Tests** | 78 文件 / 6323 行 / 443 用例 | 确定性时间注入、错误注入、Swift/SQL 双路径对账——设计水平高。缺口集中在 ApiPoller（375 行 vs 14 行测试）、schema 迁移（唯一迁移测试被 env-gate 跳过）、LogWatcher 扫描循环、CloudSync 状态机、libgit2 diff 行数；2 个同义反复测试 |
| **构建/CI/发布** | — | 依赖锁定规范（唯一远端依赖 GRDB 按 revision 锁定）、无密钥泄漏历史、沙盒豁免最小化。但 `make release` 双硬伤当前不可用（P1-1/2）、CI 极薄（不构建不测试）、action 全部 tag 引用 |

---

## 七、测试套件评估（详见测试审查）

**覆盖好的**：TokenAccounting（Swift+SQL 对账、饱和/负数钳制）、JSONLCheckpoint/LogCheckpointStore（失败注入、回滚、`PRAGMA quick_check`）、PulseEngine（固定 now、半衰期验算）、时区/DST（显式构造 Asia/Shanghai、America/New_York）、7 个解析器正常路径。

**最值得补的 5 个测试**：
1. ApiPoller 供应商余额解析表驱动测试（钱数直出 UI，可测性极好却零覆盖）
2. 合成旧 schema → `AppDatabase.setup(at:)` 迁移测试（当前唯一迁移测试被 `AIPULSE_QA_*` 环境变量 gate，默认 CI 零验证）
3. LogWatcher 上下文重建 + 中断续扫的合成日志测试（codexResumeMetadata 半途续扫、截断回退）
4. CloudSyncService 同步状态机测试（账户禁用/部分周期/写失败 → result）
5. GitMonitor 端到端行数统计测试（真实 temp repo 验证 added/deleted/merge 排除——顺带消灭两个同义反复测试，并会在修复 P0-1 时立刻抓到回归）

---

## 八、安全 / 隐私 / 供应链专项结论

1. **密钥泄漏：未发现**。`git log --all --full-history -- .env` 为空；全历史对象 grep 凭据格式零命中；`.env.example` 仅占位符。残余风险仅在本机：`.env` 0644 含真实凭据（建议 `chmod 600`）。
2. **隐私**：API key//token 不落日志（逐点核实）；但 Release error 级日志 `%{public}@` + 含家目录路径的 health 消息构成公开持久化面（P2-16）；API key 明文 UserDefaults（P2-15，已文档化取舍）。
3. **沙盒**：macOS 主 app 豁免最小化（sandbox + network.client + user-selected.read-only + CloudKit + 单一 app group），与隐私声明吻合；watch widget 扩展的 aps/iCloud 待复核。
4. **CI 供应链**：攻击面小（无自定义 secrets、无 cache、不执行第三方 Swift 依赖）；缺口是全部 action tag 引用 + cla.yml `contents: write` + 无 permissions 块（P2-17/18）。
5. **vendored 二进制**：libgit2 1.9.0 / zstd 1.5.7 版本明确、arm64-only 与 EXCLUDED_ARCHS 自洽；libgit2 为 /tmp 本机构建、无配方/校验和/许可文本，建议补齐（P3）。

---

## 九、建议修复路线图

**第一批（正确性地基，1-2 天）**
1. P0-1 `git_patch_line_stats` 参数 + 存量数据重算决策
2. P1-1/P1-2 release.sh scheme 与版本号（发布前必须）
3. P1-3 Aider naive 时间戳 + 解析器回退策略统一（回退 mtime + 打点）
4. P2-1 SpendAlertRules baseline==0 + NaN 过滤

**第二批（数据链路可靠性，2-3 天）**
5. P1-4 失败快照拒绝缓存/上云 + phase4 时间戳后置（与 P2-7 同改）
6. P1-5 iOS 推送 completionHandler
7. P2-3/P2-5 迁移失败上抛 + backfill 一次性化（+P2-4 WAL）
8. P1-7 BookmarkManager stale 自愈与失败上报
9. P2-6 CloudKit serverRecordChanged 处理 + 指纹持久化（复用 stableHash）

**第三批（性能与常驻开销，2-3 天）**
10. P1-9 Claude 前缀 fingerprint 缓存
11. P1-6 SessionInfoBackfill 移出主线程
12. P1-8 主线程探测热路径（TTL 缓存 + 可见性守卫 + @State 化 detect）
13. P2-8 Qwen chats 目录条件收紧；P1-10 Git 首扫 hide 锚点
14. P2-10 DSH 增量截断 + 失败冷却期

**第四批（工程加固，随迭代）**
15. CI permissions + action pin SHA + （可选）CI 跑 `swift test`
16. 并发类型化清理：`@unchecked Sendable`/`nonisolated(unsafe)` 逐个消除（P2-11/12/13/14），Package.swift 与 Xcode 的 defaultIsolation 对齐
17. 跨 target 四重实现下沉 AIPulseShared（P2-20）
18. 覆盖缺口五测试（第七节）+ 删除同义反复测试
19. 死代码清理（MenuBarController、EditorDetector 接线或删除、DashboardView 8 成员）
20. vendored libgit2 README/LICENSE、artifacts/ ignore + prune、文档脱节修正

---

## 十、值得肯定的亮点（全库级）

1. **幂等重放地基正确**：完整行边界 checkpoint + FNV-1a 稳定哈希（并点破 Swift Hasher 每进程种子问题）+ 持久化失败整体放弃推进——"宁可重放不可丢失"贯穿始终。
2. **"空 ≠ 失败" 全链路可观测**：`ObservationFailures` TaskLocal → `readFailures` 随 payload 到 UI/云端，配 AppHealthMonitor 分级上报与 DiagnosticJournal 黑匣子。
3. **TokenAccounting 单一口径**：三家工具的 token 语义归一收敛为一个模块的 SQL/Swift 双实现且严格一致，全程 saturating 加法。
4. **CloudKit 版本契约**：独立 record type 防旧写手覆盖 + 最小 envelope 先探版本 + VersionMismatchView 明确升级方向；`CurrentPulseEnvelope` 绝不复活过期观测。
5. **Demo 数据零外泄**：demo 路径只写内存通道，forceRefresh 的 demo 分支在上云前 return，未发现任何 demo→磁盘/iCloud 通路。
6. **数值边界防线**：ChartMath/ApiPoller/cacheBalance 对除零、NaN/Inf、负值、Int 溢出全部显式守卫且有测试；注释点破"SQLite NaN→NULL→0 会伪造余额清零"这类深坑。
7. **Reduce Motion 与无障碍是认真的**：全局 transaction 禁动画、三端脉冲时钟逐点检查、矩阵/构成图自定义 accessibility 值。
