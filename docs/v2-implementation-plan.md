# AI Pulse v2 实施计划（P0 燃烧闭环 · P1 状态外显 · P2 全端感知）

> 版本 v1.2 — 2026-09-12 · **状态：P0 + P1 + P2 已全部实施完毕**
> v1.2：全部 WI 落地；新增 §0 实施状态（工作项总表 + 实战修复记录 + 遗留项）。
> v1.1：新增 WI-8 零配置启动重构（对应产品设计 §4.7）。
> 依据：`docs/PRODUCT_DESIGN.md` v2.0-draft r6。**冲突以产品设计文档为准**；本文是其工程实施口径。
> 所有现状描述均经代码核实（含 file:line）。

> **2026-09-13 方向校准：** 本文的“P0 + P1 + P2 已完成”只代表旧版 money-first 工作项已经落地，不代表新的“消费脉搏”目标已经实现。当前权威语义与后续阶段以 `docs/data-facts-and-surfaces.md` v2.2 为准：阶段 A/B 已完成，阶段 C/D 待实施；本文中“钱是统一分母”与旧 `todayCost` 跨端口径均属于待替换兼容实现，估算金额已不再驱动 macOS 脉搏和声音。

---

## 0. 实施状态（2026-09-12 收官）

### 0.1 工作项状态总表

| WI | 状态 | 提交 | 验收结论 |
|---|---|---|---|
| WI-1 BurnRateEngine | ✅ | `69ca778` | 共用基线 `HourlyBaseline` 落地，AnomalyDetector 行为逐值一致；B 级余额差值按防双算并入（§4.4 的核对修正：余额差值在 `balance_snapshot` 而非 `usage_event`） |
| WI-2 消费事件载荷化 | ✅ | `dac2bb1` | `ConsumptionEvent` 总线；ApiPoller 收编；Git 扫描/缓存刷新不再响铃；`lastSoundBadgeLabel` 口径废除 |
| WI-3 CoinSound 心跳 | ✅ | `dac2bb1` | 纯函数决策 + AVAudioPlayer 独立音量 + 跨午夜静音 + 每小时上限 + 档位缩放合并窗 |
| WI-4 设置感知组 | ✅ | `dac2bb1` | 音量/静音时段/上限/收盘钟/启动钟 + 7 个 i18n 键 |
| WI-5 归因兜底 | ✅ | `3eb39e8` | trailer（exact）+ 编辑器会话（uncertain）双信号；`code_change` +2 列；归因行数接入燃烧率 |
| WI-6 菜单栏状态项 | ✅ | `2fd3aba`→`1187d33` | 新表面（F10 核实：原无 NSStatusItem）；档位着色渲染修正（template → 实色位图） |
| WI-7 收盘钟 | ✅ | `2fd3aba` | 惰性日检（无新定时器）；今日总额 + 峰值小时；豁免上限、不豁免静音 |
| WI-8 零配置启动 | ✅ | `9477bd8` | 引导 4→3 步；套餐目录价预填（一次性迁移，新老安装覆盖）；Key 降为增强；盲区诚实提示 |
| P2 Dock 环色 + 徽章口径 | ✅ | `0ea8df6` | 环色映射燃烧档位（健康度保留为角点）；徽章切 `consumptionSpend`（A+B） |
| P2 声音包 | ✅ | `0ea8df6` | coin 包沿用项目方提供的两个 MP3，缺少的 chime 与 droplet/register 六个提示音由 `scripts/gen_sound_packs.py` 纯合成、无第三方采样；多格式解析 + 设置选择器/逐项试听 |
| P2 全端同步 | ✅ | `28f118d` | 快照加 4 个可选燃烧字段（加法契约，无 payloadVersion bump，契约测试钉死）；iOS 横幅 + watchOS 燃烧行/触觉 |

### 0.2 实战修复记录（真机反馈暴露，已归档）

| 提交 | 问题 | 根因 | 修复 |
|---|---|---|---|
| `3d961fe` | Codex 有消费但金额为 0；菜单"今日"恒为固定 3.3 | 价表缺 4 个新 Codex 模型 → 2,302 条事件 cost=NULL；菜单口径（combinedSpend=B+C）不含 A 级估价，3.3 实为预填订阅摊销 | 价表补家族档位价（估算，待官方牌价）；`CostBackfill` 新增 NULL 成本回填；新增 `StatsService.consumptionSpend`（A+B 消费总账）并切换状态项/Dock 菜单/收盘钟 |
| `d29e0c4` | DeepSeek Harness 用量自 9/10 20:29 断流 | Harness 发布 v3 日志（新文件名 `session.v3.jsonl.zstd` + usage 载体移位至 `assistant/message → data.usage`），扫描器只匹配旧名 | 扫描器改 `session*.jsonl.zstd` 前缀匹配；解析器双载体兼容；+3 测试 |
| `1187d33` | 火焰四档颜色不显示；状态项与统计重复感 | template 图标在菜单栏恒为单色，contentTintColor 不生效；Dock 右键菜单缺燃烧标题 | 档位色烘进非 template 位图（sourceAtop）；燃烧标题行同步进 Dock 右键菜单（共用 `burnLine` 格式化） |
| `6f2ba0e` | watch widget target 添加后仍是模板代码 | 用户在 Xcode 添加 target（工程侧完成），实现侧待完成 | 重写为自包含实现（本地最小解码结构，免 AIPulseShared 链接）；删除模板 Bundle/Control；对 watchOS SDK typecheck 通过 |

### 0.3 遗留与后续（按优先级）

1. **P2.5 候选 · 采集源健康度可见性**：DSH v3 断流静默持续两天才被发现。建议在设置或健康面板展示"各采集源最近入库时间"，把采集静默从隐形变可见。
2. **P2.5 候选 · 未计价 token 可见性**：新模型缺价 → 金额静默的模式会复发。建议提示"近期 N tokens 未计价（模型缺价）"。
   完整分析见 `docs/data-facts-and-surfaces.md`（事实/估算/上下文三层框架 + 出口×形态展示设计 + 落地差距清单）。
3. **P3 · 叙事切换**：App Store 文案 / README / 首屏截图改为"实时电表"叙事（`docs/appstore-description.md` 需改写）。
4. **分支收编**：`codex/today-metric-token-format`（WIP 已提交于 `ca30e5f`）与 `codex/dynamic-island` 未合回 main；与 v2 分支在 `DataRefreshCoordinator` 有小冲突点。
5. **表盘小组件真机验证**：target + 自包含代码已就绪（`6f2ba0e`），需 Xcode 构建一次 Suites（新 target 首次编译）并真机添加表盘槽位。清单见 `docs/watchos-widget-checklist.md`。
6. **验证边界备忘**：SPM 测试只覆盖 macOS 目标（188 → 230 全绿）；Suites 的 iOS/watchOS/Widget UI 改动需在 Xcode 构建——小组件已单独对 watchOS SDK typecheck 通过，其余以 Xcode 构建为准。
7. **价表维护**：新模型缺价的模式会复发；`Resources/pricing-catalog.json` 补价后 `CostBackfill` 自动修复历史（keyed one-shot），估算价需随官方牌价修正。

### 0.4 开放决策执行记录

五项开放决策均按建议值执行：静音时段 22:00–08:00 默认开 ✅ / 上限 8 次/小时 ✅ / 启动钟默认关 ✅ / 状态项默认开 ✅ / HourlyBaseline 共用数学 ✅。另录 r6 边界决策：GLM Coding Plan 不做套餐登记，用量以 token 形态提醒（`c8a0c35`）。

---

## 0a. 交付顺序与依赖

```
WI-1 BurnRateEngine ──┬── WI-2 消费事件载荷化 ── WI-3 CoinSound 改造
                      └── WI-6 菜单栏燃烧状态（P1）
WI-4 设置组（并行，无依赖）
WI-5 归因（P1，独立支线）
WI-7 收盘钟（P1，依赖 WI-2/WI-4）
WI-8 零配置启动重构（P1，独立支线）
```

- **P0 = WI-1 → WI-2 → WI-3 + WI-4**（燃烧闭环，声音只对消费事件响）
- **P1 = WI-5 + WI-6 + WI-7 + WI-8**（归因兜底、状态外显、日终收盘、零配置启动）
- P2/P3（Dock 环色、watchOS 触觉、声音包扩充、App Store 文案）不在本文范围。

---

## 1. 现状摘要（已核实的代码事实）

这些事实决定了实施方式，也是 §11.3 触及面估算的依据：

| # | 事实 | 位置 |
|---|---|---|
| F1 | 事件推送管道已存在：`notifyPhaseIngest()`（usage_event 插入后）/ `notifyPhaseGitScan()` / `notifyPhaseBalance()` → 500ms 防抖（`minNotifyInterval` 3s）→ `notifyConsumers(playSound:)` | `DataRefreshCoordinator.swift:229-296` |
| F2 | 当前声音语义 = "今日徽标文案变化"：格式化今日花费与 `lastSoundBadgeLabel` 对比后才响 | `DataRefreshCoordinator.swift:285-295` |
| F3 | B 级余额路径**绕过** coordinator 直接出声：`CoinSound.play(for: spend)`（余额差值检测后主线程直调） | `ApiPoller.swift:241-256` |
| F4 | 启动钟：`playForDataChange(bypassThrottle: true)` | `AIPulseApp.swift:91` |
| F5 | 熄屏即静默：`screensDidSleep/Wake` 挂起/恢复全部定时器 | `DataRefreshCoordinator.swift:81-93` |
| F6 | 合成事件排除惯例：`model IS NULL OR model != '<synthetic>'`，全仓 8 处一致 | `AnomalyDetector.swift:27` 等 |
| F7 | 迁移机制：`addColumnIfMissing(table, col, type)` + UserDefaults 一次性键回填 | `Database.swift:31-64` |
| F8 | A 级入库：`insertEvents` 批量事务，逐行完成 CostSource 仲裁（`Arbitrator.resolve`）+ token 计价，**此处置已知每行 cost/tokens** | `LogWatcher.swift:720-750` |
| F9 | 小时聚合查询范式可直接复用 | `AnomalyDetector.swift:20-32` |
| F10 | **App 无菜单栏状态项**：`MenuBarController` 构建的是 Dock 右键菜单 | `AIPulseApp.swift:51-53,245-253` |
| F11 | 声音播放用 `NSSound`（无音量控制）；多实例存活用 `activeSounds` 集合管理 | `CoinSound.swift:60-81` |
| F12 | 设置模式：UserDefaults 键 + `I18n.t()` 中英键（`Localizable.xcstrings`）；声音当前仅一个总开关 `coin_sound_enabled` | `SettingsView.swift:326-336` |
| F13 | 测试约定：`Tests/XxxTests.swift` 扁平目录，163 用例全绿 | `Tests/` |
| F14 | `EditorDetector` 已接线（`IntegrationRegistry`/`DashboardView` 在用），能以 workspace storage.json → repo 出 `Mapping(certain)` | `EditorDetector.swift:9-52` |
| F15 | 首启自动启用检测到的集成已是现状（零确认的地基已存在） | `AIPulseApp.swift:56` |

---

## WI-1 `BurnRateEngine`（新模块 · P0 核心）

**文件**：`Sources/Engine/BurnRateEngine.swift`（新增）；`Sources/Engine/HourlyBaseline.swift`（抽取共用数学）。

**API 草案**：

```swift
struct BurnRateSnapshot {
    let usdPerHour: Double?              // 钱形态（A+B 级事件）；nil = 该窗口无钱数据
    let tokensPerHour: Double?           // token 形态（A 级事件）
    var attributedLinesPerHour: Double?  // P1 WI-5 之后接入；P0 恒 nil
    let confidence: CostConfidence       // 取参与求和的最弱档
    let tier: BurnTier                   // cold / normal / hot / blaze（视觉+声音共用）
    let asOf: Date
}

enum BurnTier { case cold, normal, hot, blaze   // 阈值见下 }
```

**计算口径**（全部走既有聚合，零新表、零新定时器）：

1. **滚动窗口**：`ts >= now - 3600_000` 的 `usage_event`，排除 `<synthetic>`（F6 惯例）；
   `usdPerHour = SUM(cost_usd)`，`tokensPerHour = SUM(in+out+cache)`。
2. **窗口退化**：滚动窗为空时退回"今日 00:00 起活跃小时均值"，避免清晨恒 cold 的假象；再空则返回 nil（诚实静默）。
3. **基线**：前 7 个自然日同时段（小时桶）均值——数学与 `AnomalyDetector`（F9）同源，抽为 `HourlyBaseline` 共用，**AnomalyDetector 改为调用它**（行为不变，消除口径漂移）。
4. **分层**：`ratio = rate / baseline`；`<0.5 cold · 0.5–1.5 normal · 1.5–3 hot · >3 blaze`；无基线时 `normal`。
5. **缓存**：内存快照 TTL 30s；订阅 `.dataDidChange` 失效。**不新增任何 Timer**（§9.5 红线）。

**前置核对（开工第一步）**：确认 B 级余额差值进入 `usage_event` 的确切落库路径与字段（`CostBackfill` / `ApiPoller` 写入侧），以 FI-1 查证结论为准写入本节——防止"钱形态"漏统计。

**验收**：`BurnRateEngineTests`（窗口数学、退化链、tier 阈值、TTL 失效）；`AnomalyDetector` 行为回归不变。
**预估**：~250 行 + 测试。

---

## WI-2 消费事件载荷化（P0）

**目标**：把 F1 管道里的 `playSound: Bool` 升级为携带消费载荷，声音语义从"徽标变了"（F2）改为"花了钱/烧了 token"。

**改动**：

1. **新类型** `ConsumptionEvent`（放 `DataRefreshCoordinator.swift` 内）：
   `struct ConsumptionEvent { let spendUSD: Double?; let tokens: Int?; let source: String }`
2. **`LogWatcher.insertEvents`**（F8）：批量插入后把本次新增行汇总为 `(spend, tokens)` 随 `notifyPhaseIngest(_ event: ConsumptionEvent?)` 上报——数据已在手，只是传出去。
3. **`ApiPoller.cacheBalance`**（F3）：**移除直调 `CoinSound.play(for:)`**，改为向 coordinator 上报 `ConsumptionEvent(spendUSD: delta, ...)`。这是全局节流/勿扰生效的前提——B 级不能再绕过总线。
4. **`notifyConsumers`**（F2）：防抖窗口（500ms）内聚合多个事件 → 调 `CoinSound.play(events:)`；**删除 `lastSoundBadgeLabel` 徽标对比逻辑**（语义被取代）。`.dataDidChange` 通知本身不动。
5. **启动钟**（F4）：移除 `bypassThrottle` 启动钟；如需"活着的反馈"，改为 WI-4 中默认关闭的 `startup_chime_enabled`。

**验收**：`DataRefreshCoordinatorTests` 扩展——载荷聚合、B 级路径走总线、启动无声。
**预估**：~80 行改动，净删约 30 行。

---

## WI-3 `CoinSound` 改造（P0）

**目标**：从"数据音效"到"金钱心跳"（§3.2），三原则硬约束落地。

**改动**：

1. **播放器**：`NSSound` → `AVAudioPlayer`（F11，NSSound 无音量控制）。保留现有 `activeSounds` 存活管理思路；`AVAudioPlayer` 播放中自带持有，结束后置 nil。沙盒内读 bundle 资源无新权限。
2. **决策抽为纯函数**（可单测）：

```swift
enum SoundDecision { case none, coin, coinDouble, coinRain, chime }
static func decide(events: [ConsumptionEvent],
                   rate: BurnRateSnapshot?,
                   settings: SoundSettings,
                   now: Date,
                   recentPlayTimes: [Date]) -> SoundDecision
```

3. **防烦三原则的参数**（默认值，均可设置）：
   - **合并窗**：90s 内多事件合并为一次发声（金额/_token 累加参与分级）；
   - **绝对上限**：8 次/小时（`sound_max_per_hour`），滑动窗口检查 `recentPlayTimes`；
   - **勿扰**：静音时段默认 **22:00–08:00 开启**（`sound_quiet_*` 键组）；熄屏沿用 F5（播放前查 `CGDisplayIsAsleep` 双保险）。
4. **强度映射**：事件金额分级保留（≥$1 → `coinRain`，≥$0.1 → `coinDouble`，小额 → `coin`）；`rate.tier ∈ {hot, blaze}` 时合并窗缩短至 45s / 30s。
5. **声音包**：`Resources/Sounds/<pack>/coin.mp3 · coins.mp3 · chime.mp3`；`sound_pack` 键；解析顺序 = 所选包 → `default` 包 → `NSSound.beep()` 兜底。首批只交付 `default`（现有两个 mp3 迁入），其余包 P2。

**验收**：`CoinSoundDecisionTests` 纯函数全覆盖（勿扰/节流/分级/包回退）；人工听感清单进 PR 描述。
**预估**：~180 行改动。

---

## WI-4 设置组「感知」（P0，与 WI-2/3 并行）

**键位表**（`UserDefaults`，沿用 F12 模式）：

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `coin_sound_enabled` | Bool | false | **保留现有键**，语义升级为总开关 |
| `sound_pack` | String | "default" | 声音包 |
| `sound_volume` | Int (0–100) | 50 | 独立音量（WI-3 AVAudioPlayer） |
| `sound_quiet_enabled` | Bool | true | 静音时段总开关 |
| `sound_quiet_from` / `sound_quiet_to` | String "HH:mm" | "22:00" / "08:00" | 支持跨午夜 |
| `sound_max_per_hour` | Int | 8 | 绝对上限 |
| `startup_chime_enabled` | Bool | false | 启动钟（取代 bypassThrottle 语义） |
| `closing_bell_enabled` | Bool | true | 日终收盘（WI-7） |

**UI**：`SettingsView` 现有"金币音效"单行（F12）扩展为"感知"分组：总开关 / 声音包 Picker / 音量 Slider（即时试听）/ 静音时段 / 上限 Stepper / 收盘钟。**I18n 键**（中英双语进 `Localizable.xcstrings`）：`perception.group`、`perception.sound_pack`、`perception.volume`、`perception.quiet_hours`、`perception.max_per_hour`、`perception.closing_bell`、`perception.startup_chime`。

**验收**：开关即时生效；静音时段跨午夜正确；旧安装 `coin_sound_enabled=true` 用户无感迁移。
**预估**：~120 行 + i18n。

---

## WI-5 归因兜底（P1）

按设计文档 §4.6，三个信号分两步落地（第三信号"工具本地历史"随 §4.5 盘点结论再定）：

1. **DB**（F7 机制）：`addColumnIfMissing("code_change", "attributed_tool", "TEXT")` + `addColumnIfMissing("code_change", "attribution", "TEXT")`。列可空、无回填——历史代码变更的会话时序不可考，**只对新数据打标**。
2. **信号一（强）**：`GitMonitor` 现有 `git show` 调用加 `%b`（commit body）解析 `Co-Authored-By: .*<tool>` / `Generated-with: <tool>` trailer → `attribution = "exact"`。
3. **信号二（中）**：`GitMonitor.insertChange` 写入时，比对 `EditorDetector.detect()` 会话缓存（TTL 60s，`Mapping.repoPath` 匹配）→ `attributed_tool = mapping.toolName`，`attribution = "uncertain"`。
4. **铁律**：两信号皆空 → 不打标，该行走既有对照层路径（行为与今天完全一致）。

**验收**：`GitMonitorTests` 扩展（trailer 解析、会话匹配、无信号不打标）；`BurnRateSnapshot.attributedLinesPerHour` 接通（仅 `attribution IS NOT NULL` 行进速率）。
**预估**：~140 行 + 测试。

---

## WI-6 菜单栏燃烧状态（P1）

**现状更正**（F10）：App 目前**没有**菜单栏状态项，这是新增表面，不是改造。

1. **新增 `StatusItemController`**（`Sources/UI/MenuBar/`）：`NSStatusBar.system().statusItem(withLength:)`，button 用模板图 `flame.fill`（SF Symbols），着色三档映射 `BurnTier`：cold=次要灰 / normal=金 / hot+blaze=橙红；title 保留今日金额数字。
2. **菜单**：复用 `MenuBarController.statsMenuItems()` 产出，**首行插入**：燃烧率（`~$3.2/h`，`estimated` 加 `~` 前缀）+ 今日总账 + 打开仪表盘/设置。
3. **刷新**：`.dataDidChange` 观察（既有模式）+ 快照 TTL 过期惰性刷新。
4. **开关**：`status_item_enabled`（默认 true）；App Store 截图素材依赖此表面。

**验收**：三档图标随燃烧率切换；`~` 置信度标注；关闭开关后完全移除状态项。
**预估**：~180 行（新文件）+ `MenuBarController` 首行插入 ~30 行。

---

## WI-7 收盘钟（P1）

1. **触发**：**不加新定时器**——挂在 coordinator Phase 1（30s tick）内惰性检查：`now >= 当日收盘时刻 && 今日未播 && objectiveSpend(today) > 0`。收盘时刻默认 21:30（`closing_bell_time`）。
2. **动作**：本地通知（`SystemNotifications`，文案 i18n：`closing_bell.title/body`，含今日总额 + 峰值小时）+ 可选 `chime` 音（受勿扰与静音时段约束，但**收盘钟豁免绝对上限**——每天最多一次）。
3. **状态**：`closing_bell_last_fired` 存日期字符串。

**验收**：同日不重复；花费为零的日期不响；静音时段内静默（通知照发、无音）。
**预估**：~90 行。

---

## WI-8 零配置启动重构（P1，独立支线）

按产品设计 §4.7：**以"检测"代替"登记"**。目标——安装 → 授权主目录 → 看到第一个数字。

1. **套餐价目录**：新增 `Resources/plans-catalog.json`（与 `pricing-catalog.json` 同模式，纯本地数据）：

```json
{ "cursor":  [ { "tier": "Pro",       "monthlyFee": 20.0, "currency": "USD" } ],
  "copilot": [ { "tier": "Pro",       "monthlyFee": 10.0, "currency": "USD" },
               { "tier": "Business",  "monthlyFee": 19.0, "currency": "USD", "perSeat": true } ] }
```

2. **C 级预填**：`SubscriptionRegistry.detect()` 命中已安装工具 → 从目录取首个档位写入默认订阅行（`amortized` 置信度不变）；用户可在设置中改档/改价/清空。**月费路径不变**：只进总账与对照层，不进燃烧率。
3. **引导坍缩**：`OnboardingView`（333 行）四步 → 三步：`欢迎+检测结果` / `主目录授权` / `完成`。**移除**"AI 服务商填 Key"与"选择套餐"步骤；检测即启用沿用 F15 既有机制。
4. **设置重构**：`SettingsView` 的「AI 服务商」（Key 输入）与「开发工具」（套餐选择）两页移入新增的**「增强（可选）」折叠组**，默认收起；组内文案明确"不填也能完整使用"。套餐行改为"目录预填 + 可编辑"。
5. **仪表盘配套**：环形图订阅切片标签改为"已登记订阅"（`amortized` 角标）；目录预填后默认有值，用户清空则该切片如实消失。
6. **盲区诚实化**：纯 API 直连用户（无任何编码工具日志）在完成页与设置增强组内显式提示："你的用法没有本地日志，添加 API Key 才能计量"。

**验收**：全新安装零输入完成引导且首屏有真实数字；预填价可改可清空且总账随之变化；移除 Key 后 App 功能完整（B 级静默降级）；163 既有用例中涉引导/设置者同步更新。
**预估**：净简化为主——`OnboardingView` 删减 ~120 行、设置移动 ~80 行、目录加载与预填 ~100 行、catalog 文件 1 份。

---

## 2. 测试与质量计划

| 层 | 内容 |
|---|---|
| 单元 | `BurnRateEngineTests`（窗口/退化/tier）、`HourlyBaselineTests`（与 AnomalyDetector 旧值对齐）、`CoinSoundDecisionTests`（纯函数全分支）、`GitMonitorTests` 扩展（归因）、`DataRefreshCoordinatorTests` 扩展（载荷/总线/启动无声）、`PlansCatalogTests`（目录解析/预填/清空） |
| 回归 | 163 个既有用例零改动通过（§11.5 承诺）；`AnomalyDetector` 改用 `HourlyBaseline` 后行为逐值对齐 |
| 人工 | 听感清单：合并窗手感、上限是否够"心跳"、勿扰跨午夜；状态项三档视觉；`~` 标注出现条件 |
| 性能 | 燃烧率查询走既有索引（`ts` 已有索引，`Database.swift:129`）；熄屏挂起沿用 F5 |

## 3. 明确不做（P0/P1 边界外）

CloudKit/DashboardSnapshot 字段变更与 iOS/watchOS 燃烧 UI（P2）；Dock 环色（P2）；声音包 ≥2（P2）；App Store/README 文案切换（P3）；`playForDataChange` 之外的任何 API 兼容层。

## 4. 开放决策（开工前拍板）

1. **静音时段默认值**：本文建议 22:00–08:00 默认开启——对"心跳"定位偏保守，可辩。
2. **绝对上限默认 8 次/小时**：偏低防烦、偏高保感知，建议先 8 听一周。
3. **启动钟**：默认关（本文建议）还是保留旧行为？
4. **状态项默认开**：新表面默认常驻（本文建议 true），还是跟随 `coin_sound_enabled`？
5. **`hourly baseline` 抽取**：AnomalyDetector 改共用数学（本文建议）还是各自实现避免触碰告警路径？

## 5. 工作量与验收总览（对齐产品设计 §7）

| WI | 阶段 | 预估 | 硬验收 |
|---|---|---|---|
| WI-1 | P0 | ~250 行 | 声音/视觉消费同一个 `BurnRateSnapshot`；AnomalyDetector 回归不变 |
| WI-2 | P0 | ~80 行 | 声音只对消费事件响；B 级走总线；启动无声 |
| WI-3 | P0 | ~180 行 | 节流上限兜住密集消费；勿扰静默；包回退链 |
| WI-4 | P0 | ~120 行 | 旧用户无感迁移；键位全部生效 |
| WI-5 | P1 | ~140 行 | 盲区工具开始产生归因燃烧数据（或明确盲区） |
| WI-6 | P1 | ~210 行 | 不开仪表盘可答"烧多快"；`~` 标注 |
| WI-7 | P1 | ~90 行 | 日终一次；零花费日静默 |
| WI-8 | P1 | 净简化（删 ~200 / 增 ~100） | 零输入完成引导且首屏有真实数字；无 Key 功能完整 |
| **合计** | | **~1,100 行**（其中新代码约 800） | P0 闭环 ≈ 2–3 个工作日 / P1 ≈ 4–5 个工作日 |
