# AI Pulse Mac App — 开发计划

## 产品定位

Chrome 扩展（免费）做通用 AI 余额监控，Mac 应用（付费）做编程场景的深度统计——核心差异化功能是 **AI 编程单行成本**。

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
