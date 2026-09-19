# watchOS 表盘小组件验收清单

维护中的实现位于 `Suites/AIPulseWatchWidget/AIPulseWatchWidget.swift`，扩展 target 为
`AIPulseWatchWidgetExtension`，由 `AIPulse_watchOS` 嵌入。

## 数据契约

小组件直接读取用户 iCloud 私有数据库中的 `DashboardCache_v2`，不依赖 Watch App
处于前台，也不使用 iPhone App Group：

- `snapshot-v2-today`：今日词元与代码行数。
- `snapshot-v2-30d`：最近 28 天已观测活跃日的中位数基线。
- `current-pulse`：独立的当前 AI 活动强度及有效期。

三个记录分别容错。缺失和读取失败不会被转换成零；未知指标显示灰圈和 `N/A`。
摘要超过 15 分钟后降低外圈与中圈强调度。当前活动到期后保留最后一次强度、观测时间和
环形位置，同时降低强调度，避免把最后一次真实观测误写成“没有数据”。

## 图库条目与表盘槽位

扩展提供四个按内容命名的图库条目，而不是让一个通用 `AI Pulse` 条目在不同槽位中
改变含义：

| 图库条目 | Family | 展示内容 |
|---|---|---|
| AI Pulse · 三环总览 | Circular | 纯三环，不在内圈叠加机器人 |
| AI Pulse · 三环总览 | Rectangular | 左侧全高三环，右侧显示今日词元和今日行数 |
| AI Pulse · 活动强度 | Circular | 居中的状态机器人 |
| AI Pulse · 活动强度 | Rectangular | 左右等宽铺满：左侧状态机器人，右侧显示强度档位和观测时间或状态 |
| AI Pulse · 活动强度 | Corner | 表盘弧形 gauge 显示当前强度，状态机器人随角落方向旋转 |
| AI Pulse · 活动强度 | Inline | 仅显示紧凑状态机器人 |
| AI Pulse · 今日词元 | Corner | 中心显示紧凑词元数，外弧显示相对平常的比例 |
| AI Pulse · 今日词元 | Inline | 单行显示 `Tokens 2.4M` |
| AI Pulse · 今日行数 | Corner | 中心显示紧凑行数，外弧显示相对平常的比例 |
| AI Pulse · 今日行数 | Inline | 单行显示 `Lines 900` |

两个 Rectangular 变体都使用左右等宽栏位铺满可用区域。Corner 主内容通过
`widgetCurvesContent()` 交给系统按所在角落调整方向；词元和行数文字以及活动机器人均应
与表盘角度一致。Corner 和 Inline 的活动机器人使用扩展内置的模板矢量资产，避免 accessory
槽位丢弃运行时生成的图片；Inline 不附加文字。

外圈为深红词元环，中圈为马尔斯绿代码行数环，内圈为深黄当前活动环。系统的
vibrant/tinted 渲染可能统一着色，因此机器人同时使用平直、微笑和大笑三种嘴型表达状态组。
全彩模式下，未知为系统灰；平静/活跃分别使用深绿/亮绿；升高/强烈分别使用深红/亮红。

## 工程能力

- Watch App 和 Widget extension 都启用 CloudKit 容器 `iCloud.com.wxy.aipulse`。
- Widget extension 链接 `AIPulseShared`。
- Widget extension 的最低系统版本与 Watch App 一致，均为 watchOS 10.0。
- `AIPulse_watchOS.app/PlugIns/AIPulseWatchWidgetExtension.appex` 必须存在。

## 构建检查

```sh
xcodebuild -project Suites/AIPulse_Suites.xcodeproj \
  -scheme AIPulseWatchWidgetExtension \
  -destination 'generic/platform=watchOS Simulator' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

xcodebuild -project Suites/AIPulse_Suites.xcodeproj \
  -scheme AIPulse_watchOS \
  -destination 'generic/platform=watchOS Simulator' \
  -configuration Release build CODE_SIGNING_ALLOWED=NO
```

构建宿主后检查：

1. Watch App 包内存在 Widget `.appex`。
2. Watch App 与 Widget 均包含正确的 CloudKit entitlement。
3. Widget `MinimumOSVersion` 为 `10.0`。

## 模拟器与真机

1. 在表盘编辑器中确认四个条目名称均包含具体指标，并且只提供表中声明的 family。
2. 检查正常、无数据、摘要陈旧、pulse 过期四种状态。
3. 分别检查全彩、vibrant/tinted 表盘，文字不得依赖固定黑色背景。
4. 等待 pulse `validUntil` 和摘要 15 分钟边界，确认无需重新打开 Watch App 即可降低相应数据的强调度，并继续显示最后观测时间。
5. 真机需使用与 Mac 写入端相同的 Apple 账户，并确认三个 v2 记录均已写入私有库。
6. 在 40mm 与 46mm 的直线、曲线 Inline 槽位检查活动机器人、`Tokens 2.4M`、
  `Lines 900`、`Tokens 999.9M`、`Lines 999.9K` 和 `N/A` 状态均不裁切。
7. 在四个角落分别检查机器人、词元和行数主内容均跟随角落方向，且不与 gauge 标签碰撞。

以上模拟器与真机项目均已完成验收；该清单继续作为后续回归基线。

## 常见问题

| 症状 | 检查项 |
|---|---|
| 图库中没有四个 AI Pulse 条目 | 宿主包是否嵌入 `.appex`，扩展与宿主最低系统版本是否兼容 |
| 全部显示 `N/A` | iCloud 登录状态、容器 ID、三个 v2 记录与 payload version |
| 外圈或中圈为灰色 | 对应读取失败，或 30 天活跃样本不足 7 天 |
| 内圈变灰 | `current-pulse` 缺失或活动 signal 不可用；过期但存在的观察应保留并降低强调度 |
| 数据长时间不更新 | macOS 写入端是否运行，以及 WidgetKit 是否授予刷新预算 |
