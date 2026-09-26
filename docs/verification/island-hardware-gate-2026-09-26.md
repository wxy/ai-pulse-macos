# 无刘海屏灵动岛入口回退检查

日期：2026-09-26。分支：`codex/island-hardware-gate`。

## 环境、输入与复现

- macOS arm64；当前主屏幕为无刘海外接显示器。独立 Debug QA bundle ID：`xingyu.wang.aipulse.runtimeqa`；该应用禁用正常采集与账户轮询，不使用用户正式应用的数据目录。
- 此 QA bundle ID 先前已将 `dashboard_entry_mode` 设置为 `island`，用于复现旧偏好在无刘海屏上的回退。启动前确认同 bundle ID 的旧进程已退出。
- 从仓库根目录执行：

  ```sh
  xcodebuild -project AIPulse/AIPulse.xcodeproj -scheme AIPulse_macOS \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath /private/tmp/ai-pulse-island-gate-qa/DerivedData \
    PRODUCT_BUNDLE_IDENTIFIER=xingyu.wang.aipulse.runtimeqa \
    CODE_SIGNING_ALLOWED=NO build
  ```

- 启动 `DerivedData/Build/Products/Debug/AIPulseDebug.app`，使用 computer-use 打开偏好设置（`⌘,`），查看“通用 → 仪表盘入口”并展开选择菜单。

## 结果

- Xcode 构建成功，退出码 0。QA 应用启动后 AX 看到的是普通 560×640 仪表盘，没有收起态中央胶囊。
- [设置页截图](island-hardware-gate-settings-2026-09-26.png)与 AX 显示“当前屏幕没有摄像头缺口，使用菜单栏机器人以免遮挡其他图标”；入口选择为“菜单栏机器人”。展开选择菜单后只有这一项。
- QA 应用已退出。未改动正式应用的设置或进程。

## 验收边界

本次没有真实摄像头缺口屏的界面证据，也没有证明带缺口屏左右区域绝不覆盖系统图标。现有展开态仍是独立浮层；将仪表盘真正放进连续展开的黑色容器，需要单独设计并在有缺口设备上验收。当前修正只阻止已确认有问题的无刘海屏中央覆盖行为。
