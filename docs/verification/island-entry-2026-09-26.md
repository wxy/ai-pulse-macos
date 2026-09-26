# 灵动岛风格入口：macOS 端到端检查

日期：2026-09-26。源码分支：`codex/island-entry`。检查对象是专用 Debug QA 应用，不是用户正在运行的正式应用。

## 环境与复现

- macOS arm64；Xcode 当前选中的工具链；项目 `AIPulse/AIPulse.xcodeproj`，scheme `AIPulse_macOS`。
- QA bundle ID：`xingyu.wang.aipulse.runtimeqa`。`RuntimeQA` 禁用正常采集、账户轮询和通知请求，使用独立数据目录。启动前确保同 bundle ID 的旧 QA 进程已经退出。
- 构建命令：

  ```sh
  xcodebuild -project AIPulse/AIPulse.xcodeproj -scheme AIPulse_macOS \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath /private/tmp/ai-pulse-island-qa-derived \
    PRODUCT_BUNDLE_IDENTIFIER=xingyu.wang.aipulse.runtimeqa \
    CODE_SIGNING_ALLOWED=NO build
  ```

- 启动产物：`/private/tmp/ai-pulse-island-qa-derived/Build/Products/Debug/AIPulseDebug.app`。在设置 → 通用 → 仪表盘入口选择“灵动岛风格”。界面操作使用 computer-use `sky.get_app_state`、`sky.click`、`sky.press_key`，每步重新读取 AX 树。
- 输入：QA 应用没有可报告的当前活动；本次没有授权目录、打开私人会话、执行真实采集或修改系统外观。

## 结果与工件

- 完整 Xcode Debug 构建成功，退出码 0。
- 选择灵动岛风格后，AX 显示“展开 AI Pulse 仪表盘”；收起时仅有胶囊，未知活动为灰色点及“当前活动不可用”提示。[收起截图](island-entry-collapsed-2026-09-26.png)。
- 点击胶囊后，AX 显示“收起 AI Pulse 仪表盘”及完整今日／本周／30 天仪表盘。[展开截图](island-entry-expanded-2026-09-26.png)。点击胶囊可再次收起。
- 右键胶囊可打开偏好设置、声音和退出菜单；偏好设置可以切回“菜单栏机器人”。切回后通过 `⌘1` 打开仪表盘，AX 与截图均确认窗口恢复完整尺寸。
- 退出并重启专用 QA 应用后，灵动岛风格设置保留，胶囊仍是初始收起状态。详情打开时第一次 Escape 返回主仪表盘，第二次 Escape 收起为胶囊。

本次截图来自当前系统暗色外观。没有在浅色外观、刘海屏／无刘海外接屏、全屏及菜单栏自动隐藏环境完成视觉验收；这些系统组合需要相应设备的实际检查。截图只覆盖 QA 应用窗口，不证明胶囊相对物理刘海的屏幕坐标。

尝试读取 SystemUIServer 菜单栏 AX 时返回 `timeoutReached`。因此回切后的机器人图标是否在系统菜单栏中显示，本轮未得到独立的界面证据；回切设置及仪表盘通过 `⌘1` 打开已实际验证。
