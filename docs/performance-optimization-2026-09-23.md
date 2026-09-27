# macOS 周期性 CPU 峰值优化（2026-09-23）

## 范围与证据

本轮针对已安装 Release 版约每 30 秒出现的短时 CPU 峰值。基线观察到约 80–163% CPU、持续约 8–10 秒；采样栈显示日志扫描与仪表盘统计在同一 SQLite 串行队列上竞争。诊断事件记录到一个扫描周期内重复缓存失效、三个时间范围的快照重建。安装版数据库的只读统计为 111,558 条 usage_event、2,693 条 balance_snapshot。没有修改安装版或其数据库。

## 根因与实施顺序

1. **刷新扇出（已实施）**：日志每个文件批次都通知，隐藏的仪表盘仍保留 SwiftUI 树并重算 Today／Week／30d；30 秒脉冲外观事件又使菜单重跑全部统计查询。改为每次完整日志扫描通知一次，缓存失效完成后再通知 UI；隐藏窗口只标记数据过期，打开或切换周期时按需加载；脉冲外观只更新菜单标题。
2. **余额查询（已实施）**：旧查询逐行扫描余额表，并为每行运行“该提供商上一个样本”的相关子查询。改为先枚举提供商，再查各自的一个前驱样本，增加 `(provider_id, ts, id)` 复合索引。索引迁移为增量、可重复执行，不改变历史数据。
3. **重复扫描和写入（已实施）**：同一个周期两次递归发现 Git 仓库；Codex 追加日志重复读取已扫描前缀；每个文件都单独持久化检查点。现在仓库只由日志扫描器遍历，协调器负责权限范围修剪；Codex 元数据在进程内缓存；检查点按扫描批量提交；已成功入库且未改动的 OpenCode 消息文件跳过重新解析。

## 本轮验证

- 在原始数据的副本上运行旧查询和新查询，30 天窗口均返回 411 行，双向 `EXCEPT` 差异均为 0；副本 `PRAGMA integrity_check` 为 `ok`。
- 同一副本上、使用 `sqlite3 -batch` 输出重定向到空设备的三次查询级计时：旧查询 0.73／0.70／0.72 秒，新查询 0.01／0.01／0.01 秒。这个数字仅衡量该 SQL 查询，不是整机 CPU 或仪表盘端到端耗时。
- 隔离 DerivedData 中的 macOS arm64 Debug 与 Release 构建均通过（`xcodebuild -workspace AIPulse.xcworkspace -scheme AIPulse_macOS -configuration <Debug|Release> -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/aipulse-perf-dd -clonedSourcePackagesDirPath /private/tmp/aipulse-perf-packages -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build -quiet`，退出码均为 0）。运行前将已有 Xcode `SourcePackages` 复制到该临时包目录，避免受限网络重新解析依赖。构建没有安装或启动新应用。

复现查询比较：先通过 SQLite `.backup` 将用户数据库复制到临时路径；在副本中分别运行 `BalanceObservation.fetchBalanceDeltas` 修改前后的 SQL（30 天窗口 `sinceMs=1787500800000`，`beforeMs=1790155839934`），用 `/usr/bin/time -p sqlite3 -batch <copy> '<SQL>' >/dev/null` 测时，用双向 `EXCEPT` 比较结果。基线副本仅有单列 `ts`、`provider_id` 索引；新版本副本另外执行 `CREATE INDEX balance_snapshot_provider_ts_id ON balance_snapshot(provider_id,ts,id)`。原始日志和数据库副本不入库。

验证结束后已删除本轮两份含真实数据的临时数据库副本，以及约 1.4 GB 的隔离构建与包缓存；上述命令和测量结果保留于本文，临时工件须按前置条件重新生成。

## 尚待端到端验收

本轮只完成代码构建和数据库副本上的查询级验证；尚未用新版签名应用在同等数据、权限和 30 秒周期条件下重测 CPU，也未验证隐藏／重开仪表盘的实际画面。因此不能宣称 80–163% 的整机峰值已消失。发布前应使用隔离的测试身份和可重复生成的数据副本，记录测试命令、环境、输入、CPU 时间线、诊断事件、窗口截图，以及两次运行的结果；比较空闲、持续写入日志、窗口打开和关闭四种情形。不得把未签名构建或旧安装版当作新版运行验收。

建议验收门槛：相同数据与操作下，每 30 秒周期的 CPU 时间中位数及 P95 至少下降 50%；窗口关闭期间没有由数据变更触发的仪表盘快照构建，窗口打开时只重建选中周期；重新打开与切换周期后显示最新事实，错误／未知值不变成零；数据库完整性检查通过，原始 usage_event 与 balance_snapshot 行数不因迁移改变。若未达到门槛，再根据新版采样栈决定是否调整全源遍历频率或 Phase 4 的后台聚合，而不是继续凭推测改动。

## 第二轮：启动及五分钟同步（2026-09-23）

用户运行第一轮改动后的签名 Xcode Debug 版时，启动曾有较高 CPU；随后隐藏窗口下连续 121 秒的 13 次采样，最高瞬时值为 6.1%，累计 CPU 时间增加 2.56 秒（约占一个核心的 2.1%）。这个短窗口说明原先每 30 秒的显著峰值未再出现，但不能代表长期 P95。该 Debug 数据库当时有 93,411 条 usage_event、82 条 balance_snapshot，`PRAGMA quick_check` 为 `ok`，不是与旧 Release 完全同一数据集。

继续检查发现：启动扫描处理了 37 个 Codex 文件、解析 2,453 个事件；五分钟 Phase 4 日志中，同一轮出现 30 天快照构建两次（分别约 3.19 秒、5.24 秒）。直接原因是新增 usage event 清除了三个缓存；本地 Widget 发布先在缓存未命中时构建 30 天快照，紧接着 CloudKit 同步又独立构建一次。仪表盘首次出现时还可能在初始扫描未结束前发起额外同步。

本轮改动：CloudSyncService 在一次调用中解析 Today 与 30 天快照并同时交给本地 Widget 和 CloudKit；并发 CloudKit 同步在计算前就被排除；启动同步先等候已经排队的日志扫描（包括扫描器的第二次队列跳转），但不额外遍历文件。Phase 4 同样先等候扫描结束；仪表盘首次加载不再单独发起云同步，自动发布仍由启动后约 20 秒的 Phase 4 承担。手动刷新及设置页的显式同步保留。

编译验证：在独立目录运行 `xcodebuild -workspace AIPulse.xcworkspace -scheme AIPulse_macOS -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/aipulse-sync-dd -clonedSourcePackagesDirPath /private/tmp/aipulse-sync-packages -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build -quiet`，退出码为 0；Release 用相同参数并替换 `-configuration Release`，退出码也为 0。隔离包缓存来自现有 Xcode SourcePackages；没有安装或启动新构建，也没有接触当前运行的签名版或其数据库。

验收仍需用新签名构建重复五分钟以上的运行观察：记录一次 Phase 4 内 `StatsService` 各周期构建次数、CPU 时间线、本地 Widget 发布时间、CloudKit 状态，以及启动和窗口开关时的数据新鲜度。预期是一次同步内 30 天最多构建一次；具体 CPU 降幅尚未测得。运行端到端测试时，按上文要求留下可再生成的日志／采样工件与完整前置条件。

## 新版运行观察工件（2026-09-23 21:33–21:40 CST）

前置条件和输入：用户自行重新构建并启动签名的 Xcode Debug 版；本次只读观察其 PID 49246（启动于 21:33:22），可执行文件位于 Xcode `DerivedData/.../Debug/AIPulseDebug.app`，文件修改时间 21:33:21，Bundle ID 为 `xingyu.wang.aipulse.debug`，Team ID 为 `YUUWV9L8M8`，`CloudKitAccessEnabled=YES`。观察期间未操作窗口，未更改数据库或当前应用。开始时数据库有 93,637 条 usage_event、82 条 balance_snapshot；结束时为 93,667／82，`PRAGMA quick_check=ok`。这是 Debug 版、持续写入的实时数据，不是旧 Release 的同数据集受控对照。

可重复生成的只读命令：

```sh
ps -axo pid,ppid,lstart,etime,%cpu,cputime,rss,comm | rg 'AIPulseDebug|PID'
top -l 68 -s 5 -pid 49246 -stats pid,cpu,time,mem
jq -r 'select(.pid == 49246 and .event == "dashboard_snapshot_stage" and .data.stage == "total") | [.ts,.data.days,.data.elapsed_ms] | @tsv' "$HOME/Library/Containers/xingyu.wang.aipulse.debug/Data/Library/Application Support/AIPulse/diagnostics/events-active.jsonl"
sqlite3 "file:$HOME/Library/Containers/xingyu.wang.aipulse.debug/Data/Library/Application%20Support/AIPulseDebug/aipulse.db?mode=ro" 'PRAGMA quick_check; SELECT (SELECT COUNT(*) FROM usage_event), (SELECT COUNT(*) FROM balance_snapshot);'
```

重测时先用 `ps` 确定当次 PID，并在 `jq` 条件和 `top -pid` 中同时替换；诊断 journal 可能轮转，需在轮转前读取当前 segment，或读取相应压缩归档。原始 `top` 输出含全机负载等无关信息，以下保留与本应用有关的可复核结果：

| 时段 | 进程 CPU 与快照结果 |
| --- | --- |
| 启动首轮 21:33:45–21:33:50 | Today 75.6 ms、30 天 2783.5 ms、Week（已过 3 天）190.0 ms，各构建一次；Widget 发布，CloudKit 三个周期和 current pulse 均成功。 |
| 稳态 21:34:38–21:38:44 | 进程累计 CPU 约从 9.06 秒增至 13.96 秒，246 秒内增加 4.90 秒（约一个核心的 2.0%）；5 秒采样多数接近零，30 秒扫描附近可见约 8–13% 短峰。期间没有新的仪表盘快照构建。 |
| 五分钟轮次 21:38:45–21:38:50 | Today 89.2 ms，30 天 2385.0 ms，Week 152.0 ms，各构建一次；21:38:49 单个 5 秒 `top` 采样为 87.8%，累计 CPU 从 21:38:44 的 13.96 秒到 21:38:54 的 18.55 秒增加 4.59 秒；Widget 和 CloudKit 同步成功。 |
| 结束 21:40:21 | 进程仍运行，累计 CPU 19.99 秒，内存约 228 MiB；本窗口内没有看到 CloudSync、Widget 写入或统计快照失败日志。 |

结论边界：第二轮优化把一次同步中重复的 30 天构建消除，但没有消除五分钟轮次的 CPU 峰值。该轮 Today 缓存命中，30 天和 Week 缓存未命中；30 秒数据变更会清除全部周期缓存，因此 Phase 4 对 Week/30 天的长间隔限制没有阻止随后 CloudSync 在未命中时重算。当前剩余峰值与完整 30 天快照构建在时间上吻合，但未取得该峰值的 Time Profiler 调用栈，不能把 87.8% 全部精确归因于某个 SQL 或函数。也未验证仪表盘打开、关闭、切换周期时的画面与新鲜度；旧 Release 与新 Debug 的数据、构建和操作不相同，不能给出可信的总体降幅百分比。

## 五分钟峰值调用栈定位（2026-09-23 22:00–22:05 CST）

此节补足上节尚缺的调用栈证据；分析为只读，未启动旧 Release，也未修改当前应用或数据库。环境：macOS 26.6.2、Xcode/Instruments 27.0、签名 Xcode Debug v2.0.0/32，附加既有 PID 49246。用 `xcrun xctrace record --template 'Time Profiler' --attach 49246 --time-limit 5m --output /private/tmp/aipulse-time-profiler-20260923-2200.trace --no-prompt` 采集 22:00:55.686–22:05:56.654 的 300.97 秒 trace；随后运行 `xcrun xctrace export /private/tmp/aipulse-time-profiler-20260923-2200.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output /private/tmp/aipulse-time-profile-20260923-2200.xml`。20 MB 原始 trace 已另存为 `artifacts/aipulse-time-profiler-2026-09-23-2200.trace`（含本机路径等私有运行信息，不应直接提交或公开）。重测须先确认当前 PID，再替换命令中的 PID 与唯一输出路径；保持仪表盘状态和数据输入一致，至少覆盖下一次 Phase 4。XML 中 sample-time 为相对采样开始的纳秒；按栈中 frame ID／ref 解析符号，在 170.19–172.62 秒筛选 30 天构建窗口。

同一轮诊断 journal 显示：Today 111.1 ms、30 天 2422.7 ms、Week 183.9 ms，各构建一次；Widget 与 CloudKit 发布成功。30 天窗口有 4,924 个运行线程的 1 ms Time Profiler 采样（并发线程样本数可大于 2.42 秒墙钟时间）。其中 4,284 个（87.0%）的调用栈包含 `RepositoryScope`；3,593 个（73.0%）包含 `GitRepo.verifiedWorkingRoot`；只有 219 个（4.4%）包含 `sqlite3`。按“最靠近栈顶的本应用函数”归类，`GitRepo.verifiedWorkingRoot` 3,166 个、`RepositoryScope.canonicalPath` 839 个；栈顶系统函数主要是 `stat`、`access`、`open`、`lstat` 和 libgit2 哈希／配置处理。百分比是这一时间窗的采样占比，不是全应用长期 CPU 占比。

代码路径与采样吻合：`StatsService.buildDashboardSnapshot` 并发请求日趋势、代码变化、仓库代码、仓库提交；其中 `authorizedCodeChanges` 被调用三次，`authorizedCommits` 两次。两者读取行后逐行调用 `RepositoryScope.authorizedGitRoot`，后者每行做路径规范化、逐层检查 `.git`，再调用 `GitRepo.verifiedWorkingRoot` 打开并释放 libgit2 仓库。观察时 Debug 数据库近 30 天约有 781 条非合并 `code_change`（12 个不同仓库路径）和 1,030 条 `git_commit`（10 个不同仓库路径）；单个快照据此可能触发约 4,400 次逐行授权验证，数量级是推算而非直接计数。瓶颈不是“大量不同仓库”，而是同一批仓库被重复验证。五分钟 trace 全程另有约 2,079 个 `LogWatcher` 样本，分布在多次 30 秒扫描；这是次要、相对分散的成本。

优先修复建议：让一次快照中每个规范化仓库路径只验证一次，再将授权结果应用于该路径的所有行；同时复用已读取的授权代码／提交记录，避免同一快照在多个统计分支重复查询和验证。缓存生命周期应限于单次快照或显式绑定目录权限、路径、Git 根状态的版本，不能持久化“曾获授权”而绕过用户改动授权目录、仓库移走、符号链接变化或工作树变化。保持代码行数、提交去重、合并提交、时区日界与不可访问仓库的既有语义；在隔离的数据副本上对比旧／新快照，再用相同运行条件重新采样五分钟峰值。此节仅完成定位，尚未实现或验证该修复。

## 仓库授权热点修复（2026-09-23）

这次实现采取比上节完整建议更小的边界：`StatsService.authorizedCodeChanges` 与 `authorizedCommits` 各自持有一个仅覆盖本次读取的 `RepositoryScope.AuthorizedRootLookup`。同一原始路径的授权成功或失败只解析一次；函数返回后即丢弃，下次快照会根据当时配置和文件系统重新验证。未持久化授权结果，也未改动原始数据、SQL 的时间边界、行顺序或统计归并。跨统计分支的 SQL 读取暂未合并，因为前次 Time Profiler 中 SQLite 栈只占 30 天峰值窗口采样的约 4.4%；先解决确认的 Git 验证热点，再以新 trace 决定是否继续。

观察时约有 781 条近 30 天非合并代码变更、1,030 条提交，分别只有 12／10 个不同仓库路径。以快照内三次 `authorizedCodeChanges`、两次 `authorizedCommits` 推算，单轮 Git 根验证次数上限从约 `3×781 + 2×1030 = 4403` 缩为约 `3×12 + 2×10 = 56`，约减少 98.7%。这是基于行数与代码调用路径的**次数估算**，不是实测 CPU 降幅；路径内容或时间窗口变化会改变该数字。

测试边界：真实应用端到端运行无法可靠触发授权目录变更、Git 仓库移走和符号链接改指向而不触碰用户仓库，因此先对短生命周期查找器写隔离回归测试，再写实现。事先列出的失败方式为：有效路径重复解析、无效／未授权路径误复用、不同路径被合并、跨读取沿用旧授权、行顺序／数量或提交去重改变。新测试覆盖成功／失败各只解析一次、不同路径隔离、不同读取重新检查；现有 `RepositoryScopeTests` 覆盖真实 Git 根、无效 `.git`、linked worktree 和目录边界，`SessionRepositoryScopeTests` 与 `StatsServiceTests` 覆盖会话归属和统计聚合。测试没有直接证明新版签名应用的 CPU 降幅。

验证结果：使用本机 Xcode `SourcePackages` 中已固定在 `b83108d10f42680d78f23fe4d4d80fc88dab3212` 的 GRDB checkout/bare repository，复制到独立的 `/private/tmp/aipulse-repo-lookup-scratch` 后，分别运行以下命令（后两次仅把 `--filter` 改为 `RepositoryScopeTests`、`StatsServiceTests`）：

```sh
swift test --scratch-path /private/tmp/aipulse-repo-lookup-scratch --cache-path /private/tmp/aipulse-repo-lookup-cache --disable-automatic-resolution --filter RepositoryAuthorizationLookupTests -Xcc -I/Users/xingyuwang/develop/ai-pulse-macos/Libraries/libgit2/include
```

结果依次为 3／8／6 项通过、0 失败。另以 `xcodebuild -workspace AIPulse.xcworkspace -scheme AIPulse_macOS -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/aipulse-repo-lookup-dd -clonedSourcePackagesDirPath /private/tmp/aipulse-repo-lookup-xcode-packages -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build -quiet` 构建，并替换 `-configuration Release` 复核；退出码均为 0。构建位于独立 DerivedData，未安装、启动或替换当前签名 Debug 版。

运行验收仍待新版签名构建：用同类活跃数据覆盖至少一次五分钟 Phase 4，保留进程 CPU 时间线、Time Profiler trace、`dashboard_snapshot_stage` 诊断及 Dashboard/Widget 的数据新鲜度检查。重点比较 30 天快照耗时和 `RepositoryScope`／`GitRepo.verifiedWorkingRoot` 的采样占比，并检查授权目录撤销后历史仓库记录不再展示。不能把本轮编译与隔离测试通过表述为运行峰值已消失。

## 仓库授权修复后的运行观察（2026-09-23 22:41–22:50 CST）

前置条件与输入：用户自行重新构建、签名并运行 Xcode Debug 版，观察现有 PID 64083；进程和可执行文件均于 22:41:30 启动／更新，Bundle ID 为 `xingyu.wang.aipulse.debug`。未启动旧 Release、未重启当前应用、未操作窗口或修改数据库。开始时只读数据库有 93,804 条 `usage_event`、82 条 `balance_snapshot`，结束时为 93,832／82，`PRAGMA quick_check=ok`。同为 Debug 版且数据仍在增长，和前次采样接近但不是严格相同输入的受控 A/B。

用 `top -l 65 -s 5 -pid 64083 -stats pid,cpu,time,mem` 记录 22:43:25–22:48:52 的进程时间线；用 `xcrun xctrace record --template 'Time Profiler' --attach 64083 --time-limit 5m --output /private/tmp/aipulse-time-profiler-20260923-2243.trace --no-prompt` 记录 22:43:19.293–22:48:20.237 的 300.94 秒调用栈。原始 19 MB trace 保存在 `artifacts/aipulse-time-profiler-2026-09-23-2243.trace`（含本机路径，不应提交或公开）。导出命令：

```sh
xcrun xctrace export /private/tmp/aipulse-time-profiler-20260923-2243.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output /private/tmp/aipulse-time-profile-20260923-2243.xml
jq -r 'select(.pid == 64083 and .event == "dashboard_snapshot_stage") | [.ts,.data.stage,.data.days,.data.elapsed_ms] | @tsv' "$HOME/Library/Containers/xingyu.wang.aipulse.debug/Data/Library/Application Support/AIPulse/diagnostics/events-active.jsonl"
sqlite3 "file:$HOME/Library/Containers/xingyu.wang.aipulse.debug/Data/Library/Application%20Support/AIPulseDebug/aipulse.db?mode=ro" 'PRAGMA quick_check; SELECT (SELECT COUNT(*) FROM usage_event), (SELECT COUNT(*) FROM balance_snapshot);'
```

复测时先用 `ps` 确认当次 PID，替换命令中的 PID、trace 输出路径和诊断日志过滤值；保持相同窗口状态并至少覆盖下一次五分钟同步。统计 trace 时，以采样开始为零点，将每行 `sample-time` 纳秒转换为秒，并按 `frame id/ref` 解析调用栈；本次 30 天窗口采用 214.9–215.8 秒。

| 指标 | 修复前观察 | 本次观察 |
| --- | ---: | ---: |
| 启动首轮 30 天快照 | 2783.5 ms | 667.6 ms |
| 五分钟同步 30 天快照 | 2422.7 ms | 613.8 ms |
| 五分钟同步附近单个 5 秒 `top` 峰值 | 87.8% | 14.3% |
| 五分钟同步附近约 10–11 秒累计 CPU 时间增量 | 4.59 秒 | 0.92 秒 |
| 30 天构建窗口 `GitRepo.verifiedWorkingRoot` 运行线程采样 | 3593／4924 | 57／737 |
| 30 天构建窗口 `sqlite3` 运行线程采样 | 219／4924 | 247／737 |

本次五分钟轮次 Today 48.0 ms、Week 98.1 ms，三个周期各构建一次。启动后的普通 30 秒扫描仍有约 10–12% 的单次短峰；五分钟同步附近最高 14.3%，未重现先前 87.8% 峰值。`top` 观察全段 CPU 时间从 5.19 秒增至 12.10 秒，约 327 秒增加 6.91 秒；采样期间附加了 Time Profiler。应用在采样后仍运行。上述前后对比是两次真实运行的观察值，不应外推为长期 P95 或精确总体降幅；没有验证 Dashboard／Widget 画面新鲜度、授权撤销行为或 Release 性能。

这次目标热点已显著缩小；当前 trace 中 SQLite 相对占比上升，但 30 天快照约 0.61 秒，尚无证据值得马上进行更复杂的跨分支 SQL 合并。下一步可在日常使用中继续收集多个五分钟轮次；只有当峰值或交互卡顿再次可复现时，才针对新的调用栈继续优化。
