# HTTPS 代理方案事后分析

> 2026-06-30 · 已撤销

## 动机

希望用本地 HTTPS CONNECT 代理捕获 AI API 流量（SNI hostname + 字节数），作为 A 级日志的通用兜底层，避免为每个编辑器编写适配器。

## 实现

- `ProxyServer.swift`：NWListener CONNECT 代理，127.0.0.1 监听，TCP 隧道转发 + 字节计数
- `PortDetector.swift`：端口探测（18899 起自动递增）
- `proxy_event` 数据库表 + `StatsService.proxyDailyStats` 查询
- Dashboard 代理流量卡片（字节体积，非花费）
- 设置页代理开关 + HTTPS_PROXY 环境变量引导

## 发现的问题

1. **字节 → Token → 成本不可推**。不同模型 tokenizer、input/output 定价比、JSON/SSE 框架开销、TLS 记录开销均不可知。代理能看到的字节数和实际花费之间不存在可靠的换算关系。

2. **字节 → 花费不能假装**。任何形式的"估算成本"都是误导。v1.3 刚否定了不精确的 CPL，整条代理都在同一个方向上。

3. **覆盖范围与已有方案高度重叠**。代理使用场景的分析：

| 场景 | 代理能覆盖？ | 是否已有更好方案 |
|------|:---:|------|
| Claude Code / aider | 能 | A 级日志（更精确） |
| Cursor/VSCode 官方订阅 | 不能（GUI 不读 HTTPS_PROXY） | C 级订阅登记 |
| 自写脚本调 API | 能 | 无覆盖（但群体极小） |

代理唯一净增量：自写脚本的 API 调用。价值不足以支撑 5 个文件 + 1 张表 + UI 的维护成本。

4. **repo 归因不可行**。代理看到的是 TCP 连接，无法可靠反查进程 PID→cwd。即使 Developer ID 下用 proc_pidinfo 也存在竞态。代理不能做仓库归因。

5. **系统 PAC 在 MAS 下不可行**。`SMJobBless` 弃用、沙箱应用无权改系统网络设置。HTTPS_PROXY 环境变量只能覆盖终端工具。

## 能留下的

- **存在性信号**：代理可以确认"有人在用 Anthropic/DeepSeek"，但不能量化花费。作为定性展示有一些价值，但非常有限。

## 结论

**撤销。** 代理是一个在理论上吸引人、在实践中几乎不产生独特价值的子系统。它的存在性信号不足以证明其维护成本。A+B+C 三层已覆盖绝大多数用户场景。

## 保留的部分

无。代理及其所有依赖全部撤销。`proxy_event` 表如已存在于用户数据库则残留为空表，无实际影响。
