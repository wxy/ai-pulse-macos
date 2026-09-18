# iPhone 2.0 首版验收

本轮仅迁移 iPhone。旧 Watch / Widget 源码与 targets 保留；iPhone 暂不嵌入它们，因为其旧费用字段已不属于 v2 模型。验收后单独迁移并恢复嵌入。本分支保留了 #73 的提交：#73 合入的是 #72 的分支，尚未进入本轮起点 origin/main。

## 运行

打开 `Suites/AIPulse_Suites.xcodeproj`，选择 `AIPulse_iOS`。

- 普通启动：读取三个独立的 `snapshot-v2-*`，以及 `CurrentPulse_v2/current-pulse`。签名真机需具备原容器 `iCloud.com.wxy.aipulse` 权限，两端使用同一 Apple 账户。Mac Debug 不写入 iCloud。
- 模拟器支持 CloudKit。正常 Xcode / XcodeBuildMCP 签名构建会生成 CloudKit 权限；明确传入 `CODE_SIGNING_ALLOWED=NO` 的未签名预览包不构造容器。需在模拟器设置内登录与 Mac 相同的 Apple 账户，并确认 Development / Production 环境一致。无需限定从 Xcode 界面启动。
- 明确的 Debug 界面预览：在 Scheme → Run → Arguments 加入 `--iphone-preview`。顶部显示“预览数据”，不访问 CloudKit、不注册通知、不写摘要缓存；Release 不启用该参数。

## 验收清单

- 今日 / 本周 / 30 天只切换历史统计，不改变当前强度；未观测和过期强度均不等同于平静。
- TOKENS / LINES 双圈、两列图例、三段鼻梁和双行节奏；本周邻周为灰色占位。
- 详情取代头部，只有返回；费用底座持续可见。
- 账户已观测支出按原币种展示，固定费用为声明的 USD 月费，两者不相加。
- 左右耳朵与设置页共用本机静音状态，不修改 Mac。
- 无摘要时提示先配置 Mac；授权通知由用户在设置页主动触发。
- 断网保持同范围缓存；拒绝旧版、错范围缓存，缺失值显示破折号。

## 已验证与待验证

本地 Swift 测试 404 项、4 项跳过、0 失败；iOS Debug / Release 模拟器构建通过。机器人视觉已按 macOS 的 440×440 头部、57 高额头、统一四色圈图、梯形鼻梁、相向节奏图和 128 高分层底座等比适配。通过 XcodeBuildMCP 检查范围切换、头部详情返回、静音与设置入口，以及普通启动的不可用状态。亮色与暗色截图已检查。

尚未完成真实 Mac → CloudKit → iPhone 的签名设备往返、推送与通知声音验证。新界面目前提供简体 / 繁体中文与英文兜底；其他语言的新文案需要后续本地化补齐。旧已有错误 / 版本提示继续使用原有多语言字典。
