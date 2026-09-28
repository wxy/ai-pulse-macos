# 性能优化端到端验收 Runbook

2026-09-27 整理。四轮 macOS CPU 峰值优化（刷新扇出、余额查询索引、重复扫描、仓库授权热点）已完成编译与查询级验证，但"峰值已消失"的声明只能由本验收闭环。背景、根因与历史观察数据见 [performance-optimization-2026-09-23](../performance-optimization-2026-09-23.md)；本文是唯一可重复的执行清单与判定门槛。

## 前置条件（缺一不可）

1. **签名构建**：由用户构建并启动签名的 Xcode Debug（或 Release）版。不得把未签名构建或旧安装版当作验收对象。
2. **隔离运行**：记录构建号、Bundle ID 与启动时间；确认同 Bundle ID 无旧进程残留。
3. **可重复数据**：开始与结束各记录一次只读行数（见步骤 4）；数据持续写入是允许的，但必须如实记录，不得与旧 Release 的不同数据集做严格 A/B 声明。
4. **观察窗口**：至少覆盖一次启动首轮 + 一次五分钟 Phase 4 同步 + 多个 30 秒扫描周期；期间不操作窗口（另做一轮开/关窗口情形，见判定 4）。

## 采集步骤（只读；重跑时替换 PID、输出路径与 journal 过滤值）

```sh
# 1. 确定 PID 与可执行文件时间戳
ps -axo pid,ppid,lstart,etime,%cpu,cputime,rss,comm | rg 'AIPulse|PID'

# 2. 全程 CPU 时间线（约 5 分钟，5 秒采样）
top -l 65 -s 5 -pid <PID> -stats pid,cpu,time,mem

# 3. 五分钟调用栈（覆盖至少一次 Phase 4）
xcrun xctrace record --template 'Time Profiler' --attach <PID> --time-limit 5m \
  --output /private/tmp/aipulse-perf-accept-$(date +%Y%m%d-%H%M).trace --no-prompt

# 4. 诊断 journal：快照构建次数与耗时
jq -r 'select(.pid == <PID> and .event == "dashboard_snapshot_stage") | [.ts,.data.stage,.data.days,.data.elapsed_ms] | @tsv' \
  "$HOME/Library/Containers/<BUNDLE_ID>/Data/Library/Application Support/AIPulse/diagnostics/events-active.jsonl"

# 5. 数据库只读健康检查
sqlite3 "file:$HOME/Library/Containers/<BUNDLE_ID>/Data/Library/Application%20Support/AIPulse/aipulse.db?mode=ro" \
  'PRAGMA quick_check; SELECT (SELECT COUNT(*) FROM usage_event), (SELECT COUNT(*) FROM balance_snapshot);'
```

trace 导出与符号解析方法沿用性能文档 2026-09-23 22:00 一节的 `xctrace export` 命令；原始 trace 含本机路径，存 `artifacts/`（已 gitignore），不得提交。

## 判定门槛（全部满足 = 通过）

| # | 门槛 | 依据 |
|---|---|---|
| 1 | 相同数据与操作下，30 秒周期 CPU 时间的**中位数与 P95 较基线下降 ≥50%**（基线：约 80–163%、持续 8–10 秒） | 性能文档"建议验收门槛" |
| 2 | 五分钟轮次内 Today/Week/30 天**各最多构建一次**；30 天快照耗时不劣于 2026-09-23 修复后观察值（约 0.6–0.7 s）量级 | 文档第二轮与 22:41 观察 |
| 3 | 单个 5 秒 `top` 采样**不再重现 ≥50% 的短峰**（修复后观察 10–15%） | 文档 22:41 观察表 |
| 4 | 窗口关闭期间**没有**由数据变更触发的仪表盘快照构建；打开时只重建所选周期，画面为最新事实，错误/未知不显示为零 | 文档"建议验收门槛" |
| 5 | 30 天构建窗口的 `GitRepo.verifiedWorkingRoot` 采样占比不再主导（修复前 73%，修复后 7.7%） | 文档 22:41 trace 对比 |
| 6 | `PRAGMA quick_check` 为 ok；`usage_event` 与 `balance_snapshot` 行数不因迁移改变（步骤 5 前后对比） | 迁移可重复性与原始历史保留 |

## 记录模板

| 指标 | 基线（2026-09-23 修复前） | 本次 | 判定 |
| --- | ---: | ---: | --- |
| 启动首轮 30 天快照 | 2783.5 ms | | |
| 五分钟同步 30 天快照 | 2422.7 ms | | |
| Phase 4 各周期构建次数 | 各 1 次 | | |
| 5 秒采样峰值（Phase 4 附近） | 87.8% | | |
| 周期 CPU 中位数 / P95 | 80–163% × 8–10 s | | |
| `verifiedWorkingRoot` 窗口采样占比 | 3593/4924 (73%) | | |
| `quick_check` / 行数守恒 | ok / ok | | |

## 判定之后

- **通过**：把上表与原始工件路径补进性能文档"尚待端到端验收"一节，该项方可关闭；此后才允许在发布说明中表述 CPU 峰值修复。
- **不达标**：按性能文档既定边界处理——用本次 trace 定位新的调用栈后决定是否调整全源遍历频率或做 Phase 4 后台聚合，**不凭推测改代码**；把偏差数据与 trace 路径记入性能文档。
