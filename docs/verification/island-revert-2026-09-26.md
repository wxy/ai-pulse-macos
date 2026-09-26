# 撤销灵动岛入口：端到端检查

日期：2026-09-26。分支：`codex/revert-island-entry`。目标是恢复 `b05b90d` 时的菜单栏机器人入口，保留后续 Git 历史。

## 环境、输入与复现

- macOS arm64、Xcode 当前选中工具链；独立 Debug QA bundle ID `xingyu.wang.aipulse.runtimeqa`，禁用正常采集与账户轮询，使用独立数据目录。启动前确认同 bundle ID 的旧进程退出。
- 本次 QA bundle ID 曾保存过 `dashboard_entry_mode=island`；撤销后的版本应忽略旧键值，不显示中央胶囊。
- 从仓库根目录运行：

  ```sh
  xcodebuild -project AIPulse/AIPulse.xcodeproj -scheme AIPulse_macOS \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath /private/tmp/ai-pulse-island-revert-qa/DerivedData \
    PRODUCT_BUNDLE_IDENTIFIER=xingyu.wang.aipulse.runtimeqa \
    CODE_SIGNING_ALLOWED=NO build
  ```

- 启动 `DerivedData/Build/Products/Debug/AIPulseDebug.app`；使用 computer-use 读取仪表盘 AX，按 `⌘1` 打开普通仪表盘，按 `⌘,` 打开偏好设置通用页，保存窗口截图。

## 结果与工件

- Xcode 完整 Debug 构建成功，退出码 0。
- 四次撤销后的暂存源码与 `b05b90d` 逐文件一致；`rg` 在源码中找不到 `DashboardEntryMode`、`dashboard_entry_mode` 或“灵动岛风格”。
- QA 应用显示普通 [仪表盘截图](island-revert-dashboard-2026-09-26.png)；`⌘1` 后 AX 有今日、本周、30 天等原有控件，没有中央胶囊的展开按钮。
- [偏好设置截图](island-revert-settings-2026-09-26.png)与 AX 证明通用页不再包含仪表盘入口选择。QA 应用已退出。
- 截图是应用窗口，不包含系统菜单栏合成画面；本次没有独立捕获系统菜单栏机器人的视觉证据。主目录原有未提交文件不属于撤销范围。
