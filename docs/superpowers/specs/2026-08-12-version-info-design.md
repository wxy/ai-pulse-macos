# 版本信息显示（Version Info Display）设计

日期：2026-08-12
分支：`codex/version-info`

## 背景与目标

应用即将修改 CloudKit 数据/载荷结构，需要先在界面上把载荷版本号暴露出来，方便后续核对版本。本次只做**展示**，不修改任何数据结构。

目标：

1. macOS 仪表盘最下方显示数据库（CloudKit 载荷）版本号。
2. macOS 设置-关于页显示软件版本号与数据库版本号。
3. iOS 仪表盘三个时间范围页面的底部显示数据库版本号（与各页面独立的"更新于…"时间放在一起）。
4. iOS 检测到载荷版本不匹配时，同时提示"当前支持的版本号"与"CloudKit 提供的版本号"。

## 数据来源

复用两端现有的 `CKSchema.payloadVersion` 常量：

- macOS：`Sources/Sync/CloudKitSchema.swift`，值为 `"1.2.4"`。
- iOS：`Suites/Shared/Models/CloudKitSchema.swift`，值为 `"1.2.4"`。

`payloadVersion` **保持 `1.2.4` 不变**（本次未修改 DashboardSnapshot JSON 结构，符合"仅结构变化才 bump"的既有约定）。

应用软件版本号 `1.2.5`、构建号 `27` 已在两个 Xcode 项目中更新完毕（AIPulse.xcodeproj 与 AIPulse_Suites.xcodeproj），不在本次改动范围内。

## 改动点

### 1. macOS 仪表盘底部（`Sources/UI/Dashboard/DashboardView.swift`）

在仪表盘底部 footer（`lastUpdatedFooter` 所在区域）增加一行小字：

```
CloudKit 1.2.4
```

- 样式：`font(.caption2)`、`foregroundColor(.secondary)`，与现有"更新于…"一致。
- 文案：`"CloudKit " + CKSchema.payloadVersion`，"CloudKit" 为专有名词，不做多语言翻译。
- 只显示数据库版本号，不显示软件版本号（软件版本只在关于页显示）。

### 2. macOS 设置-关于页（`Sources/UI/Settings/SettingsView.swift` 的 `AboutTab`）

在现有 `v1.2.5 (27)` 文本下方增加一行：

```
CloudKit 1.2.4
```

同样为 `caption`/`secondary` 小字风格。软件版本号已有，不动。

### 3. iOS 仪表盘底部（`Suites/iOS/UI/DashboardView.swift`）

在底部"更新于…"（`cloudData.lastUpdated`）同一区域增加 `CloudKit 1.2.4`。

- 更新时间本身已随时间范围（today/week/30d）切换而变化；版本号是常量，与它放在一起后三个页面都会显示。
- 样式与现有 `caption2`/`secondary` 一致。

### 4. iOS 版本不匹配提示（`Suites/iOS/UI/VersionMismatchView.swift`）

现有页面在 `state == .needsUpgrade` 时展示，目前只显示 CloudKit 提供的版本（`version.mismatch.payload`，即"载荷版本 %@"）。

改为同时显示：

```
当前支持版本：1.2.4（CKSchema.payloadVersion）
CloudKit 提供版本：<recordVersion>
```

具体 UI：保留现有结构，将"载荷版本 %@"一行扩展为**两行小字**：

1. `当前支持版本：1.2.4`
2. `CloudKit 提供版本：<recordVersion>`

标签文案新增 I18n key：

- `version.mismatch.supported`（"当前支持版本 %@" / 对应各语言）
- 云端版本复用现有 `version.mismatch.payload`（"载荷版本 %@"）

I18n 需要在 `Suites/Shared/I18n/I18n.swift` 的全部 10 种语言（en / zh-Hans / zh-Hant-TW / zh-Hant-HK / ja / ko / de / fr / es / pt-BR）中补齐。

## 不做的内容（YAGNI）

- 不新增独立的"数据库版本"常量或本地 SQLite 版本机制。
- 不 bump `payloadVersion`。
- 不修改 DashboardSnapshot JSON 结构或 CloudKit 记录格式。
- 不修改 macOS 本地 GRDB 数据库 schema。
- 不改动现有"更新于…"时间显示。

## 验证

1. macOS：`xcodebuild -project AIPulse/AIPulse.xcodeproj -scheme AIPulse_macOS -configuration Debug build`，确认编译通过、无新增警告。
2. iOS：`xcodebuild -project Suites/AIPulse_Suites.xcodeproj -scheme AIPulse_Suites -destination 'platform=iOS Simulator' build`（CODE_SIGNING_ALLOWED=NO），确认编译通过。
3. 手动检查：macOS 仪表盘底部与关于页出现 `CloudKit 1.2.4`；iOS 三个时间范围页面底部出现 `CloudKit 1.2.4`；构造版本不匹配时提示页同时显示两个版本号。

## 风险与说明

- iOS 的版本不匹配检测目前只在启动时（`hasData()`）触发并展示全屏提示页；切 tab 时 `fetchAndStore` 检测到不匹配仅记录日志、保留旧数据。本次只完善提示页内容，不改变触发时机。
- macOS 与 iOS 的 `CKSchema.payloadVersion` 需要保持同步（当前均为 `1.2.4`）。
