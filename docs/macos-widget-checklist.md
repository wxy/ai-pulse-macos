# macOS 原生三环 Widget 验收

macOS 原生 Widget extension 位于 `AIPulse/AIPulseMacWidget`，target 为
`AIPulseMacWidgetExtension`，由 `AIPulse/AIPulse.xcodeproj` 中的实际 macOS 宿主
`AI Pulse` 嵌入。它与 macOS 可以从 iPhone 连续互通显示的 iPhone Widget 是两个独立来源。

## 数据与刷新

Widget 不访问 CloudKit，而是读取 Mac App 写入 App Group
`group.com.wxy.aipulse` 的版本化 JSON 快照：

- `todaySnapshot`：今日词元和代码行数。
- `historySnapshot`：最近 28 天已观测活跃日的中位数基线。
- `pulseEnvelope`：最后一次真实活动观测及其有效期。

Mac App 的五分钟后台周期先原子写入本机快照，再请求刷新 `AIPulseMacWidget`；CloudKit 写入成功
与否不影响本机 Widget。Mac App 关闭后不读取云端，也不生成新快照；最后一次真实观测按自身
`validUntil` 自然过期。跨日摘要不冒充今天，陈旧摘要降低外圈与中圈强调度。常规 timeline
每 15 分钟请求重读本地快照，并在活动过期、摘要变旧和跨日边界增加过渡 entry。点击 Widget
在快照仍新鲜时会立即重读共享快照。若 App Group 已超过 20 分钟没有新写入，Widget 保留
最后数据和写入时间，提示打开仪表盘；此时点击会启动 Mac App，而不是把旧文件冒充刷新结果。

## 工程与签名

- 宿主和 extension 最低版本均为 macOS 14，并且只构建 ARM64。
- Debug bundle ID 为 `xingyu.wang.aipulse.debug.widget`，Release 为
  `com.wxy.aipulse.macoswidget`；两者都以对应宿主 bundle ID 为前缀。Release 使用独立的
  `macoswidget` 后缀，避免与既有 iPhone Widget 的 `com.wxy.aipulse.Widget` 冲突。
- 宿主和 extension 使用同一 Team `YUUWV9L8M8`。
- 宿主和 extension 都启用 App Sandbox 与 App Group `group.com.wxy.aipulse`。
- extension 不包含 network client 或 CloudKit entitlement；CloudKit 只保留在宿主中，供
  iPhone 与 Watch 同步使用。
- 宿主 target 依赖 extension，并通过 `Embed Foundation Extensions` 把产物放到
  `AI Pulse.app/Contents/PlugIns/AIPulseMacWidgetExtension.appex`。

首次为新 bundle ID 签名时，普通 wildcard profile 可能不包含 App Group。使用 Xcode 自动签名，
让开发者账号为宿主和 extension 生成包含相同 App Group 的 profile。未签名构建只能验证编译，
不能用于判断 Widget 图库是否可发现或共享容器是否可读。

## 构建检查

```sh
xcodebuild \
  -project AIPulse/AIPulse.xcodeproj \
  -scheme AIPulse_macOS \
  -destination 'platform=macOS' \
  -configuration Debug \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/<existing-AIPulse-directory> \
  -disableAutomaticPackageResolution build
```

构建后检查：

1. 宿主的 `Contents/PlugIns` 中存在可执行的 `AIPulseMacWidgetExtension.appex`。
2. extension Info.plist 的扩展点为 `com.apple.widgetkit-extension`。
3. `codesign --verify --deep --strict` 对宿主通过。
4. 宿主和 extension 的 `TeamIdentifier` 相同，并都包含 `group.com.wxy.aipulse`；extension
   不包含 CloudKit 与 network client。
5. 宿主和 extension 的 Mach-O 架构均为 `arm64`。

## 图库发现

1. 安装或运行包含 extension 的签名 Mac App。只单独构建 extension、把 target 建在移动套件
   工程，或没有把 `.appex` 嵌入实际 Mac App，都不会形成可发现的本机 Widget。
2. 使用 `pluginkit -m -A -D -v -i <extension bundle id>` 检查系统插件数据库。
3. 打开 macOS Widget 图库，确认 AI Pulse 来自本机 Mac App，并可添加正方形小组件；不要把
  “使用 iPhone”下的 AI Pulse 当作原生扩展验收结果。原生条目显示为 `AI Pulse · Mac`，
  iPhone 条目仍显示为 `AI Pulse`。
4. 若新构建没有立即出现，先退出旧宿主、删除旧构建、重新运行签名宿主，再重开 Widget 图库。
   不要用缺少 App Group profile 的 ad-hoc 或未签名产物排查图库。命令行构建复用 Xcode 的
   固定 DerivedData 路径；不要为每次构建创建并注册新的临时签名产物。

## 功能验收

- 正常数据：外圈词元、中圈代码行、内圈当前强度，四角显示数量和相对平常倍数。
- 无本机快照与等待跨日刷新不转换为零；本地组成部分缺失时不展示用户无法处理的错误提示。
- 分别检查浅色、深色以及系统着色渲染；背景被系统移除时文字和三环仍可读。
- 摘要陈旧时只降低环和数值，辅助标签保持可读；活动到期后内圈变为未知。
- 中英文内容不裁切，VoiceOver 摘要包含今日词元、今日行数、当前强度和状态。
