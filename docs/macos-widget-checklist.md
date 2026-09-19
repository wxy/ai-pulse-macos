# macOS 原生三环 Widget 验收

macOS 原生 Widget extension 位于 `AIPulse/AIPulseMacWidget`，target 为
`AIPulseMacWidgetExtension`，由 `AIPulse/AIPulse.xcodeproj` 中的实际 macOS 宿主
`AI Pulse` 嵌入。它与 macOS 可以从 iPhone 连续互通显示的 iPhone Widget 是两个独立来源。

## 数据与刷新

Widget 直接读取用户 iCloud 私有数据库中的三个 v2 记录，不依赖 iPhone App Group：

- `snapshot-v2-today`：今日词元和代码行数。
- `snapshot-v2-30d`：最近 28 天已观测活跃日的中位数基线。
- `current-pulse`：当前活动强度及有效期。

读取会分别处理成功、缺失和失败状态。跨日摘要不冒充今天，陈旧摘要降低外圈与中圈强调度，
过期活动不会继续显示为当前强度。常规 timeline 每 15 分钟请求刷新，并在活动过期、摘要变旧
和跨日边界增加过渡 entry。Mac App 成功写入 CloudKit 后也会请求刷新 `AIPulseMacWidget`。

## 工程与签名

- 宿主和 extension 最低版本均为 macOS 14，并且只构建 ARM64。
- Debug bundle ID 为 `xingyu.wang.aipulse.debug.widget`，Release 为
  `com.wxy.aipulse.macoswidget`；两者都以对应宿主 bundle ID 为前缀。Release 使用独立的
  `macoswidget` 后缀，避免与既有 iPhone Widget 的 `com.wxy.aipulse.Widget` 冲突。
- 宿主和 extension 使用同一 Team `YUUWV9L8M8`。
- extension 启用 App Sandbox、network client 和 CloudKit 容器
  `iCloud.com.wxy.aipulse`。
- 宿主 target 依赖 extension，并通过 `Embed Foundation Extensions` 把产物放到
  `AI Pulse.app/Contents/PlugIns/AIPulseMacWidgetExtension.appex`。

首次为新 bundle ID 签名时，普通 wildcard profile 不包含 CloudKit。使用 Xcode 自动签名，
或运行带 `-allowProvisioningUpdates` 的 `xcodebuild`，让开发者账号创建明确的 App ID 和包含
CloudKit 权限的 profile。未签名构建只能验证编译，不能用于判断 Widget 图库是否可发现。

## 构建检查

```sh
xcodebuild -allowProvisioningUpdates \
  -project AIPulse/AIPulse.xcodeproj \
  -scheme AIPulseMacWidgetExtension \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug build
```

构建后检查：

1. 宿主的 `Contents/PlugIns` 中存在可执行的 `AIPulseMacWidgetExtension.appex`。
2. extension Info.plist 的扩展点为 `com.apple.widgetkit-extension`。
3. `codesign --verify --deep --strict` 对宿主通过。
4. 宿主和 extension 的 `TeamIdentifier` 相同，extension 的签名权限包含 CloudKit 容器。
5. 宿主和 extension 的 Mach-O 架构均为 `arm64`。

## 图库发现

1. 安装或运行包含 extension 的签名 Mac App。只单独构建 extension、把 target 建在移动套件
   工程，或没有把 `.appex` 嵌入实际 Mac App，都不会形成可发现的本机 Widget。
2. 使用 `pluginkit -m -A -D -v -i <extension bundle id>` 检查系统插件数据库。
3. 打开 macOS Widget 图库，确认 AI Pulse 来自本机 Mac App，并可添加正方形小组件；不要把
   “使用 iPhone”下的 AI Pulse 当作原生扩展验收结果。
4. 若新构建没有立即出现，先退出旧宿主、删除旧构建、重新运行签名宿主，再重开 Widget 图库。
   不要用缺少 CloudKit profile 的 ad-hoc 或未签名产物排查图库。

## 功能验收

- 正常数据：外圈词元、中圈代码行、内圈当前强度，四角显示数量和相对平常倍数。
- 无账户、无数据、部分同步、同步失败、等待跨日刷新均显示独立状态，不转换为零。
- 分别检查浅色、深色以及系统着色渲染；背景被系统移除时文字和三环仍可读。
- 摘要陈旧时只降低环和数值，辅助标签保持可读；活动到期后内圈变为未知。
- 中英文内容不裁切，VoiceOver 摘要包含今日词元、今日行数、当前强度和状态。