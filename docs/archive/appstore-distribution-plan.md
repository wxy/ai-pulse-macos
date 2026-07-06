# AI Pulse 分发方案 v3

> 2026-06-30
> 基于用户 v2 修订。**保留 v2 全部正确决策**，仅修订三处分歧。与 `PLAN.md`、`PRODUCT_DESIGN.md`(v1.3) 对齐。

---

## 0. 与 v2 的差异（TL;DR）

**沿用 v2 正确的部分**：不做系统 PAC、不做 MITM、不做 privileged helper；CPL 仅来自日志；libgit2 替代 Process git；Security-Scoped Bookmark；代理走 `HTTPS_PROXY` 环境变量、只喂花费图、不进 CPL、不做 repo 归因。

**修订三处**：

| # | v2 | v3 | 理由 |
|---|---|---|---|
| 1 | App Store 唯一渠道，删 Developer ID | **MAS-first，保留 Developer ID 兜底**；代理优先放 Developer ID | v2 新增的"改 `.zshrc` + home 访问 + 本地代理"恰是审核高风险点；单渠道无保险 |
| 2 | P 层作为覆盖"所有工具"的增强 | **P 层定位诚实化**：独特价值很窄 + 可靠性警告 + 严格可选 | GUI 不读 env-var、CLI 已有日志，净增覆盖仅"无解析器的 CLI 工具" |
| 3 | 端口 1.5 固定 / 1.6 自动递增（矛盾）；EditorDetector 随 libgit2 落地 | **端口动态回填**；EditorDetector 维持 P3+ 后置 | 修内部不一致；与 v1.3 一致 |

---

## 1. 分发决策：MAS-first，保留 Developer ID 兜底

### 1.1 为什么不删 Developer ID

- **单渠道 = 把产品命运押在一次审核上**。AI Pulse 的三个能力恰是审核敏感区：
  1. **要求用户改 `.zshrc`**：App Store 审核倾向拒绝"必须命令行配置才能启用"的功能（即便标注可选）。
  2. **整个 home 目录读取**：Apple 偏好最小权限，整 home 访问常被要求收窄。
  3. **本地代理拦截其他 app 流量**：用途需在审核中充分说明，存在被质疑风险。
- **同类工具的事实**：Charles、Proxyman 等"开发者 + 代理 + 读取本地"类工具多走 Developer ID 直分发，正因上述摩擦。MAS-only 是逆流。
- **成本对比**：sandbox-ready 的**同一份二进制在 Developer ID 下照跑**（沙箱是更严约束的超集）。维护两条线的增量主要是签名/公证/Sparkle，成本可控；而 Developer ID 作为"审核被拒时的唯一出货渠道"，保险价值高。

### 1.2 最终形态：同一份二进制，两份配置

```
MAS 版                           Developer ID 版
├─ 日志(A) ✅                    ├─ 日志(A) ✅
├─ 余额(B) ✅                    ├─ 余额(B) ✅
├─ 订阅(C) ✅                    ├─ 订阅(C) ✅
├─ CPL（仅日志）✅                ├─ CPL（仅日志）✅
├─ 两张图表 ✅                    ├─ 两张图表 ✅
├─ 代理+PAC ❌                   ├─ 代理+PAC ✅（自动配，Touch ID 一次）
│                                ├─ PID→cwd 仓库归因
│                                └─ 全工具覆盖，零适配器
├─ 零审核风险                     ├─ 零审核约束
├─ App Store 流量                 ├─ 功能最强版
└─ 覆盖 90% 用户价值              └─ 覆盖需要完整追踪的高级用户
```

**同一份 sandbox-ready 二进制**，MAS 配置少 `network.server` entitlement。维护成本是单轨两份配置，不是双轨。MAS 版不提供代理功能，开箱零终端配置。

| 版本 | 代理 + PAC | 用户操作 |
|------|:---:|------|
| **MAS 版** | 不提供 | 零终端——开箱即用 |
| **Developer ID 版** | ✅ 自动配 + PID→cwd 归因 | Touch ID 一次 → PAC 自动启停 |


### 1.3 决策顺序（重要）

> **先送 MAS 核心版拿到真实审核结论，再决定是否真的弃用 Developer ID。** 在拿到 MAS 批准前，不删除 Developer ID 构建。

---

## 2. 备选方案评估

| 方案 | 结论 |
|------|------|
| 透明代理（`NETransparentProxyProvider`） | ❌ 需 System Extension + Apple 特批 entitlement |
| MITM 证书解密 | ❌ certificate pinning 阻断 + 安全风险，违背信任 |
| 系统 PAC + SMJobBless | ❌ 沙箱无权改系统网络设置；SMJobBless 已弃用；审核必拒 |
| 仅余额 API | ⚠️ 无 repo 归因，单独不足，作为 B 层保留 |
| 仅订阅登记 | ⚠️ 无法追踪第三方 API，作为 C 层保留 |
| **MAS-only、删 Developer ID** | ❌ 过早：审核敏感点集中、无兜底（见 §1） |
| **✅ MAS-first + Developer ID 兜底 + env-var 代理** | 选此（见 §1） |

---

## 3. P 层（env-var 代理）的诚实定位

### 3.1 原理（修正术语）

用户手动设一行环境变量，指向本地 CONNECT 代理：

```bash
export HTTPS_PROXY=http://127.0.0.1:<实际端口>
```

客户端发送 `CONNECT api.anthropic.com:443`，代理**从 CONNECT 请求行直接取 host**（显式代理无需解析 SNI；SNI 属透明代理场景）。不解密 TLS，只得：provider 域名 + 上下行字节数。

### 3.2 它的独特价值很窄（必须如实告知）

| 工具类型 | env-var 代理能抓？ | 是否已被覆盖 |
|---|:---:|---|
| GUI（Cursor / VSCode 内建） | ✗ 多数不读 `HTTPS_PROXY` | — |
| CLI Agent（Claude Code / aider） | ✓ | 已有日志(A)，**重复** |
| **无解析器的 CLI 工具 / 自写脚本 / codex 类** | ✓ | **这才是净增覆盖** |

→ P 层的真实增量 = "**没有日志解析器的 CLI 工具的粗略花费信号**"。是个有价值但**窄**的补盲，不是"覆盖所有工具"。

### 3.3 可靠性 / 信任警告（必须设计）

- 把 `export` 永久写进 `.zshrc` 后，**AI Pulse 未运行时，CLI 的所有 HTTPS 调用会连接被拒**——监控工具反而搞挂被监控对象。
- **对策（fail-open）**：
  1. 引导**优先建议 per-session 设置**（当前终端 `export`），而非永久写入 `.zshrc`；
  2. 永久方案需明确风险文案 + 一键关闭（移除该行）的指引；
  3. 代理崩溃自动重启；端口绑定失败时**不静默换端口**（见 §4）。

### 3.4 产品约束

- **严格可选、默认关闭、绝不进首次启动主路径**。
- 核心功能（A/B/C + 两张图）**零终端配置**即可用。
- P 层产出标注"代理估算"，**只进花费图、不进 CPL、不求和**（v1.3 铁律）。

---

## 4. 端口处理（修 v2 内部矛盾）

v2 中 1.5 给固定 `18899`、1.6 又自动递增——用户粘贴的固定行会与实际绑定端口不符。

**v3 规则**：

- 启动时绑定 18899；若被占用，依次尝试 18900/18901…（保留 v2 探测器）。
- **引导页的"复制命令"按钮动态回填实际绑定端口**，绝不给死值。
- 实际端口变化时，设置页同步更新展示命令，并提示用户更新 env 值。

---

## 5. 数据架构（沿用 v2 四层 + 铁律）

| 层级 | 来源 | 成本精度 | 仓库归因 | 进 CPL | 进花费图 |
|:---:|------|:---:|:---:|:---:|:---:|
| **A 日志** | Claude Code / aider | token 级精确 | cwd | ✅ 唯一来源 | ✅ |
| **B 余额** | API 余额轮询 | 全局合计 | 无 | ❌ | ✅（标"余额"） |
| **C 订阅** | 用户登记（+ EditorDetector，**P3+ 可选**） | 固定月费 | ⚠️ 仅 P3+ | ❌ | ✅（标"订阅"） |
| **P 代理** | 可选 `HTTPS_PROXY` | 流量趋势（估算） | 无 | ❌ | ✅（标"代理估算"） |

**铁律**：只有 A 进 CPL（v1.3 有效门：per-token 精确 + 有日志 + 按量计费）；B/C/P 仅进花费图、各自独立标注、**永不求和**。

> 订正：**EditorDetector 维持 `PRODUCT_DESIGN.md` v1.3 的 P3+ 后置/可选定位**，不因 libgit2 改造提前落地。阶段 1.4 的 `gitToplevel()` 替换仅在 EditorDetector 真正启用时才需要。

---

## 6. 实施计划

> 原则：**libgit2 + Bookmark 是"上沙箱"的地基，先做**（单/双渠道都受益）；代理与 `.zshrc` 引导排到最后且 gated；**MAS 核心版送审作为独立里程碑，先于代理 MAS 化**。

### 阶段 1：libgit2 替换（沙箱地基）

| # | 任务 | 文件 |
|---|------|------|
| 1.1 | 引入 libgit2（vendored 或 Clibgit2 module map；注意无官方 SPM，需维护） | `Package.swift` |
| 1.2 | 封装 `GitRepo`：`log(since:)` / `diffTree(hash:)` / `findRoot(containing:)` | `Sources/Engine/GitRepo.swift`（新） |
| 1.3 | 替换 `GitMonitor.runGit()` → `GitRepo` | `Sources/GitMonitor/GitMonitor.swift` |
| 1.4 | （仅 EditorDetector 启用时）替换 `gitToplevel()` | `Sources/Engine/EditorDetector.swift` |

### 阶段 2：Security-Scoped Bookmark（沙箱地基）

| # | 任务 | 文件 |
|---|------|------|
| 2.1 | `BookmarkManager`：create / resolve / 持久化 | `Sources/Engine/BookmarkManager.swift`（新） |
| 2.2 | 引导页"授权主目录"步骤（一次 Open Panel；尽量引导收窄到 `~` 或代码根目录） | `Sources/UI/Onboarding/OnboardingView.swift` |

### 阶段 3：MAS 核心版送审（里程碑）

| # | 任务 |
|---|------|
| 3.1 | Entitlements：`network.client`、App Group、`files.user-selected.read-only`（核心版**不含** `network.server`） |
| 3.2 | Info.plist 隐私说明（读代码与日志，**绝不外传**） |
| 3.3 | 送 MAS 核心版（A/B/C + 两张图，零终端）→ **取得真实审核结论** |

### 阶段 4：HTTPS CONNECT 代理（可选增强，优先 Developer ID）

| # | 任务 | 文件 |
|---|------|------|
| 4.1 | `ProxyServer`（NWListener CONNECT 隧道 + 字节统计；fail-open + 自动重启） | `Sources/Engine/ProxyServer.swift`（新） |
| 4.2 | `PortDetector`（18899 起，动态回填实际端口给 UI） | `Sources/Engine/PortDetector.swift`（新） |
| 4.3 | `proxy_event` 表 + 统计查询 | `Sources/Store/Database.swift`、`StatsService.swift` |
| 4.4 | Dashboard 花费图增加"代理估算"独立数据层 | `Sources/UI/Dashboard/DashboardView.swift` |

### 阶段 5：代理引导（gated，零终端核心之外）

| # | 任务 | 文件 |
|---|------|------|
| 5.1 | 设置页：`HTTPS_PROXY` 引导（**per-session 优先** + 风险文案 + 一键复制动态端口 + 关闭指引） | `Sources/UI/Settings/SettingsView.swift` |
| 5.2 | 代理设置**不进首次启动主路径**，仅作可选项 | `Sources/UI/Onboarding/OnboardingView.swift` |

### 阶段 6：分发决策收尾

| # | 任务 |
|---|------|
| 6.1 | 依据阶段 3 审核结论，决定代理是否携带进 MAS，或仅留 Developer ID |
| 6.2 | Developer ID：Hardened Runtime + notarize + Sparkle appcast（保留为兜底 + 代理之家） |

---

## 7. MAS 审核风险清单（新增）

| 风险点 | 缓解 |
|------|------|
| 要求改 `.zshrc` | 代理为可选增强；核心版零终端；必要时代理只走 Developer ID |
| 整 home 目录访问 | 引导收窄到代码根/`~`；明确用途文案；security-scoped 标准做法 |
| 本地代理拦其他 app 流量 | 用途说明 + 仅回环 + opt-in + 不解密；预期仍可能被质疑 → 兜底 Developer ID |
| 隐私标签 | 声明"本地处理，不收集、不外传代码/prompt/diff" |
| 读取 `~/.claude` 等隐藏目录 | bookmark 子树访问；隐私说明覆盖 |

---

## 8. 不做的事

| 方案 | 否决原因 |
|------|----------|
| 透明代理 | Apple 特批 entitlement + System Extension |
| MITM 证书 | certificate pinning + 安全风险 |
| 系统 PAC 自动配置 | MAS 审核必拒 + SMJobBless 弃用 |
| 代理成本进 CPL | 违反 v1.3 有效门（非 per-token 精确） |
| 代理做 repo 归因 | 沙箱内 `proc_pidinfo` 受限，不可靠 |
| **删除 Developer ID 渠道** | 失去审核被拒时的唯一出货渠道与快速迭代能力（见 §1） |
| 永久 `.zshrc` 为默认引导 | app 未运行时会拒断 CLI 调用；改 per-session 优先 |
