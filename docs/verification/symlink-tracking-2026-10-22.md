# 符号链接跟踪验证 — 2026-10-22

## 行为与范围

主目录、开发目录及扫描范围内的子目录均跟随符号链接，包括相对链接和路径中连续出现的链接。日志按逻辑入口识别格式，按解析后的实际文件读取、去重和保存游标；仓库身份同样使用实际路径。通过开发目录中的链接可达的外部仓库可正常归属，外部相邻仓库不会因此自动纳入；移除链接后新的查询会撤销该归属。

保留 Git 扫描原有的四层深度、系统/依赖目录排除、发现仓库后停止向内扫描和软截止时间。日志仍只读取各集成规定的目录与格式，不扫描整个主目录。运行中的 Claude/Codex 通知源会在后续扫描时重新绑定已更换的目标；周期扫描仍是嵌套日志的补充入口。

## 方法与输入

环境：Apple Silicon macOS，Xcode 27.1 / 27A9275，arm64 SwiftPM 和 `AIPulse_macOS` Debug。测试先于本次实现加入，使用真实文件系统、临时 Git 仓库和生产 `LogWatcher` 扫描/解析/SQLite 游标路径；通过实例依赖注入隔离主目录、数据库和开发目录配置。没有替换正在运行的应用或打开用户数据库用于写入。

`Tests/SymlinkTrackingTests.swift` 在系统临时目录生成全部输入并通过 defer 清理，UserDefaults 使用独立域并清除。三个集成场景覆盖：

| 场景 | 断言 |
| --- | --- |
| 开发目录自身为链接，子目录通过相对链接指向外部 Git 仓库 | 缓存发现实际仓库、子目录 cwd 正确归属 |
| 多个目录入口、重叠配置目录指向同一仓库 | 仓库及总计仅一份 |
| 授权目录与链接入口、相似前缀路径和跳出授权目录的链接 | 按实际路径比较覆盖范围，外部目标仍需独立授权 |
| 循环、断链、隐藏目录、依赖目录与超出深度的链接 | 有限结束，既有排除规则保持 |
| 删除开发目录中的链接 | 外部仓库不再属于下一次查询；外部相邻仓库始终不纳入 |
| 主目录、Codex sessions、下级目录及单个日志文件为链接 | 实际日志导入一次，只有一个实际路径游标；回退时间来自目标文件 |
| 半行追加、补齐换行、再次扫描、重新创建扫描器 | 未完整记录不越过游标，补齐后入库，重启不重复 |
| sessions 换目标、断链后目标恢复、主目录链接换目标 | 新目标后续数据均进入同一隔离测试库 |
| Qwen/Gemini chats 指向不同名称的存储目录、文件链接指向 .txt 目标 | 依逻辑入口识别格式，按实际文件正确入库与去重 |

日志集成场景最终得到 7 条唯一用量记录。开发目录用真实 `git init`，既有实际仓库只读验证也已启用。首轮曾发现 Foundation 混用 `/var` 与 `/private/var` 导致重复路径，修复为逐项规范化后所有对应断言通过。

## 可复现命令与结果

在仓库根目录执行，构建产物均放入独立临时目录：

```sh
qa_dir=$(mktemp -d "${TMPDIR%/}/aipulse-symlinks.XXXXXX")
AIPULSE_QA_REPO_ROOT="$PWD" /usr/bin/arch -arm64 swift test --scratch-path "$qa_dir/swift-build"
xcodebuild -project AIPulse/AIPulse.xcodeproj -scheme AIPulse_macOS -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$qa_dir/DerivedData" -clonedSourcePackagesDirPath "$qa_dir/xcode-packages" CODE_SIGNING_ALLOWED=NO build -quiet
python3 scripts/check-localizations.py
git diff --check
rm -rf "$qa_dir"
```

- 完整 SwiftPM 测试：523 项，520 通过、3 按条件跳过、0 失败。CI 要求运行完整包测试，因此在专项验证后复用同一构建执行。
- 三个符号链接集成场景全部通过；真实所选仓库只读验证通过。授权路径比较与直接 aider 历史路径规范化的后续调整另运行受影响范围测试及增量编译：41 项、1 项按条件跳过、0 失败。最后补充链接文件回退时间断言并运行三个链接集成场景及增量编译。
- 跳过项目：需要 `AIPULSE_QA_CODEX_LOG`、`AIPULSE_QA_DSH_LOG`、`AIPULSE_QA_BASELINE` 的三项私有真实数据验证，本次没有提供这些输入。
- macOS Debug arm64 无签名编译通过。首次编译的两处未使用循环变量警告已改用 `_` 并通过增量编译确认。
- 本地化验证：767 个有效键、10 个语言区域、416 组内联文案，通过；`git diff --check` 通过。
- 测试宿主未初始化全局 UI 数据库，刷新通知会记录缓存失效的 AppDBError 0 警告；隔离采集数据库的断言均通过。这不构成完整 UI 验收。

## 未验证范围与留存

未启动签名商店版验证 App Sandbox、外置卷授权、文件选择器交互或系统通知事件的实时到达；链接目标仍须具备 OS 读取权限。未验证外置磁盘长时间断连/重挂载与长期扫描性能，未运行 iOS/watchOS 回归。上述本地结果不能代替这些验收。

只保留本报告与可复现的测试源码。生成日志、SQLite、输入目录、构建缓存与无签名应用产物均在本任务结束时删除，不进入 Git。
