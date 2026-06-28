# AI 花费归因模型

> 版本 v1 — 2026-06-27
> 本文档定义 AI Pulse Mac 应用的**花费归因逻辑**和**数据展示策略**。
> 基于对现有能力的诚实评估，核心原则：**不求和不同精度的数据，不用估算误导用户**。

---

## 1. 三类原始数据

| # | 数据层 | 来源 | 精确度 | 能归因到 repo | 能归因到 provider | 能归因到 tool |
|---|--------|------|:---:|:---:|:---:|:---:|
| L1 | Token 花费 | 本地日志解析 (Tier A) | **高** | ✅ cwd | ✅ model→provider | ✅ 日志源 |
| L2 | API 余额变化 | 服务商 API 轮询 (Tier B) | **中** | ❌ 聚合值 | ✅ provider | ❌ |
| L3 | 订阅月费 | 用户选择套餐 | **低** | ❌ 固定成本 | ❌ | ✅ tool name |

### L1 — Token 花费（唯一精确归因源）

- 来源：Claude Code `.jsonl`、aider `.llm.history`
- 每笔调用有：`model`、`input/output/cache tokens`、`cwd`
- `cwd` → `findGitRepo(containing:)` → repo_path
- `model` → `PricingManager.pricing(for:)` → 单价 → `cost_usd`
- **这是唯一能精确按 repo 拆分花费的数据**

### L2 — API 余额变化

- 来源：4 个 provider 的官方 API（DeepSeek/OpenAI/Kimi/Zhipu）
- 只能拿到 provider 级别的余额变化，无法拆分到 repo 或 tool
- 可能与 L1 重叠（同一个 API 调用可能在日志和余额轮询中都被统计）
- 用途：**不作为 CPL 计算输入，仅作独立参考展示**

### L3 — 订阅月费

- 来源：用户选择订阅套餐（自动检测已安装 IDE）
- 月费是固定成本，无法拆分到 provider、repo、或具体调用
- 可能与 L1/L2 重叠（Cursor 订阅内包含的 API 调用可能也在日志/余额中体现）
- 用途：**作为独立预算行展示，不参与 CPL 计算**

---

## 2. 重叠问题

```
同一个 API 调用可能同时出现在：

  L1 日志 ──→ Anthropic / claude-sonnet-4 / $0.05
  L2 余额 ──→ Anthropic 余额减少了 $0.05
  L3 订阅 ──→ Cursor Pro 月费 $20 的一部分

→ 三层加总会 double/triple count
→ 因此不应该求和
```

```
编程工具 ↔ AI 服务商 的多对多关系：

  Cursor ──┬── Anthropic（订阅额度）
            ├── OpenAI（用户自己 Key）
            └── DeepSeek（用户自己 Key）

  VS Code ─┬── GitHub Copilot（credits）
            ├── Anthropic（via Copilot）
            └── 其它 Model Context Protocol

  Claude Code ─── Anthropic（用户 Key，日志可追踪）
  aider ────┬── OpenAI（用户 Key，日志可追踪）
             └── DeepSeek
```

---

## 3. CPL 计算策略

### 原则

> **CPL = L1 Token 花费 / L1 对应时间段的 repo 净增行**

只用 L1（日志追踪）数据，因为：
- 花费可精确到 repo
- 净增行也精确到 repo
- 没有重叠污染的 risk

### 公式

```swift
// Per-repo CPL
repoCPL = repoL1Cost / repoNetLines(from commit numstat)

// Global CPL
globalCPL = totalL1Cost / totalNetLines

// 时间窗口：本周（Mon 00:00 → Sun 23:59）
```

### 不包含

- ❌ L2 API 余额变化（无法归因到 repo，且可能与 L1 重叠）
- ❌ L3 订阅月费（无法归因到 repo/provider，且可能与 L1 重叠）
- ❌ Cursor/Copilot 的超量 credits（无 API，完全不可知）

---

## 4. 仪表盘展示

```
┌─────────────────────────────────────────────────┐
│ AI 花费（Token，精确）        $42.50            │
│ AI 花费（含订阅月度摊销）        $72.50  ⚠️ 估算  │
│ 净增行数                       5,200             │
│ CPL（精确）                  $0.0082/行          │
│ CPL（含订阅）                $0.0139/行 ⚠️ 估算   │
└─────────────────────────────────────────────────┘

┌ Token 花费明细（按 repo）─────────────────────┐
│  ai-pulse      3200 行 | $18.20 | $0.0057/行  │
│  other-repo    2000 行 | $24.30 | $0.0122/行  │
└───────────────────────────────────────────────┘

┌ 订阅月费（独立，不参与 CPL）────────────────────│
│ Cursor Pro       $20/月 ⚠️ 可能与 Token 花费重叠  │
│ Copilot Pro      $10/月 ⚠️ 超量 credits 未计入    │
└───────────────────────────────────────────────┘

┌ API 余额（独立，不参与 CPL）───────────────────│
│ DeepSeek  ¥320 余额                              │
│ OpenAI   $2.50 消耗（近 3 日）                    │
│ ⚠️ 余额变化可能包含 Token 花费中的数据              │
└───────────────────────────────────────────────┘
```

---

## 5. 编辑器侦测（辅助信号）

当用户配置了订阅套餐，且对应编辑器正在运行时，GitMonitor 在检测到 commit 时：
1. 查询当前运行的编辑器列表 (`NSWorkspace.runningApplications`)
2. 对每个运行的编辑器，检查其 workspace state 是否包含当前 repo 路径
3. 若匹配：标记该 commit "可能与 Cursor/Windsurf/... 相关"
4. **不同步**：这些标记仅作为**辅助信息**在 Dashboard 展示，不改变 CPL 计算

用途：
- 帮助用户理解 L1/L3 数据的关系
- 引导用户为有日志的工具配置 API Key

---

## 6. 数据结构

### Database（当前 schema）

```sql
-- 已有
usage_event(ts, source, model, in_tokens, out_tokens, cache_tokens,
            cost_usd, repo_path, dedupe_key)
code_change(ts, repo_path, commit_hash, added, deleted, is_merge)
subscription_tool(id, name, monthly_fee, currency)

-- 新增（L3 订阅摊销）
subscription_attribution(id, subscription_name, repo_path, ts, net_lines, confidence)
  -- confidence: "inferred" (编辑器 workspace 匹配)
```

### 关键 class

```
StatsService        -- 聚合查询（已有，直接用于 CPL 计算）
EditorDetector      -- 运行时编辑器检测 + workspace 解析
CostCalculator      -- CPL 计算（只用 L1 数据）
SubscriptionService -- 订阅配置管理（已有 SubscriptionRegistry）
ApiPoller           -- L2 API 轮询（已有，仅作独立展示）
```

---

## 7. 实现步骤

| 步骤 | 内容 | 影响范围 |
|:---:|------|---------|
| 1 | 重构 `subscription_tool` schema，加 `bundle_ids` | Database, SubsTab |
| 2 | 创建 `EditorDetector`（workspace state 解析） | 新文件 |
| 3 | 创建 `CostCalculator`（只从 L1 计算 CPL） | 新文件，替换现有分散逻辑 |
| 4 | 重构 `DashboardView` 按本文档展示分层数据 | DashboardView |
| 5 | 重构 `MenuBarController.fetchStats()` 统一口径 | MenuBarController |
| 6 | 移除旧硬编码预设和错误归因逻辑 | 清理代码 |

---

## 8. 已知盲区（不做，诚实标注）

| 盲区 | 原因 |
|------|------|
| Copilot 超量 credits | 无公开 API |
| 无日志的 API 调用归属 | 无 cwd 数据 |
| 订阅月费的具体 API 组成 | Cursor 等不公开其模型路由 |
| 人写代码 vs AI 写代码 | 无法区分 |
| 多编辑器同时编辑同一 repo | 无法精确分配 |
