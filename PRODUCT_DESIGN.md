# AI Pulse — 产品设计与实施方案

> 版本 v1.3 — 2026-06-28
> 定位：综合 `PLAN.md`（总体工程计划）与 `COST_ATTRIBUTION.md`（花费归因模型），收敛为一份**可靠、可实施**的产品形态与实施路线。
> **权威边界**：本文是上述两份文档的收敛版；**三者冲突时以本文为准**。术语映射——本文能力分级 **A/B/C** ≡ `PLAN.md` 数据层 **Tier A/B/C** ≡ `COST_ATTRIBUTION.md` 的 **L1/L2/L3**。

### 文档分工

| 文档 | 角色 | 在本文中的体现 |
|---|---|---|
| `PLAN.md` | 工程总计划、三层数据策略、隐私/分发/签名 | 背景与详尽工程口径，本文引用不重述 |
| `COST_ATTRIBUTION.md` | 花费归因模型、CPL 算法（L1-only） | 第 2 节能力分级与 CPL 口径即其收敛 |
| **本文** | 产品形态 + 集成架构 + 实施路线 | 唯一的可实施基线 |

> 注（v1.3 重大调整）：**CPL 从"第二层头条"降级为"限定条件下的精确小窗"**；第二层主形态改为**花费图 + 代码变化图两张独立图表**（参照看、不合并、不相除，见 6.1）。`COST_ATTRIBUTION.md` 第 4 节的双 CPL 仪表盘与其 `subscription_attribution` 表均被本文取代。

---

## 1. 产品本质：AI 油表

> **AI Pulse 是一只"AI 油表"——告诉用户在 AI 上消费了多少，并让这个数字在 Chrome 扩展、菜单栏、Dock 图标中持续、醒目地被感受到。**

在油表之上，叠加第二层价值：

> **针对 AI 编程场景，把"花费"与"代码产出"诚实地并列呈现，让用户自行对照判断——而非用一个 CPL 比值去暗示二者成正比。**

### 1.1 两层产品模型

| | 第一层：油表 | 第二层：花费 ⋅ 产出 并列 |
|---|---|---|
| 回答的问题 | "我在 AI 上烧了多少钱？" | "这段时间花了多少、又改了多少代码？" |
| 展示形态 | 扩展弹窗、菜单栏、Dock 图标 | 仪表盘内**两张独立图表**：花费图 + 代码变化图（参照看、不合并） |
| 情绪目标 | 让花费"被感受到" | 让花费与产出**各自被看见**，并暴露二者的"背离" |
| 适用人群 | 所有 AI 付费用户 | 用 AI 编程的用户 |

> **CPL 不再是第二层的头条**。它被降级为一个**限定条件下才出现的精确小窗**（见 2.2 有效门）：只在"按量计费 + 有日志 + 单一编程用途"时显示，否则隐藏。

### 1.2 为什么"花费÷产出"不能当头条

1. **套餐下 token 无成本意义**：用 Claude/Cursor 套餐时，token 是固定费下的"免费额度"，拿 API 单价去乘得到的是**虚构成本**。
2. **固定成本使日粒度 CPL 失真**：开了多个套餐但当日产出少，CPL 会飙高，却不代表"效率低"。
3. **分母是坏代理**：调试一天净增几行、重构删掉几百行都是有价值的工作，却会把 CPL 推向虚高甚至负数。
4. **成本与产出无必然同调**：订阅成本恒定、API 成本跟"用量"走、而"用量 ≠ 产出"。**相除即是在制造一个不存在的比例关系。**

> 结论：真正可靠地反馈给用户的，是**某段时间的花费**（API + 订阅）与**代码增减量**这两个**直接观测量**，分两张图参照看。**覆盖率不全不会击穿产品**——只用 Cursor 的用户即便算不出 CPL，两张图照样成立。

---

## 2. 数据能力分级（A / B / C）

与 `COST_ATTRIBUTION.md` 的 L1/L2/L3 一一对应：

| 等级 | 数据来源 | 能产出 | 服务的层 |
|:--:|---|---|---|
| **A — 日志** | 本地 Agent 日志 | token + model + cwd → 成本 + repo + 增减行 | 油表 +（限定）CPL |
| **B — 余额** | 服务商余额/用量 API | 金额（无 repo、无行数） | **仅油表** |
| **C — 订阅** | 用户登记月费（IDE 安装侦测） | 月度固定成本 | **仅油表** |

### 2.1 铁律

1. **只有 A 级进 CPL**，且仅在 2.2 的有效门内；B、C 级永远不进 CPL 分子。
2. **三档之间永远不求和**（同一笔花费可能同时出现在日志、余额、订阅里）。
3. **套餐后端不出 token-CPL**：套餐下 token 无边际成本，只反映用量、不反映花费。
4. **花费与产出分两张图、不合并、不相除**（二者无必然同调）。
5. B、C 级只喂油表层：驱动花费展示、预算告警、Dock 动画。
6. UI 自适应：无有效 CPL → 隐藏 CPL 小窗，仅展示两张图。

### 2.2 CPL 口径与有效门（限定小窗）

**有效门——三条件全满足才显示 CPL，否则隐藏**：

1. **按量计费**：该工具后端是 per-token 计费的 API（套餐后端不算，token 无成本意义）。
2. **有日志**：能从日志拿到 `model` + token，按 `model → price` 定价（注意是 model 定价，不是工具品牌定价；"Claude Code 接 DeepSeek" 即按 DeepSeek 单价）。
3. **单一编程用途**：该 provider 的 key 未混用非编程任务（用户可在设置标记"混用/排除"）。

满足时按 repo 给出**精确 CPL**：

```
按 repo：repoCPL = repoL1Cost / repoNetLines
时间窗：默认本周（周一 00:00 → 周日 23:59）；菜单栏另给"今日"
```

- **分子**：A 级日志 `Σ(in×inPrice + out×outPrice + cache×cachePrice)`，单价取自 `shared/pricing-catalog.json`（`PricingManager`，按 `model` 查价）；未知模型 → 不计 CPL，仅入油表花费。
- **分母**：`GitMonitor` 按 commit `git show --numstat` 累加 `added - deleted`，排除 lockfile / 生成代码 / `node_modules`、`dist`、`build` / merge commit。**诚实命名为"每净增行成本"，不暗示"AI 生产力"**；调试/重构日会使其失真，故以**趋势**而非绝对值解读。
- **不做**：全局混合 CPL（套餐+按量相除）、套餐 token-CPL、跨 provider 求和。
- **计算位置**：`CostCalculator` 只读符合有效门的 L1 数据；`StatsService` 负责聚合。

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
        "已就绪。菜单栏持续显示今日花费；
         仪表盘可对照花费与代码变化两张图（满足条件时含精确 CPL）。"
```

- 整页可跳过；可事后从设置页重做。
- 权限延迟到启用那一刻；欢迎页本身不申请任何权限。

---

## 6. 展示层设计

| 位置 | 展示内容 | 数据来源 |
|---|---|---|
| **菜单栏** | 今日/本周花费、代码增减；CPL 仅在有效门内 | StatsService 聚合 |
| **仪表盘 Dashboard** | **两张独立图表**：花费图 + 代码变化图（参照看、不合并）；CPL 为限定小窗 | StatsService 聚合 |
| **Dock 图标** | **Demo 级别**：数字显示花费 + 超日均变色告警。金币动画后续 | 任意等级花费 |
| **Chrome 扩展** | 花费总览 + "升级 Mac 版" 引导 | **Demo 级别**：`GET /api/v1/health` + `GET /api/v1/stats/today`，仅绑 `127.0.0.1` |

### 6.1 仪表盘：两张独立图表（不合并）

花费与产出**没有必然同调**，因此分两张图、参照看，绝不画进同一坐标轴（同轴会暗示相关性）。

**图 1 — 花费图**（API 余额消耗 + 订阅均摊，按时间）

```
花费/日
  $ ┤        ▆        ▆
    ┤   ▆ ▅  █   ▅   █  ▅      ■ API 余额消耗（按 provider）
    ┤ ▅ █ █  █ ▅ █ ▅ █  █      ▨ 订阅均摊（月费 ÷ 当月天数）
    └────────────────────────  注：两类独立堆叠，不与产出相除
```

**图 2 — 代码变化图**（增 / 删 叠加柱形，按时间）

```
行/日
 +200 ┤    ███            ███
    0 ┼────███───────█████████──  ███ 新增（added）
 -100 ┤    ▒▒▒    ▒▒▒▒▒            ▒▒▒ 删除（deleted）
      └────────────────────────  增删都是工作量，分别显示而非只给净值
```

- 下方可并排辅助卡：**API 余额**（按 provider）、**订阅消耗**（按工具，⚠️ 标注可能与 API 重叠）、以及**满足有效门时**的精确 CPL（按 repo）。
- 卡片之间**永不求和**，沿用 `COST_ATTRIBUTION.md` 诚实原则。

### 6.2 CPL 的定位：保持小窗，不提级

CPL 只在有效门内、作为按 repo 的精确小窗存在，**不**升级到菜单栏头条或 Dock。产品的醒目位永远留给油表（花费）与代码变化两张图。

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
- **诚实展示**：三档永不求和；**花费与产出分两张图、不相除**；套餐不出 token-CPL；CPL 仅在 2.2 有效门内；盲区显式标注。
- **CPL 口径单一来源**：成本取 `pricing-catalog.json`、净增行按 commit 排除规则，二者均以 2.2 为准，禁止旁路计算。
- **桥接安全**：本机服务仅绑 `127.0.0.1`、校验 `Origin`、CORS 限定扩展 id。
- **密钥存储**：API Key 目标存 Keychain（当前 `UserDefaults`，列为硬化项）。
- **复杂度红线**：无公开插件市场、无运行时加载；协议仅为编译期结构。
- **性能**：闲置内存 < 80MB；日志增量解析单批 < 50ms；本地 API 响应 < 20ms。
