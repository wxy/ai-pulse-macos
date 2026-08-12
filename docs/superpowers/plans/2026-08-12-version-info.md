# Version Info Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 macOS/iOS 的仪表盘与关于页展示 CloudKit 载荷版本号，并在 iOS 版本不匹配提示页同时显示"当前支持版本"与"CloudKit 提供版本"。

**Architecture:** 纯展示层改动。数据来源统一为两端各自的 `CKSchema.payloadVersion` 常量（值 `1.2.4`，保持不变）；macOS 与 iOS 分别在 DashboardView / AboutTab / VersionMismatchView 中直接引用该常量渲染文本。

**Tech Stack:** SwiftUI、Swift 6、GRDB（macOS 端，本次不动）、CloudKit、Xcode 26.6（Swift 6.3）。

## Global Constraints

- `CKSchema.payloadVersion` 保持 `"1.2.4"` 不变（两份：`Sources/Sync/CloudKitSchema.swift` 与 `Suites/Shared/Models/CloudKitSchema.swift`）。
- 不修改 DashboardSnapshot JSON 结构、CloudKit 记录格式、GRDB 数据库 schema。
- 仪表盘只显示数据库版本号，文案固定为 `"CloudKit " + CKSchema.payloadVersion`；软件版本号只在关于页显示（已存在，不动）。
- macOS 关于页沿用现有 `v1.2.5 (27)` 行，在其下方新增数据库版本行。
- iOS 不匹配提示页新增 I18n key `version.mismatch.supported`，需在 `Suites/Shared/I18n/I18n.swift` 的全部 **10 种语言**（en、zh-Hans、zh-Hant-TW、zh-Hant-HK、ja、ko、de、fr、es、pt-BR）中补齐。
- 构建验证命令（需要写 DerivedData，执行时需沙箱外权限）：
  - macOS: `xcodebuild -project AIPulse/AIPulse.xcodeproj -scheme AIPulse_macOS -configuration Debug -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/AIPulse-aczbwitgdbvfhncfhiamhgkajsjm CODE_SIGNING_ALLOWED=NO build`
  - iOS: `xcodebuild -project Suites/AIPulse_Suites.xcodeproj -scheme AIPulse_iOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/aipulse-suites-dd CODE_SIGNING_ALLOWED=NO build`

---

### Task 1: macOS 仪表盘底部显示 CloudKit 版本号

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardView.swift`（body 中 `lastUpdatedFooter` 调用处，约 276 行）

**Interfaces:**
- Consumes: `CKSchema.payloadVersion`（`Sources/Sync/CloudKitSchema.swift`，同 module 直接引用）
- Produces: 仪表盘最底部出现 `CloudKit 1.2.4`

- [ ] **Step 1: 在 footer 后追加版本号文本**

在 `lastUpdatedFooter` 调用行之后、外层 VStack 闭合之前插入：

```swift
                    lastUpdatedFooter

                    Text("CloudKit \(CKSchema.payloadVersion)")
                        .font(.caption2).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 12)
```

（`lastUpdatedFooter` 原有代码不动；版本号行始终显示，不依赖 `lastUpdated`。）

- [ ] **Step 2: 构建验证**

Run: macOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`，无新增 warning（`plotAreaFrame` 警告此前已修复）

- [ ] **Step 3: 提交**

```bash
git add Sources/UI/Dashboard/DashboardView.swift
git commit -m "feat: show CloudKit payload version in macOS dashboard footer"
```

---

### Task 2: macOS 关于页显示数据库版本号

**Files:**
- Modify: `Sources/UI/Settings/SettingsView.swift`（`AboutTab` 内版本行之后）

**Interfaces:**
- Consumes: `CKSchema.payloadVersion`
- Produces: 关于页在 `v1.2.5 (27)` 下方显示 `CloudKit 1.2.4`

- [ ] **Step 1: 在软件版本行后追加数据库版本行**

在 AboutTab 中下面这行之后：

```swift
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"))").font(.caption).foregroundColor(.secondary)
```

插入：

```swift
            Text("CloudKit \(CKSchema.payloadVersion)")
                .font(.caption).foregroundColor(.secondary)
```

- [ ] **Step 2: 构建验证**

Run: macOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add Sources/UI/Settings/SettingsView.swift
git commit -m "feat: show database version in macOS About tab"
```

---

### Task 3: iOS 仪表盘底部显示 CloudKit 版本号

**Files:**
- Modify: `Suites/iOS/UI/DashboardView.swift`（"更新于…" 文本之后）

**Interfaces:**
- Consumes: `CKSchema.payloadVersion`（`Suites/Shared/Models/CloudKitSchema.swift`，同一 target 直接引用）
- Produces: 三个时间范围页面底部均显示 `CloudKit 1.2.4`

- [ ] **Step 1: 在"更新于…"之后追加版本号文本**

在下面这段之后：

```swift
                if let updated = cloudData.lastUpdated {
                    Text("\(I18n.t("dashboard.updated")) \(updated, format: .dateTime.month(.abbreviated).day().hour().minute().locale(.current))")
                        .font(.caption2).foregroundColor(.secondary)
                }
```

插入（仍在同一个 VStack 内）：

```swift
                Text("CloudKit \(CKSchema.payloadVersion)")
                    .font(.caption2).foregroundColor(.secondary)
```

- [ ] **Step 2: 构建验证**

Run: iOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add Suites/iOS/UI/DashboardView.swift
git commit -m "feat: show CloudKit payload version in iOS dashboard footer"
```

---

### Task 4: iOS 版本不匹配提示页显示两个版本号

**Files:**
- Modify: `Suites/iOS/UI/VersionMismatchView.swift`
- Modify: `Suites/Shared/I18n/I18n.swift`（10 种语言的 `version.mismatch.payload` 行附近）
- Modify: `docs/superpowers/specs/2026-08-12-version-info-design.md`（把"5 种语言"更正为实际 10 种语言）

**Interfaces:**
- Consumes: `CKSchema.payloadVersion`、`I18n.t("version.mismatch.supported")`、`I18n.t("version.mismatch.payload")`、现有参数 `recordVersion: String?`
- Produces: 提示页显示两行小字：`当前支持版本 1.2.4` 与 `载荷版本 <recordVersion>`

- [ ] **Step 1: 修改 VersionMismatchView**

把现有：

```swift
            if let recordVersion, !recordVersion.isEmpty {
                Text(String(format: I18n.t("version.mismatch.payload"), recordVersion))
                    .font(.caption).foregroundColor(.secondary)
            }
```

替换为：

```swift
            Text(String(format: I18n.t("version.mismatch.supported"), CKSchema.payloadVersion))
                .font(.caption).foregroundColor(.secondary)
            if let recordVersion, !recordVersion.isEmpty {
                Text(String(format: I18n.t("version.mismatch.payload"), recordVersion))
                    .font(.caption).foregroundColor(.secondary)
            }
```

- [ ] **Step 2: 在 I18n.swift 的 10 种语言中新增 `version.mismatch.supported`**

在每种语言的 `"version.mismatch.payload": ...` 行之后插入对应行：

| 语言 | 键值 |
| --- | --- |
| en | `"version.mismatch.supported": "Supported version %@",` |
| zh-Hans | `"version.mismatch.supported": "当前支持版本 %@",` |
| zh-Hant-TW | `"version.mismatch.supported": "目前支援版本 %@",` |
| zh-Hant-HK | `"version.mismatch.supported": "目前支援版本 %@",` |
| ja | `"version.mismatch.supported": "対応バージョン %@",` |
| ko | `"version.mismatch.supported": "지원 버전 %@",` |
| de | `"version.mismatch.supported": "Unterstützte Version %@",` |
| fr | `"version.mismatch.supported": "Version prise en charge %@",` |
| es | `"version.mismatch.supported": "Versión compatible %@",` |
| pt-BR | `"version.mismatch.supported": "Versão compatível %@",` |

`version.mismatch.payload` 在 I18n.swift 中的 10 个位置：41、78、114、150、186、222、258、294、330、366 行附近。

- [ ] **Step 3: 更正 spec 中的语言数量描述**

将 `docs/superpowers/specs/2026-08-12-version-info-design.md` 中：

```markdown
I18n 需要在 `Suites/Shared/I18n/I18n.swift` 的 5 种语言（en / zh-Hans / zh-Hant / ja / ko）中补齐。
```

替换为：

```markdown
I18n 需要在 `Suites/Shared/I18n/I18n.swift` 的全部 10 种语言（en / zh-Hans / zh-Hant-TW / zh-Hant-HK / ja / ko / de / fr / es / pt-BR）中补齐。
```

- [ ] **Step 4: 构建验证**

Run: iOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 提交**

```bash
git add Suites/iOS/UI/VersionMismatchView.swift Suites/Shared/I18n/I18n.swift docs/superpowers/specs/2026-08-12-version-info-design.md
git commit -m "feat: show supported and CloudKit versions on iOS mismatch screen"
```

---

### Task 5: 全量验证

**Files:** 无代码改动

- [ ] **Step 1: macOS 构建**

Run: macOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`；确认输出中无 `plotAreaFrame`/`plotFrame` 相关 warning

- [ ] **Step 2: iOS 构建**

Run: iOS 构建命令（见 Global Constraints）
Expected: `** BUILD SUCCEEDED **`；确认输出中无新增 warning

- [ ] **Step 3: 核对工作区改动**

Run: `git -C /Users/xingyuwang/develop/ai-pulse-macos status --short`
Expected: 仅包含本计划的 5 个文件（DashboardView.swift×2、SettingsView.swift、VersionMismatchView.swift、I18n.swift、spec、plan）以及此前已存在的用户改动（`AIPulse/AIPulse.xcodeproj/project.pbxproj`、`Suites/AIPulse_Suites.xcodeproj/project.pbxproj`、两个 xcuserdata 文件、`Sources/UI/Dashboard/ToolDetailOverlayView.swift` 的 plotFrame 修复）
