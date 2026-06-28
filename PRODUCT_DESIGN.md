# AI Pulse — 产品设计与实施方案

> 版本 v1.2 — 2026-06-28
> 定位：综合 `PLAN.md`（总体工程计划）与 `COST_ATTRIBUTION.md`（花费归因模型），收敛为一份**可靠、可实施**的产品形态与实施路线。
> **权威边界**：本文是上述两份文档的收敛版；**三者冲突时以本文为准**。术语映射——本文能力分级 **A/B/C** ≡ `PLAN.md` 数据层 **Tier A/B/C** ≡ `COST_ATTRIBUTION.md` 的 **L1/L2/L3**。

### 文档分工

| 文档 | 角色 | 在本文中的体现 |
|---|---|---|
| `PLAN.md` | 工程总计划、三层数据策略、隐私/分发/签名 | 背景与详尽工程口径，本文引用不重述 |
| `COST_ATTRIBUTION.md` | 花费归因模型、CPL 算法（L1-only） | 第 2 节能力分级与 CPL 口径即其收敛 |
| **本文** | 产品形态 + 集成架构 + 实施路线 | 唯一的可实施基线 |

> 注：`COST_ATTRIBUTION.md` 第 4 节仪表盘示意含"含订阅 CPL"双 CPL 行，**已被本文 6.1 的"单一精确 CPL + 独立卡片"布局取代**；其提出的 `subscription_attribution` 表由本文 7.1 `subscription_daily` 取代。

---

## 1. 产品本质：AI 油表

> **AI Pulse 是一只"AI 油表"——告诉用户在 AI 上消费了多少，并让这个数字在 Chrome 扩展、菜单栏、Dock 图标中持续、醒目地被感受到。**

在油表之上，叠加第二层价值：

> **针对 AI 编程这一垂直场景，提供"投入产出比"（CPL，单行成本）的观察窗。**

### 1.1 两层产品模型

| | 第一层：油表 | 第二层：CPL 观察窗 |
|---|---|---|
| 回答的问题 | "我在 AI 上烧了多少钱？" | "这些钱换来了多少代码？" |
| 展示位置 | 扩展弹窗、菜单栏、Dock 图标 | 仪表盘 Dashboard |
| 情绪目标 | 让花费"被感受到" | 让产出"被量化" |
| 适用人群 | 所有 AI 付费用户 | 用 AI 编程且使用可追踪工具的用户 |

### 1.2 关键洞察：数据门槛

| 目标 | 需要的数据 | 谁能满足 |
|---|---|---|
| 油表 | 只要"花了多少钱" | 几乎所有工具/服务商 |
| CPL | token + model + **cwd**（归因到 repo） | 只有写本地日志的工具 |

**覆盖率不全不会击穿产品**。一个只用 Cursor 的用户即便永远算不出 CPL，油表照样能显示花费并播动画——核心使命达成且诚实。覆盖率只影响第二层的可用范围。

---

## 2. 数据能力分级（A / B / C）

与 `COST_ATTRIBUTION.md` 的 L1/L2/L3 一一对应：

| 等级 | 数据来源 | 能产出 | 服务的层 |
|:--:|---|---|---|
| **A — 全量 CPL** | 本地 Agent 日志 | token + model + cwd → 成本 + repo + 净增行 | 油表 **和** CPL |
| **B — 仅花费** | 服务商余额/用量 API | 金额（无 repo、无行数） | **仅油表** |
| **C — 固定订阅** | 用户登记月费（IDE 安装侦测） | 月度固定成本 | **仅油表** |

### 2.1 铁律

1. **只有 A 级进 CPL**。B、C 级永远不进 CPL 分子。
2. **三档之间永远不求和**（同一笔花费可能同时出现在日志、余额、订阅里）。
3. B、C 级只喂油表层：驱动花费展示、预算告警、Dock 动画。
4. UI 自适应当前已启用的等级：无 A 级 → 隐藏 CPL，显示解锁引导。

### 2.2 CPL 口径（综合 `COST_ATTRIBUTION.md`）

> 仅用 A 级（L1）数据计算，分子分母同源、可按 repo 拆分，无重叠污染。

```
按 repo：repoCPL   = repoL1Cost / repoNetLines
全局：  globalCPL = totalL1Cost / totalNetLines
时间窗：默认本周（周一 00:00 → 周日 23:59）；菜单栏另给"今日"
```

- **分子（成本）**：A 级日志的 `Σ(in×inPrice + out×outPrice + cache×cachePrice)`，单价取自 `shared/pricing-catalog.json`（`PricingManager` 加载）；未知模型回退为不计 CPL，仅入油表花费。
- **分母（净增行）**：`GitMonitor` 按 commit `git show --numstat` 累加 `added - deleted`，并应用排除规则——**排除 lockfile / 生成代码 / `node_modules`、`dist`、`build` 等目录 / merge commit**（规则已在 `GitMonitor` 实现，详见 `PLAN.md` 行归因规则）。
- **计算位置**：`CostCalculator` 只读 L1 产出 CPL；`StatsService` 负责聚合与维度拆分（按 repo/model）。

---

## 3. 插件式集成架构

边界声明：**不提供公开插件市场，不支持第三方运行时加载**。"插件式"仅指内部编译期适配器结构。

### 3.1 两个小协议（而非一个大协议）

A/B/C 三级的数据流差异太大，用一个胖协议只能产出要么过薄要么处处 `fatalError`。拆成两个职责清晰的小协议，`grade` 直接挂在 `Detectable` 上（UI 据此渲染，无需再单独抽一个只含 `grade` 的空壳协议）：

```swift
// 所有工具都可被探测（零权限，只读）；grade 决定 UI 如何渲染
protocol Detectable {
    var id: String { get }
    var displayName: String { get }
    var grade: DataGrade { get }      // A / B / C
    func detect() -> DetectionResult
}

// A/B 级可以启停采集；C 级不实现（仅静态配置）
protocol Collectable: AnyObject {
    func start()
    func stop()
}

/// 完整集成 = 可探测 +（可选）可采集
typealias Integration = Detectable
```

- `Detectable`：欢迎页展示所有"发现的工具"，并通过 `grade` 决定渲染方式。
- `Collectable`：启用后启动采集器。A 级是 `LogWatcher`，B 级是 `ApiPoller` 对应 task；C 级不实现（仅静态配置，摊销在展示时即时计算）。

### 3.2 现有代码收编

| 现有实现 | 等级 | 实现 `Detectable` | 实现 `Collectable` |
|---|---|---|---|
| `ClaudeCodeParser` + `LogWatcher` | A | 检查 `~/.claude/projects` 是否存在 | 已有 `LogWatcher.start/stop` |
| `AiderParser` | A | 遍历仓库检查 `.aider.llm.history` | `LogWatcher` 已合入 |
| `ApiPoller` 内 4 个余额 provider | B | 检查是否已配置对应 Key | `ApiPoller` 已有 |
| `SubscriptionRegistry` 各工具 | C | 检查 IDE 是否安装 (bundleID) | 不需要采集（摊销在展示时即时算） |

> B 级当前覆盖 4 个支持余额/用量 API 的 provider（DeepSeek / OpenAI / Kimi / Zhipu）；扩展共 13 个内置 provider，其余仅做状态检查、不产生花费数据。API Key 当前存于 `UserDefaults`（`ApiKeyManager`），按 `PLAN.md` 隐私约束应迁移至 Keychain（后续硬化项）。

### 3.3 "新增一个工具"的成本

加 1 个 adapter 文件 + Registry 注册 + `detect()` 实现。UI 与统计自动适配其声明的等级。

---

## 4. 侦测 + 启用流程

```
侦测（只读） → 呈现"发现的工具" → 用户逐项启用 → 启用项才运行
```

1. **侦测器**（每个 Integration 自带 `detect()`）：全部只读，零权限。
2. **默认全部关闭**。侦测 ≠ 启用。
3. **逐项启用，按需请求**：
   - A 级 → 启用时展示隐私声明并开始本地读取（`~/.claude` 在用户目录下，非沙箱无需系统授权；此处的"同意"是知情同意的 UX 时刻，而非 OS 权限弹窗）。
   - B 级 → 引导填入 API Key（已有 API Keys 设置页）。
   - C 级 → 选择套餐（已有 Subscription 设置页）。
4. **C 级 `detect()` 只做 IDE 安装探测（bundleID）**，稳健且足够支撑欢迎页。编辑器↔repo 关联（`EditorDetector`，解析 `NSWorkspace.runningApplications` + workspace state）属脆弱件，是**独立的可选富集模块**，仅作辅助信号，后置到 P3+，不进 onboarding、不参与 CPL。

---

## 5. 安装后欢迎页（Onboarding）

```text
Step 0  欢迎 / 价值主张
        "AI Pulse 是你的 AI 油表。"

Step 1  侦测结果（自动扫描，只读）
        ┌─ 发现的工具 ─────────────────────────────────┐
        │ ✅ Claude Code   [A 级·可算 CPL]   〔启用〕    │
        │ ✅ Cursor        [C 级·仅记花费]   〔启用〕    │
        │ ✅ DeepSeek API  [B 级·余额追踪] 〔配置 Key〕 │
        │ ⚪️ aider         未发现日志                    │
        └───────────────────────────────────────────────┘

Step 2  逐项启用
        - A 级：启动日志监听（可在此时提示隐私声明"仅本地解析"）
        - B 级：填 API Key
        - C 级：选套餐

Step 3  （可选但建议）选择要监控的 Git 仓库
        自动扫描 ~/dev、~/projects 等，用户勾选；仅 A 级启用时需要。
        可在此步或设置中完成，合并到 Step 1 的"发现"中一并展示。

Step 4  完成
        "已就绪。菜单栏会持续显示今日花费；
         启用了 Claude Code 可在仪表盘查看单行成本。"
```

- 整页可跳过；可事后从设置页重做。
- 权限延迟到启用那一刻；欢迎页本身不申请任何权限。

---

## 6. 展示层设计

| 位置 | 展示内容 | 数据来源 |
|---|---|---|
| **菜单栏** | 今日/本周花费、净增行、CPL（有 A 级时） | StatsService 聚合 |
| **仪表盘 Dashboard** | CPL 观察窗 + 分层卡片（油表 / 余额 / 订阅各自独立、不求和） | 沿用 COST_ATTRIBUTION 第 4 节 |
| **Dock 图标** | **Demo 级别**：数字显示花费 + 超日均变色告警。金币动画后续 | 任意等级花费 |
| **Chrome 扩展** | 花费总览 + "升级 Mac 版解锁 CPL" 引导 | **Demo 级别**：`GET /api/v1/health` + `GET /api/v1/stats/today`，仅绑 `127.0.0.1` |

### 6.1 分层仪表盘（沿用 COST_ATTRIBUTION）

```
┌ Token 花费（精确 CPL，仅 A 级）─────────────────────┐
│  按 repo 拆分：ai-pulse 3200行 $18.20 $0.0057/行   │
└────────────────────────────────────────────────────┘
┌ 订阅月费（C 级，不参与 CPL）─────────────────────────┐
│  Cursor Pro    $20/月 · 日均 $0.67    ⚠️ 可能重叠     │
│  Copilot Pro   $10/月 · 日均 $0.33    ⚠️ credits 未计入│
└────────────────────────────────────────────────────┘
┌ API 余额（B 级，不参与 CPL）─────────────────────────┐
│  DeepSeek  ¥320    OpenAI  $2.50（3 日）             │
│  ⚠️ 余额变化可能包含 Token 花费中的数据                │
└────────────────────────────────────────────────────┘
```

### 6.2 CPL"提级"路径

1. 现在：Dashboard 内的一个区块。
2. 中期：菜单栏摘要常驻一行 CPL（已实现雏形）。
3. 远期：Dock / 菜单栏图标可切换为"CPL 模式"。

---

## 7. 数据模型

### 7.0 当前基线（与 `COST_ATTRIBUTION.md` 现状一致）

MVP 复用已落地的 3 张表，**P0–P2 不需要新增表**：

```sql
usage_event(id, ts, source, provider_id, model,
            in_tokens, out_tokens, cache_tokens,
            cost_usd, repo_path, session_id, dedupe_key UNIQUE)   -- A/B 级花费
code_change(id, commit_hash UNIQUE, ts, repo_path, added, deleted, is_merge)  -- 净增行
subscription_tool(id, name, monthly_fee, currency)               -- C 级配置
```

- `PLAN.md` 设想的 `correlation` / `repo` / `daily_rollup` 表**暂不实现**：cwd 直接归因已替代 correlation 表；聚合走即时查询（数据量到瓶颈再引入物化 `daily_rollup`）。
- 下列 7.1 / 7.2 两表均为 **P3+ 可选**，不在 MVP 主路径，且**取代** `COST_ATTRIBUTION.md` 早期提出的 `subscription_attribution` 表。

### 7.1 `subscription_daily`（C 级记账，可选 · P3+）

> ⚠️ 可选。MVP 的油表只需"今天/本周"，订阅摊销在展示时即时计算（月费 ÷ 当月天数），**无需建表、无需定时任务**。仅当要做"订阅历史趋势"时，才引入下表与 `SubscriptionAccountant`。

```sql
-- 每日摊销表（SubscriptionAccountant 写入）
CREATE TABLE subscription_daily (
    id      INTEGER PRIMARY KEY,
    date    TEXT NOT NULL,      -- "2026-06-28"
    tool    TEXT NOT NULL,      -- "Cursor"
    tier    TEXT NOT NULL,      -- "Pro"
    cost    REAL NOT NULL,      -- 日摊销额 = 月费 / 当月天数
    UNIQUE(date, tool)
);
```

`SubscriptionAccountant` 每天运行一次：对每个启用的 C 级工具，写入 `月费 / 当月天数`。同时写入总体 `subscription_cost` 供 StatService 聚合。

### 7.2 `editor_activity`（编辑器侦测，可选 · P3+）

> ⚠️ 可选富集。`EditorDetector` 解析各编辑器 workspace state 属脆弱件，不进 onboarding、不参与 CPL，后置到 P3+ 按需实现。

```sql
-- 编辑器与 repo 关联记录（EditorDetector 写入）
CREATE TABLE editor_activity (
    id           INTEGER PRIMARY KEY,
    ts           INTEGER NOT NULL,
    tool_name    TEXT NOT NULL,     -- "Cursor" / "VS Code"
    repo_path    TEXT NOT NULL,     -- 检测到关联的仓库
    confidence   TEXT NOT NULL      -- "workspace_match" / "running"
);
```

仅作辅助信号，不参与 CPL 计算。

---

## 8. 实施方案

| 阶段 | 内容 | 类型 |
|:---:|------|:---:|
| **P0** | 两协议（`Detectable`/`Collectable`）+ Registry + 现有代码收编 | 重构 |
| **P1** | 侦测层（`detect()` 仅 bundleID/日志存在性）+ 欢迎页 + 设置页补全 | 新功能 |
| **P2** | 展示自适应（Dashboard/菜单栏按等级渲染，CPL 仅 A 级） | 新功能 |
| **P3** | Dock 油表 Demo + 扩展桥接 Demo | 新功能 |
| **P3+** | （可选富集）`EditorDetector` 编辑器↔repo 关联 + `subscription_daily` 历史趋势 | 可选 |
| **P4** | 变现（Licensing） | 新功能 |

### P0 — 架构收口

- 定义 `Detectable` / `Collectable` 两协议（`grade` 留在 `Detectable`）。
- 创建 `IntegrationRegistry`（编译期注册，统一启停）。
- 收编现有代码：ClaudeCode/Aider → A 级 adapter；ApiPoller 各 provider → B 级 adapter；SubscriptionRegistry → C 级 adapter。
- C 级订阅摊销在展示时即时计算（月费 ÷ 当月天数），P0 不建表、不引入定时任务。
- 验收：现有功能行为不变；所有数据源经由 Registry 启停。

### P1 — 侦测层 + 欢迎页

- 为各 Integration 实现 `detect()`（只读）：A 级查日志是否存在、B 级查 Key 是否就绪、C 级仅查 IDE 是否安装（bundleID）。
- 新建 Onboarding 流程（四个 Step，可跳过，可重做）。
- 设置页复用侦测组件，补全"管理集成"页面。
- 验收：侦测零权限；全新安装完成欢迎页后可见首个真实数字。

### P2 — 展示自适应

- Dashboard / 菜单栏按已启用等级渲染：无 A 级隐藏 CPL 并显示解锁引导。
- B/C 级数据只进油表展示，不进 CPL。
- 验收：只装 C 级的用户可见花费与订阅摊销，CPL 区显示引导而非空白。

### P3 — Dock + 桥接 Demo

- Dock：`NSDockTile` 显示今日花费数字 + 超日均变色告警（Demo）。
- 桥接：`GET /api/v1/health` + `GET /api/v1/stats/today`，**仅绑 `127.0.0.1`、校验 `Origin`、`Access-Control-Allow-Origin` 限定扩展 id**（防 DNS rebinding，沿用 `PLAN.md` 安全约束）。
- 验收：扩展可读取 Mac 今日花费；非扩展 Origin 被拒。

### P3+ — 可选富集（按需，不在 MVP 主路径）

- `EditorDetector`：解析 `NSWorkspace.runningApplications` + workspace state，标注编辑器↔repo 关联；脆弱件，仅作辅助信号，不参与 CPL。
- `editor_activity` 表 + `subscription_daily` 表 + `SubscriptionAccountant`：仅当要做"订阅历史趋势/编辑器关联展示"时才引入。
- 验收：开启后不影响既有油表/CPL 口径；关闭或解析失败时静默降级，不报错、不空屏。

### P4 — 变现

- License Key 校验 + Keychain 试用计时（沿用 PLAN.md E5 修正）。

### 常态化接入（P0 之后长期适用）

新工具 = 1 个 adapter + Registry 注册 + `detect()` 实现。UI 与统计自动适配。

---

## 9. 约束与验收基线

- **隐私**：仅本地处理；只存聚合（token/行数/金额/repo 路径）；绝不上传代码/prompt/diff（详见 `PLAN.md` 隐私契约）。
- **权限最小化**：侦测零权限；权限延迟到启用时按需请求；默认全部关闭。
- **诚实展示**：三档永不求和；CPL 仅来自 A 级（口径见 2.2）；盲区显式标注（如"当前 CPL 未覆盖 Cursor/Copilot"）。
- **CPL 口径单一来源**：成本取 `pricing-catalog.json`、净增行按 commit 排除规则，二者均以 2.2 为准，禁止旁路计算。
- **桥接安全**：本机服务仅绑 `127.0.0.1`、校验 `Origin`、CORS 限定扩展 id。
- **密钥存储**：API Key 目标存 Keychain（当前 `UserDefaults`，列为硬化项）。
- **复杂度红线**：无公开插件市场、无运行时加载；协议仅为编译期结构。
- **性能**：闲置内存 < 80MB；日志增量解析单批 < 50ms；本地 API 响应 < 20ms。
