# iPhone 2.0 验收

iPhone、iPhone 小组件、Watch 应用和 Watch 小组件均已迁移到 v2 数据模型。`AIPulse_iOS` 宿主包嵌入 iPhone Widget 与 Watch App，Watch App 再嵌入 Watch Widget；这些组件随同一个 iOS 归档上传，不需要分别提交安装包。

## 运行

打开 `Suites/AIPulse_Suites.xcodeproj`，选择 `AIPulse_iOS`。

- 普通启动：读取三个独立的 `snapshot-v2-*`，以及 `DashboardCache_v2/current-pulse`。签名真机需具备原容器 `iCloud.com.wxy.aipulse` 权限，两端使用同一 Apple 账户。Mac 签名构建（包括 Debug）可以写入 iCloud，未签名构建不连接云端。
- 模拟器支持 CloudKit。正常 Xcode / XcodeBuildMCP 签名构建会生成 CloudKit 权限；明确传入 `CODE_SIGNING_ALLOWED=NO` 的未签名预览包不构造容器。需在模拟器设置内登录与 Mac 相同的 Apple 账户，并确认 Development / Production 环境一致。无需限定从 Xcode 界面启动。
- 明确的 Debug 界面预览：在 Scheme → Run → Arguments 加入 `--iphone-preview`。顶部显示“预览数据”，不访问 CloudKit、不注册通知、不写摘要缓存；Release 不启用该参数。

## 外观与背景

iPhone 仪表盘跟随系统浅色与深色外观。根背景不是纯白或纯黑：浅色使用冷灰绿，深色使用
近黑绿，并叠加老式 Windows 屏保风格的多束变色贝塞尔轨迹。四束曲线各自使用四个独立移动
的锚点形成平滑闭环，并以多个完整闭环保留短尾迹，不会出现开放端点；浅色降低饱和度与
透明度，深色保留克制的霓虹感。曲线只属于 App 页面，不表示实际数据；App 进入后台或系统
开启“减少动态效果”时停止运动并保留静态构图。普通 App 窗口不能透明显示主屏幕壁纸，
因此不使用假透明背景。

Home Screen 小组件也跟随 iPhone 系统外观，但不运行持续背景动画。WidgetKit 以快照方式托管
小组件，并可能在 StandBy、tinted 或 vibrant 上下文移除或重着色容器背景；小组件通过
`containerBackground` 和 `widgetRenderingMode` 适配这些上下文。浅色使用冷灰绿底与深色文字，
深色使用近黑绿底与亮色文字。四角标签和中心辅助文字在深色背景上使用约 82% 白，不再因
缓存状态整体降到难以辨认；缓存状态只降低指标值和环的强调度，并保留 `Cached` 提示。

## 验收清单

- 今日 / 本周 / 30 天只切换历史统计，不改变当前强度；未观测和过期强度均不等同于平静。
- TOKENS / LINES 双圈、两列图例、三段鼻梁和双行节奏；本周邻周为灰色占位。
- 详情取代头部，只有返回；费用底座持续可见。
- 账户已观测支出按原币种展示，固定费用为声明的 USD 月费，两者不相加。
- 左右耳朵与设置页共用本机静音状态，不修改 Mac。
- 无摘要时提示先配置 Mac；授权通知由用户在设置页主动触发。
- 断网保持同范围缓存；拒绝旧版、错范围缓存，缺失值显示破折号。
- 在系统浅色、深色与“减少动态效果”下检查仪表盘；背景变化不得影响机器人面板内的文字和点击。
- 在 Home Screen 普通、tinted 与 StandBy 外观检查小组件；背景被移除时文字和三环仍需可读。

## 验证状态

最终自动化结果以根目录 `RELEASE_DRAFT.md` 为准。iOS Debug / Release 模拟器构建、范围切换、头部详情返回、静音与设置入口、不可用状态及亮色／暗色布局均已检查。机器人视觉按 macOS 结构等比适配，并针对手机可读性调整字体与底座高度。

已完成 Mac 写入 CloudKit、签名模拟器读取和真机验收。设置页展示手动同步进度、结果、完成时间、实际通知授权状态和系统设置入口。界面由 `Sources/Localizable.xcstrings` 提供 10 种完整本地化；`Tokens`、`Lines`、货币代码及明确指定的产品标识按产品约定保持稳定。

## 统一云端类型

四条记录统一写入 `DashboardCache_v2`，字段为 `json`（String）和 `updatedAt`（Date/Time）。Mac 的“检查并重试同步”负责写入三个统计范围与 `current-pulse`；iPhone 读取相同的类型和记录 ID。当前强度的 JSON 与历史摘要不同，独立校验有效期。

Mac 使用带 iCloud 权限的签名构建建立真实记录，Debug 与 Release 均可；未签名测试包不连接云端。在 Development 中首次成功保存可建立类型与字段；Production 需先部署 schema。两端需使用同一 Apple 账户和云端环境。当前强度名义上每 5 分钟发布；云端有效期为 22 分钟，由 5 分钟发布间隔、15 分钟 Widget 名义刷新间隔和 2 分钟传递余量组成。本地 60 秒有效期保持不变，发布端不会复活已经过期的本地观察。不要手动填入空 JSON 作为摘要，也不删除 v1 数据。若曾成功建立旧 `CurrentPulse_v2/current-pulse`，记录 ID 不允许换类型；需单独处理该未发布的旧记录，不能直接以新类型覆盖。
