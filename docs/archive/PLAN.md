# AI Pulse Mac App — 产品设计与开发计划

> 文档版本：v2（2026-06-26 修订）
> 修订重点：在原计划基础上，重构数据采集策略（日志优先）、补齐数据模型与定价口径、明确 NetworkExtension 权限/分发风险、修正买断/试用机制、统一与扩展的桥接协议、补充里程碑与验收标准。

## 方案评估结论（针对原计划）

原计划的产品定位（垂直化、漏斗、单行成本）与商业判断是成立的，差异化清晰、与现有扩展形成互补。但作为"完整的开发计划与技术方案"，原计划存在若干**工程落地风险与口径缺口**，本次修订逐一补齐：

| # | 原计划问题 | 风险等级 | 本次处理 |
|---|-----------|---------|---------|
| E1 | **以透明代理为 MVP 主数据源** —— `NETransparentProxyProvider` 需 System Extension + NetworkExtension entitlement，受 Apple 特批与沙箱限制，且无法解密内容（拿不到 token/模型），MVP 风险过高 | 🔴 高 | 重构为「日志优先」三层数据策略，代理降级为 Phase 3 可选增强（见 [数据采集策略](#数据采集策略核心重构)） |
| E2 | **单行成本缺少定价表** —— 有了 token 也算不出钱，扩展里没有 model→price 映射 | 🔴 高 | 新增共享定价 catalog 与成本计算口径（见 [成本计算口径](#成本计算口径与行归因)） |
| E3 | **净增行数口径模糊** —— 工作区 diff 会重复计数、未排除 lockfile/生成代码 | 🟡 中 | 明确「按 commit 归因 + 排除规则」（见 [行归因规则](#行归因规则)） |
| E4 | **关联引擎依赖 30s 时间窗** —— 准确度仅 ~80%，且并非每次 AI 调用都产出代码 | 🟡 中 | 日志数据源自带 cwd，可直接归因到仓库，时间窗降为兜底 |
| E5 | **买断与 7 天试用机制冲突** —— `isEligibleForIntroOffer` 属 StoreKit 订阅 API，买断不适用 | 🟡 中 | 明确「买断 = License Key + 本地试用计时」（见 [付费模式](#付费模式)） |
| E6 | **MAS 沙箱与功能冲突** —— 沙箱禁止扫描任意用户目录、读容器外日志，与核心功能矛盾 | 🟡 中 | v1 走 Developer ID 直分发 + Sparkle 自更新（见 [分发与权限](#分发权限与签名)） |
| E7 | **provider 数量与桥接协议不一致** —— 文档写 18 个（实际 13 个内置），bridge 路径前后不一（`/stats` vs `/api/stats`） | 🟢 低 | 与扩展共享 provider catalog，桥接统一为 `/api/v1/*`（见 [与扩展协同](#与-chrome-扩展的关系)） |
| E8 | **缺数据模型、测试/CI、签名公证、里程碑验收** | 🟡 中 | 补 SQLite schema、测试策略、签名公证流水线、里程碑验收标准 |
| E9 | **隐私面未定义** —— 应用会读源码 diff 与含 prompt 的日志 | 🔴 高 | 新增隐私与安全契约：仅本地处理、只存聚合计数、绝不上传代码/prompt（见 [隐私与安全](#隐私与安全)） |

**一句话结论**：方向正确，但需把"主数据源"从透明代理切换到"本地 Agent 日志解析 + 服务商用量 API 轮询"，并补齐定价、数据模型、隐私、分发与里程碑，方案才完整可落地。

## 产品定位

Chrome 扩展（免费）做通用 AI 余额监控，Mac 应用（付费）做编程场景的深度统计——核心差异化功能是 **AI 编程单行成本**。

## 垂直化定位：以开发者为核心

### 为什么聚焦开发者

AI 编程工具（Copilot、Cursor、Claude Code）已经彻底改变了编程。门槛降低意味着**会编程的人更多了**——从职业软件工程师扩展到设计师、产品经理、数据科学家、学生。

这个群体有几个特征：
1. **增长快**——GitHub Copilot 仅个人用户就超过 180 万，Cursor 估值 40 亿美元
2. **付费意愿高**——开发者习惯为工具付费（Setapp、JetBrains、Apple Developer）
3. **需求明确**——"我花了 $20 调用 API，但产出是多少？" 是每个用 AI 编程的人的真问题
4. **容易触达**——开发者聚集于 Twitter/X、Reddit、Hacker News、Product Hunt

### 双层产品矩阵

| | Chrome 扩展 | Mac 应用 |
|---|-----------|---------|
| **目标用户** | 所有人（通用监控） | 用 AI 编程的开发者 |
| **核心功能** | 余额查询、状态监控 | 单行成本、按项目统计、Dock 动画 |
| **商业模式** | 免费（引流） | 付费 $9.99（变现） |
| **价值主张** | 省得手动去 16 个网站查余额 | 知道 AI 编程的钱花在哪、值不值 |

**关系不是替代，是漏斗**：

```
所有 AI 用户
  │
  ├─ 80% 只需要查余额 → Chrome 扩展（免费、够用）
  │
  └─ 20% 用 AI 编程 → 扩展发现 → 升级 Mac 应用（付费）
       │
       └─ 这群人贡献 100% 的收入，因为他们有最深的痛点
```

**非程序员功能保留但降优先级**：
- Chrome 扩展继续做通用余额/状态监控（不会砍掉、不会变弱）
- Mac 应用也保留通用余额查询（毕竟是 AI 工具，不是纯编程工具）
- 但 Mac 应用的**差异化和卖点全部围绕编程场景**

### 竞争分析

目前的 AI 监控工具都在做"花了多少钱"——全员通用。

| 产品 | 做什么 | 不做 |
|------|--------|------|
| OpenAI Dashboard | 看 OpenAI 账单 | 不看其他服务商 |
| Helicone | API 调用日志和成本 | 不关联代码产出 |
| AI Pulse 扩展 | 多服务商余额监控 | 不统计产出效率 |
| **AI Pulse Mac** | **花费 vs 代码产出的效率** | **不试图替代通用监控** |

垂直化的优势：所有人都在做"输入"（花了多少），没人做"输出"（产出了什么）。AI Pulse Mac 是第一个回答"值不值"的工具。

## 产品设计理念

### 为什么需要 Mac 应用

Chrome 扩展受限沙箱，无法访问文件系统和非 Chrome 进程。Mac 应用天然拥有系统级能力——文件监听、网络代理、Dock 交互、菜单栏、小组件。编程场景的痛点（AI 花了钱但不知道产出多少代码）只有桌面应用能解决。

### 核心指标：单行成本

**定义**: `AI 调用花费 / 净增代码行数`

- 分子：所有 AI API 调用的累积费用（USD/CNY）
- 分母：git diff 中 **净增行数**（新增行 - 删除行）。删除行是思考过程、不是产出，不计入。

**为什么这个指标重要**:
- 把抽象的"用了多少 AI"变成具体的"每行花了多少钱"
- 让开发者直观对比不同 AI 工具的性价比
- 可跨项目、跨时间段比较——"这个月比上个月效率提高了 20%"
- 自然引导用户关注价值而非消耗——"我花了 $5，但写了 200 行，值了"

### 用户路径：从扩展到 Mac 应用

```
发现 → 试用扩展（免费）→ 觉得好用 → 扩展底部看到"单行成本"功能
  → 好奇 → 下载 Mac 应用 → 7 天试用 → 付费
```

扩展的"引流"价值在于:
1. 降低首次接触门槛（免费、一键安装、Chrome 商店可见）
2. 建立数据积累习惯（用户配置好 API Key 后天天用）
3. 自然暴露扩展无法做到的事情（没法统计 VS Code 的花费、不知道每行成本）

## 数据采集策略（核心重构）

> 这是相对原计划最重要的修正。原计划把透明代理当主数据源，但代理**无法解密内容**——拿不到 token 数、模型名、归属仓库。要算"单行成本"，必须知道「花了多少钱（精确 token × 单价）」和「产出多少行（归属到哪个仓库）」，透明代理两者都做不到。

采用三层数据源，按"精确度优先、零权限优先"排序，能用高层就不用低层：

### Tier A — 本地 Agent 日志解析（MVP 主数据源）

主流 AI 编程工具会在本地写下**带 token 用量和模型名**的会话日志，且日志路径天然包含工作目录（cwd），可直接把花费归属到具体仓库——无需时间窗猜测，也无需任何系统权限。

| 工具 | 日志位置（典型） | 可得字段 | 备注 |
|------|----------------|---------|------|
| Claude Code | `~/.claude/projects/<encoded-cwd>/*.jsonl` | input/output/cache tokens、model、cwd、时间戳 | 字段最完整，首选接入 |
| aider | 仓库内 `.aider.chat.history.md` / `.aider.llm.history` | model、token、cost、所在仓库 | aider 自带 cost，可直接采用 |
| Codex CLI / 类 CLI Agent | `~/.codex/` 等会话目录 | 视实现而定 | 适配器模式逐个接入 |
| Cursor / VS Code Copilot | 应用内 DB / 无本地用量日志 | 受限 | 详见下方"订阅制工具"特殊处理 |

实现要点：
- **FSEvents 监听日志目录**（复用原计划的 FSEvents 思路），增量解析新增的 JSONL 行，避免全量重读。
- **Parser 适配器接口**：每个工具一个 `UsageLogParser`，输出统一的 `UsageEvent { timestamp, model, inputTokens, outputTokens, cachedTokens, repoPath, source }`。新增工具只需加一个适配器。
- **去重**：以 (source, sessionId, lineHash) 去重，防止日志轮转/重放重复计费。
- **归属**：日志中的 cwd → 命中已发现仓库 → 直接归属，跳过时间窗关联。

### Tier B — 服务商用量 / 余额 API 轮询（精确金额校准）

复用扩展已有的 provider 体系（`fetchBalance` / OpenAI `/v1/usage` 等），定时轮询拿到**官方口径的精确花费/余额**，用于：
- 校准 Tier A 的估算（token×单价 vs 官方账单），消除定价表误差；
- 覆盖没有本地日志的纯 API 调用（如脚本直连）；
- 与扩展共享同一份 provider catalog 和 API Key（见 [与扩展协同](#与-chrome-扩展的关系)）。

### Tier C — 透明代理（可选增强，降级到 Phase 3）

`NETransparentProxyProvider` 仅作为"补全 Tier A/B 盲区"的可选项：统计**元数据**（域名、请求数、响应大小、频率），用于发现"有调用但无日志"的工具。明确其局限与高权限成本（见 [关键技术选型](#关键技术选型)），**不作为 MVP 必需项**。

### 订阅制工具的单行成本（摊销模型）

Copilot、Cursor Pro 等是**固定月费**，没有 per-call token 计费。对这类工具，"单行成本"用摊销口径：

```
订阅工具单行成本 = 当月订阅费 / 当月该工具辅助下的净增行数
```

- 用户在设置中登记订阅项（名称、月费、币种）。
- 净增行数仍由 Git 监听得到；归属到订阅工具可用"活跃编辑器/进程提示"或用户手动指定主力工具。
- 这反而是强卖点：让用户看到"Cursor Pro 这个月帮我写了 4200 行，折合 $0.005/行，比按量 API 便宜"。

## 成本计算口径与行归因

### 成本计算口径

```
精确成本（Tier A） = Σ ( inputTokens×inPrice + outputTokens×outPrice + cachedTokens×cachePrice )
官方成本（Tier B） = 轮询用量 API / 余额差值（现有 spend-checker 口径）
最终成本 = 有官方口径时以 Tier B 为准，否则用 Tier A 估算；差异>10% 时在 UI 标注"估算"
```

需要一张共享 **定价 catalog**（model → 每百万 token 的 input/output/cache 单价 + 币种），随模型迭代更新：

```jsonc
// shared/pricing-catalog.json（扩展与 Mac 应用共用）
{
  "anthropic/claude-sonnet-4": { "in": 3.0, "out": 15.0, "cache": 0.3, "unit": "USD/Mtok" },
  "openai/gpt-4o":            { "in": 2.5, "out": 10.0, "cache": 1.25, "unit": "USD/Mtok" },
  "deepseek/deepseek-chat":   { "in": 0.27, "out": 1.1, "cache": 0.07, "unit": "USD/Mtok" }
  // …随发布更新；未知模型回退到"按余额差值"口径
}
```

### 行归因规则

净增行数 = `新增行 - 删除行`，但必须明确口径，否则会被 churn 污染：

1. **按 commit 归因，不按工作区实时 diff**——避免来回改动重复计数。监听 `.git/objects` 触发后，对**新出现的 commit** 跑 `git show --numstat <sha>` 累加 `added - deleted`。
2. **排除非产出文件**：lockfile（`*.lock`、`package-lock.json`、`pnpm-lock.yaml`）、`node_modules`、`dist/`、`build/`、`.next/`、`vendor/`、生成代码（`*.pb.go`、`*.generated.*`）、二进制。规则可配置，默认提供一套。
3. **排除 merge commit**（避免把合并当产出）。
4. **可选**：仅统计有 AI 活动的时间段附近的 commit（与 Tier A 会话时间交叠），减少把纯手写代码算进 AI 产出。
5. **窗口兜底**：无日志 cwd 命中时，回退到原计划的 30s 时间窗将 Tier B/C 请求关联到最近 commit。

## 数据模型（SQLite / GRDB）

```sql
-- AI 用量事件（Tier A 解析 / Tier C 元数据）
CREATE TABLE usage_event (
  id            INTEGER PRIMARY KEY,
  ts            INTEGER NOT NULL,          -- epoch ms
  source        TEXT NOT NULL,             -- 'claude-code' | 'aider' | 'proxy' | 'api-poll'
  provider_id   TEXT,                      -- 关联扩展 provider catalog
  model         TEXT,
  in_tokens     INTEGER DEFAULT 0,
  out_tokens    INTEGER DEFAULT 0,
  cache_tokens  INTEGER DEFAULT 0,
  cost_usd      REAL,                      -- 由定价表算出或官方口径回填
  repo_path     TEXT,                      -- 归属仓库（来自 cwd）
  session_id    TEXT,
  dedupe_key    TEXT UNIQUE                -- (source, sessionId, lineHash)
);
CREATE INDEX idx_usage_ts ON usage_event(ts);
CREATE INDEX idx_usage_repo ON usage_event(repo_path);

-- 代码产出（按 commit）
CREATE TABLE code_change (
  id           INTEGER PRIMARY KEY,
  ts           INTEGER NOT NULL,
  repo_path    TEXT NOT NULL,
  commit_sha   TEXT NOT NULL,
  added        INTEGER NOT NULL,
  deleted      INTEGER NOT NULL,
  net_lines    INTEGER NOT NULL,           -- added - deleted（已应用排除规则）
  UNIQUE(repo_path, commit_sha)
);

-- 关联结果（用量事件 ↔ 代码产出）
CREATE TABLE correlation (
  usage_id     INTEGER REFERENCES usage_event(id),
  change_id    INTEGER REFERENCES code_change(id),
  method       TEXT,                       -- 'cwd' | 'time-window'
  confidence   REAL
);

-- 受监控仓库
CREATE TABLE repo (
  path         TEXT PRIMARY KEY,
  enabled      INTEGER DEFAULT 1,
  added_at     INTEGER
);

-- 订阅制工具（摊销模型）
CREATE TABLE subscription_tool (
  id           INTEGER PRIMARY KEY,
  name         TEXT NOT NULL,
  monthly_fee  REAL NOT NULL,
  currency     TEXT NOT NULL,
  active       INTEGER DEFAULT 1
);
```

预聚合视图（今日/本周单行成本）走物化日表 `daily_rollup(date, cost_usd, net_lines, cpl)`，避免每次全表扫描。

## 技术决策

> 注：本节的代理方案对应 [数据采集策略](#数据采集策略核心重构) 的 **Tier C**，已从 MVP 主数据源降级为 Phase 3 可选增强。MVP 主数据源是 Tier A（本地 Agent 日志）+ Tier B（用量 API 轮询）。以下分析保留，供后续启用代理时参考。

### 代理方案：透明代理 vs HTTPS_PROXY vs 中间人证书

| 方案 | 无需配置 | 能看到元数据 | 能解密内容 | 安全风险 |
|------|---------|------------|-----------|---------|
| `NETransparentProxyProvider` | ✅ 自动 | ✅ 域名、大小、频率 | ❌ 加密 | 无 |
| 环境变量 `HTTPS_PROXY` | ❌ 每工具配置 | ✅ | ❌ | 无 |
| 中间人证书 | ✅ | ✅ | ✅ | 高（证书固定会拦截） |

**选择透明代理**: 零配置是付费产品的底线——用户付钱不是为了折腾配置。不解密内容意味着放弃精确 token 计数，但通过响应大小估算 + 定时轮询 API 获取精确余额，可以弥补。

**无法做到的事情**（透明代理的局限）:
- 不能区分同一 API 下不同模型的调用（除非服务商不同域名）
- 无法从加密流量中提取 token 用量
- 某些 AI 客户端使用证书固定（certificate pinning），透明代理无法拦截

**对策**:
- 元数据（域名+大小+频率）做实时统计
- 定时轮询 API 做精确余额校准
- 两者互补：代理回答"用了几次"，轮询回答"还剩多少钱"

### Git 监听：FSEvents vs git hook vs 定时轮询

| 方案 | 实时性 | CPU 开销 | 复杂度 |
|------|--------|---------|--------|
| FSEvents | 秒级 | 几乎为零 | 中 |
| git post-commit hook | 提交时 | 零 | 高（需注入每个仓库） |
| 定时 `git diff` | 分钟级 | 每次 fork 进程 | 低 |

**选择 FSEvents**: macOS 内核级文件系统事件，只需注册目录即可。只监听 `.git/objects` 目录变化（git 写入对象时触发），过滤掉无关文件变动。触发后运行 `git diff --stat` 获取变更。

**仓库发现策略**:
1. 默认扫描 `~/dev`、`~/projects`、`~/code`、`~/Documents/GitHub`
2. 用户可手动添加/移除目录
3. 排除 node_modules、.build、.next 等非代码目录的 git 仓库
4. 监控上限：最多 20 个活跃仓库（性能保护）

### 关联引擎：时间窗口 vs 进程跟踪 vs AI 推测

| 方案 | 准确度 | 侵入性 | 实现难度 |
|------|--------|--------|---------|
| 时间窗口（30s） | ~80% | 零 | 低 |
| 进程关联（同一 PID） | ~95% | 需 netstat 轮询 | 中 |
| AI 推测匹配 | ~60% | 零 | 高 |

**选择时间窗口**: 实现简单、零侵入、准确度足够。编程流程天然有时间规律——AI 返回代码 → 几秒内贴入编辑器 → git 检测变更。30 秒窗口捕获大部分关联。跨天统计后误差趋于正态分布。

**为何不用进程跟踪**: `lsof` 轮询连接和进程的对应关系可以精确知道"哪个进程发了这个请求"，但需要 root 权限——这对付费应用是致命减分项。用户不应该为这个功能授权 root。

**为何不用 AI 推测**: 用 LLM 匹配请求内容和 git diff 变动——准确度低、成本高、悖论（用 AI 分析 AI 花费）。

### 数据库：SQLite vs Core Data vs CloudKit

选择 **SQLite (GRDB.swift)**:
- 不需要 Core Data 的对象图管理（过度设计）
- 不需要 CloudKit（第一版不需要云同步）
- GRDB 是 Swift 最成熟的 SQLite 封装，支持类型安全查询
- 历史数据量大（一年数万条请求），SQL 查询最高效

### UI 框架：SwiftUI vs AppKit vs Electron

选择 **SwiftUI + AppKit 混合**:
- 菜单栏用 AppKit（`NSStatusBar` 是 AppKit 专属，SwiftUI 做不到）
- 面板/仪表盘用 SwiftUI（开发速度快、动画效果好）
- Dock 动画用 AppKit（`NSApplication.shared.dockTile`）
- 不选 Electron: 内存 200MB+ 的"hello world"不能接受，尤其是菜单栏常驻

### 付费模式

**一次性买断 $9.99**: 
- 一次付费永久使用，无需管理订阅
- 7 天免费试用
- 大版本升级（2.0）可选择重新收费

选择买断而非订阅的原因：
- 目标用户（开发者）对订阅极度反感
- 功能不需要持续服务端成本（本地解析 + 本地数据库）
- Mac 应用商店大量成功案例（Dash、Paw、Sketch 早年）

> **机制修正（E5）**：`isEligibleForIntroOffer` 是 StoreKit **订阅**专属 API，买断商品不适用。买断 + 试用应这样实现：
> - **Developer ID 直分发（v1 推荐）**：发放 **License Key**（经 Paddle / LemonSqueezy / Gumroad 等支付商），应用内做离线/在线校验；首次启动写入试用起始时间（存 Keychain 防篡改），到期前未激活则进入只读/受限模式。
> - **Mac App Store（可选）**：买断用非消耗型 IAP；"试用"用免费下载 + 功能受限、付费解锁，而非 intro offer。

### 与扩展的桥接

Mac 应用启动后监听 `127.0.0.1:8899`（仅本机回环），提供版本化 HTTP API。所有路径统一前缀 `/api/v1`：

```
GET /api/v1/health            → { "ok": true, "version": "0.1.0" }
GET /api/v1/stats/today       → { "calls": 23, "cost": 1.50, "lines": 89, "cpl": 0.017, "currency": "USD" }
GET /api/v1/stats/this-week   → { "calls": 102, "cost": 8.20, "lines": 410, "cpl": 0.02, "currency": "USD" }
```

安全约束：
- 仅绑定 `127.0.0.1`，不监听 `0.0.0.0`；
- 校验请求 `Origin`，仅放行扩展 origin（`chrome-extension://<id>`）；
- 返回 `Access-Control-Allow-Origin` 限定为扩展 id，避免任意网页探测本机服务（DNS rebinding 防护）。

扩展每次打开时 `fetch('http://127.0.0.1:8899/api/v1/health')`:
- 可达 → 显示实时统计页
- 不可达 → 回退到定时轮询（现有逻辑，不依赖 Mac 应用）

## 功能清单

### Phase 1 — 核心引擎（MVP，4-6 周）

| # | 功能 | 说明 |
|---|------|------|
| 1.1 | **Agent 日志解析（Tier A）** | FSEvents 监听 Claude Code / aider 等日志，增量解析 token/model/cwd（MVP 主数据源） |
| 1.2 | provider catalog + 定价表 | 复用扩展 13 个内置 provider，共享 catalog；新增 model→price 定价表用于成本换算 |
| 1.3 | 用量 API 轮询（Tier B） | 复用 `fetchBalance`/`/v1/usage` 拿官方口径金额，校准 Tier A |
| 1.4 | Git 仓库发现 | 自动扫描 ~/dev/ 等目录，用户勾选监控目标 |
| 1.5 | Git 行归因 | FSEvents 监听 `.git/objects`，按 commit 累加净增行（含排除规则） |
| 1.6 | 请求-代码关联 | 优先用日志 cwd 直接归属；无 cwd 时回退 30s 时间窗 |
| 1.7 | 单行成本计算 | `最终成本 / 净增代码行数`；订阅工具走摄销口径 |
| 1.8 | SQLite 本地存储 | usage_event / code_change / correlation 等表持久化 |
| 1.9 | 菜单栏应用 | 显示"今日花费 / 今日净增行 / 单行成本" |

### Phase 2 — 可视化与统计（+3-4 周）

| # | 功能 | 说明 |
|---|------|------|
| 2.1 | 按应用统计 | VS Code / Terminal / Cursor —— 哪个工具花钱最多 |
| 2.2 | 按模型统计 | GPT-4o vs Claude Sonnet —— 性价比排行 |
| 2.3 | 按仓库统计 | 哪个项目的代码最"贵" |
| 2.4 | 成本趋势图 | 本周/本月/本年的单行成本曲线 |
| 2.5 | 花费预测 | 基于本周速率，预估本月总花费 |
| 2.6 | 异常检测 | 某小时花费飙升 5x → 通知 |

### Phase 3 — 体验与变现（+3-4 周）

| # | 功能 | 说明 |
|---|------|------|
| 3.1 | Dock 金币动画 | 花费时 Dock 图标播放金币掉落动画 |
| 3.2 | 音效系统 | 花费超日均时播放声音 |
| 3.3 | 月度预算 | 设置预算上限，接近/超出告警 |
| 3.4 | 导出报表 | CSV/JSON 导出（可导入报销系统） |
| 3.5 | 桌面小组件 | macOS Sonoma Widget — 今日花费和单行成本 |
| 3.6 | 扩展桥接 | `127.0.0.1:8899/api/v1/*`，Chrome 扩展可读取 Mac 应用数据 |
| 3.7 | 扩展引流 | 扩展底部显示"升级 Mac 版，解锁单行成本统计" |
| 3.8 | 付费墙 | 7 天试用 → 一次性买断 $9.99（License Key / 非消耗型 IAP） |
| 3.9 | 透明代理（Tier C，可选） | NETransparentProxyProvider 补无日志工具的元数据盲区（需特别 entitlement） |

### Phase 4 — 高级功能（+4-6 周）

| # | 功能 | 说明 |
|---|------|------|
| 4.1 | GitHub 关联 | 关联 GitHub 用户名，补充 push 频率和 commit 分析 |
| 4.2 | 开发效率评分 | AI 辅助下的日均净增行数、提交频率排名 |
| 4.3 | Siri / Shortcuts | "Hey Siri，我今天花了多少？" |
| 4.4 | 团队面板 | 一个小团队的各成员花费/产出对比（可选） |
| 4.5 | 全局快捷键 | ⌘⇧A 快速查看用量浮窗 |

## 架构

```
mac-app/
├── Sources/
│   ├── App/                  # SwiftUI App 入口
│   │   ├── AI_PulseApp.swift
│   │   └── AppDelegate.swift
│   │
│   ├── Ingest/               # 数据采集（三层）
│   │   ├── LogParsers/             # Tier A：每个 Agent 一个适配器
│   │   │   ├── UsageLogParser.swift    # 统一接口
│   │   │   ├── ClaudeCodeParser.swift
│   │   │   └── AiderParser.swift
│   │   ├── ApiPoller.swift         # Tier B：复用 provider catalog 轮询
│   │   └── Proxy/                  # Tier C（可选）
│   │       ├── ProxyProvider.swift     # NETransparentProxyProvider
│   │       ├── FlowClassifier.swift    # 流量分类（AI/非AI）
│   │       └── DomainRegistry.swift    # 来自共享 catalog 的域名表
│   │
│   ├── GitMonitor/           # Git 仓库监控
│   │   ├── RepoScanner.swift           # 自动发现 git 仓库
│   │   ├── DiffWatcher.swift           # FSEvents 监听 diff
│   │   └── LineCounter.swift           # 净增行数计算
│   │
│   ├── Engine/               # 关联引擎
│   │   ├── CorrelationEngine.swift     # 请求-代码关联
│   │   ├── CostCalculator.swift        # 单行成本计算
│   │   └── TimeWindow.swift            # 30s 关联窗口
│   │
│   ├── Store/                # 数据层
│   │   ├── Database.swift              # SQLite 封装
│   │   ├── Models/                      # 数据模型
│   │   └── Migrations/                  # 数据库迁移
│   │
│   ├── Licensing/            # 买断/试用
│   │   ├── LicenseValidator.swift      # License Key 校验
│   │   └── TrialManager.swift          # Keychain 试用计时
│   │
│   ├── UI/                   # 界面
│   │   ├── MenuBar/                    # 菜单栏
│   │   ├── Dashboard/                  # 主面板
│   │   ├── Settings/                   # 设置
│   │   ├── DockAnimator/               # Dock 动画
│   │   └── Widgets/                    # 桌面小组件
│   │
│   └── Bridge/               # 扩展桥接
│       └── LocalAPIServer.swift        # localhost HTTP 服务
│
├── Tests/
├── Package.swift
└── README.md
```

## 关键技术选型

| 层 | 选型 | 原因 |
|----|------|------|
| 主数据源 | 本地 Agent 日志解析（Tier A） | 零权限、含精确 token/model/cwd |
| 校准数据源 | 用量/余额 API 轮询（Tier B） | 官方口径金额，复用扩展 provider |
| 可选增强 | NETransparentProxyProvider（Tier C） | 补无日志工具盲区；⚠．需特别 entitlement，非 MVP |
| 文件监听 | FSEvents | macOS 原生，几乎零 CPU 开销 |
| Git 操作 | 调用 `/usr/bin/git` 命令行 | 稳定可靠，不引入 libgit2 |
| 数据库 | SQLite (GRDB.swift) | 轻量、适合本地单机 |
| UI | SwiftUI + AppKit 混合 | 菜单栏用 AppKit，面板用 SwiftUI |
| 自更新 | Sparkle（Developer ID 路线） | 非 MAS 分发的事实标准 |
| 最低系统 | macOS 14 Sonoma | Widget、SwiftUI 新特性 |

## 与 Chrome 扩展的关系

```
Mac App (127.0.0.1:8899)
  ├─ GET  /api/v1/stats/today       → 扩展读取今日统计
  ├─ GET  /api/v1/cost-per-line     → 扩展显示单行成本
  └─ GET  /api/v1/providers/status  → 扩展读取实时状态

Chrome Extension
  ├─ 检测 127.0.0.1:8899 可达 → 显示实时数据（Mac App 在线）
  └─ 不可达 → 回退到定时轮询（独立工作）
```

### 共享 catalog（避免两边不同步）

扩展与 Mac 应用应共用一份以数据驱动的 provider catalog，避免两套硬编码域名/名称发散：

- 从扩展现有 `providers/*/index.ts` 抽取静态元数据（`id`/`name`/`baseUrl`/`faviconUrl`/API 域名/`balanceType`），生成 `shared/provider-catalog.json`。
- 扩展构建时校验 catalog 与代码一致；Mac 应用构建时将其打包为 `DomainRegistry` 与 provider 列表。
- 定价表 `shared/pricing-catalog.json` 同理共享。

扩展底部：
> 📈 升级 Mac 版 — 解锁单行成本、实时统计、Dock 动画。7 天免费试用。

## 分发、权限与签名

### 分发路线选择（E6）

核心功能（扫描任意用户目录的 git 仓库、读取容器外的 `~/.claude` 等日志）与 **MAS 沙箱**冲突。建议：

| | Developer ID 直分发（v1 推荐） | Mac App Store（后续可选） |
|---|---|---|
| 沙箱 | 可用用户授权访问任意目录 | 严格沙箱，需 security-scoped bookmark，体验差 |
| 日志读取 | 可读 `~/.claude` 等 | 容器外读取受限 |
| NetworkExtension | 系统扩展 + 用户授权即可 | 需 Apple 特别 entitlement 审批 |
| 付费 | License Key（Paddle/LemonSqueezy） | 非消耗型 IAP |
| 自更新 | Sparkle | App Store 接管 |

**v1 走 Developer ID 直分发**，避开沙箱与 entitlement 摩擦；待产品稳定后再评估是否出 MAS 版本。

### 权限与 entitlement

- **完整磁盘访问 / 目录授权**：首次扫描仓库、读取日志时引导用户授权（明确告知用途）。
- **NetworkExtension（仅 Tier C）**：`com.apple.developer.networking.networkextension`，需 System Extension 打包与用户授权；MAS 下需 Apple 特批。**MVP 不启用**。
- **Keychain**：存 License 与试用起始时间。

### 签名与公证流水线

1. `xcodebuild archive` → Developer ID Application 签名（Hardened Runtime）。
2. `notarytool submit --wait` 提交公证 → `stapler staple` 钒钉。
3. Sparkle appcast 发布 + EdDSA 签名更新包。
4. CI（GitHub Actions, `macos-14` runner）：`swift build` / `xcodebuild test` → 打包 → 签名 → 公证 → 上传产物。

## 隐私与安全

应用会接触源码 diff 与含 prompt 的会话日志，隐私是付费开发者产品的生命线：

- **仅本地处理**：所有解析/统计在本机完成，**绝不上传代码内容、prompt、diff 原文**。
- **只存聚合**：数据库只存 token 计数、行数、金额、仓库路径哈希等聡象指标；不存代码文本、不存 prompt。
- **API Key 最小化**：轮询用 Key 存 Keychain；可与扩展共享但不明文落盘。
- **本机服务加固**：桥接 API 仅绑 `127.0.0.1`、校验 Origin、限定 CORS、防 DNS rebinding（见上）。
- **可审计与关闭**：用户可随时查看被监控的目录/日志源、一键清数据、逐源关闭采集。
- **代理不解密**：Tier C 只看元数据，不做中间人证书、不解密流量内容。

## 开发计划与里程碑

> 周数为相对工量估算（单人全职），不代表承诺交付时间。

### M0 — 骨架与验证（走通一条数据链）
验收：能解析一个 Claude Code 会话日志 → 写入 `usage_event` → 在菜单栏显示今日总 token 与估算金额。

### M1 — MVP（Phase 1）
验收标准：
- 日志解析：增量解析、去重正确（重启不重复计费）；至少接入 Claude Code + aider。
- 行归因：按 commit 统计净增行，lockfile/生成代码被排除；merge commit 不计入。
- 成本：Tier A 估算与 Tier B 官方金额误差 < 10%（有官方口径时）。
- 菜单栏准确显示今日花费 / 净增行 / 单行成本。
- 单测覆盖解析器、行归因、成本计算。

### M2 — 可视化与统计（Phase 2）
验收：按工具/模型/仓库维度的统计与趋势图准确；异常检测可触发通知。

### M3 — 体验、桥接与变现（Phase 3）
验收：Dock 动画/小组件/预算告警可用；扩展能读 `127.0.0.1:8899` 实时数据；买断+试用闭环走通（License 校验 + 试用到期限制）。可选：Tier C 代理。

### M4 — 高级功能（Phase 4）
验收：GitHub 关联、效率评分、Shortcuts、全局快捷键。

### 性能预算
- 闲置内存 < 80MB；菜单栏常驻 CPU 近 0%。
- 日志增量解析单批 < 50ms；仓库 commit 处理 < 100ms。
- 本地 API 响应 < 20ms。

### 测试与 CI
- **单元**：XCTest 覆盖解析器、行归因排除规则、成本计算、去重；用真实日志样本做 fixture。
- **集成**：临时 git 仓库 + 模拟日志 → 验证端到端单行成本。
- **CI**：GitHub Actions `macos-14`：`swift build` + `xcodebuild test`；主干合并跑签名/公证冗余检查。
- **与扩展共享测试**：catalog/pricing JSON 由单一来源生成，两边 CI 均校验一致性。
