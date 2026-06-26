# AI Pulse Mac App — 产品设计与开发计划

## 产品定位

Chrome 扩展（免费）做通用 AI 余额监控，Mac 应用（付费）做编程场景的深度统计——核心差异化功能是 **AI 编程单行成本**。

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

## 技术决策

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
- 7 天免费试用（macOS 原生支持 `isEligibleForIntroOffer`）
- 大版本升级（2.0）可选择重新收费

选择买断而非订阅的原因：
- 目标用户（开发者）对订阅极度反感
- 功能不需要持续服务端成本（本地代理+本地数据库）
- Mac 应用商店大量成功案例（Dash、Paw、Sketch 早年）

### 与扩展的桥接

Mac 应用启动后监听 `localhost:8899`，提供 HTTP API:

```
GET /health               → { "ok": true, "version": "0.1.0" }
GET /stats/today          → { "calls": 23, "cost": 1.50, "lines": 89, "cpl": 0.017 }
GET /stats/this-week      → { "calls": 102, "cost": 8.20, "lines": 410, "cpl": 0.02 }
```

扩展每次打开时 `fetch('http://localhost:8899/health')`:
- 可达 → 显示实时统计页
- 不可达 → 回退到定时轮询（现有逻辑，不依赖 Mac 应用）

## 功能清单

### Phase 1 — 核心引擎（MVP，4-6 周）

| # | 功能 | 说明 |
|---|------|------|
| 1.1 | 透明代理 | NETransparentProxyProvider，无需证书，拦截元数据 |
| 1.2 | API 域名匹配 | 内置 18 个 AI 服务商域名，用户可自定义添加 |
| 1.3 | Git 仓库发现 | 自动扫描 ~/dev/ 等目录，用户勾选监控目标 |
| 1.4 | Git diff 监听 | FSEvents 监听选中仓库的代码变更 |
| 1.5 | 请求-代码关联 | 时间窗口（30s）内将 API 请求关联到 git 变更 |
| 1.6 | 单行成本计算 | `AI 调用花费总和 / 净增代码行数（+行 - 删除行）` |
| 1.7 | SQLite 本地存储 | 所有请求、git 变更、关联结果持久化 |
| 1.8 | 菜单栏应用 | 显示"今日花费 / 今日净增行 / 单行成本" |

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
| 3.6 | 扩展桥接 | localhost HTTP API，Chrome 扩展可读取 Mac 应用数据 |
| 3.7 | 扩展引流 | 扩展底部显示"升级 Mac 版，解锁单行成本统计" |
| 3.8 | 付费墙 | 7 天试用 → 一次性买断 $9.99 或订阅 $0.99/月 |

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
│   ├── Proxy/                # 透明代理
│   │   ├── ProxyProvider.swift         # NETransparentProxyProvider
│   │   ├── FlowClassifier.swift        # 流量分类（AI/非AI）
│   │   └── DomainRegistry.swift        # 内置 AI 域名列表
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
| 代理 | NetworkExtension / NETransparentProxyProvider | 系统级拦截，无感知 |
| 文件监听 | FSEvents | macOS 原生，零 CPU 开销 |
| Git 操作 | 调用 `/usr/bin/git` 命令行 | 稳定可靠，不需引入 libgit2 |
| 数据库 | SQLite (GRDB.swift) | 轻量、适合本地单机 |
| UI | SwiftUI + AppKit 混合 | 菜单栏用 AppKit，面板用 SwiftUI |
| 最低系统 | macOS 14 Sonoma | Widget、SwiftUI 新特性 |

## 与 Chrome 扩展的关系

```
Mac App (localhost:8899)
  ├─ GET  /api/stats/today        → 扩展读取今日统计
  ├─ GET  /api/cost-per-line     → 扩展显示单行成本
  └─ GET  /api/providers/status  → 扩展读取实时状态

Chrome Extension
  ├─ 检测 localhost:8899 可达 → 显示实时数据（Mac App 在线）
  └─ 不可达 → 回退到定时轮询（独立工作）
```

扩展底部：
> 📈 升级 Mac 版 — 解锁单行成本、实时统计、Dock 动画。7 天免费试用。
