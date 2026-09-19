# iPhone 三环小组件验收

本轮只迁移 iPhone 主屏幕正方形小组件（`systemSmall`）。中号、长方形与锁屏小组件暂不提供。

## 三环语义

- 外圈深红：今日词元，相对最近 28 天已观测活跃日中位数。
- 中圈马尔斯绿：今日代码新增与删除行数之和，使用相同的个人参照算法。
- 内圈深黄：当前 AI 活动强度；达到高强度边界时满圈。
- 词元和行数超过一圈后，淡色满圈表示已达到参照，亮弧表示下一圈位置；四角显示准确倍数。
- 未知数据使用灰圈和 `N/A`，不解释为零。当前观测缺失与观测过期分别显示。

这套表达与 Apple Watch 首页一致。参照不是额度、目标或效率评价。

## 数据与刷新

小组件不直接访问 CloudKit，而是读取 iPhone App 写入 App Group `group.com.wxy.aipulse` 的两个文件：

- `dashboard_cache.json`：`today` 和 `30d` 历史摘要。
- `current_pulse_v2.json`：独立的当前活动 envelope。

Provider 只接受 `DashboardCache_v2` 的 `2.0.0` 载荷和正确范围。跨日的 `today` 缓存不再显示为今天；超过 15 分钟的同日摘要以降低透明度保留，并标记缓存时间。

常规 timeline 每 15 分钟请求一次。有效当前观测会在 `validUntil` 后追加一条 timeline entry，即使没有新上传也会自动切换为“观测已过期”。iPhone 每次写入摘要或当前观测后会合并触发 WidgetKit reload。

## Xcode 预览

打开 `Suites/AIPulseWidget/AIPulseWidget.swift`，使用文件底部的 `#Preview(as: .systemSmall)` 查看带完整三环数据的预览。

## 模拟器验收

1. 打开 `Suites/AIPulse_Suites.xcodeproj`，选择 `AIPulse_iOS` scheme 和 iPhone 模拟器。
2. 构建并运行 iPhone App，确保生成的 App 包含 `PlugIns/AIPulseWidgetExtension.appex`。
3. 在主屏幕添加 AI Pulse；选择器应只提供正方形尺寸。
4. 检查四角事实、三环和中心文字没有接触或重叠。
5. 回到 iPhone App 手动同步后，再检查 Widget 是否显示今日词元、今日行数和当前强度。
6. 停止 Mac 上传并等待当前观测失效，确认内圈变为未知灰圈且中心显示观测已过期。
7. 分别检查简体中文和英文，以及系统浅色和深色外观；Widget 保持与 Watch 一致的黑色表盘。

无摘要时显示“暂无数据”，不声称同步失败，因为 Widget 无法区分首次未共享与一次读取失败。
