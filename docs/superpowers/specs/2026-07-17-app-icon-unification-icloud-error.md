# App Icon 统一 & iCloud 错误区分

**日期**: 2026-07-17
**分支**: `explore/multi-platform-suite`
**范围**: iOS companion app

---

## 背景

iOS 端有两个素材冗余问题和一个 UX 缺陷：

1. **素材冗余**: `Logo.imageset/Logo.png` 与 `AppIcon.appiconset/AIPulse.png` 是同一个文件（MD5 `0100d99a64172616a2cb8c20180d22ed`），但分别存储
2. **引用分散**: 闪屏和 WelcomeView 用 `Image("Logo")`，而非 app icon
3. **错误混淆**: `CloudDataService.hasData()` 把所有 CloudKit 失败都返回 `false`，iCloud 连接失败（网络/认证/权限）和"无数据"（新用户）无法区分，用户看到同样的 WelcomeView

## 目标

- 统一素材：删除重复的 Logo.png，只保留 AppIcon 源文件，通过符号链接让现有 `Image("Logo")` 引用继续工作
- 区分 iCloud 不可用 vs 无数据：CloudKit 连接失败时显示专用错误页（带重试），新用户看到欢迎引导页
- 两个页面都使用 app icon + "AI Pulse" 品牌标识

---

## 设计

### 素材层

- **删除** `Suites/iOS/Assets.xcassets/Logo.imageset/Logo.png`
- **创建** 符号链接 `Logo.imageset/Logo.png → ../../AppIcon.appiconset/AIPulse.png`
- `Logo.imageset/Contents.json` 不变（filename 仍为 `"Logo.png"`，符号链接透明）
- 代码中 `Image("Logo")` 无需改动，运行时加载的实际是 AIPulse.png

### 代码层

#### CloudDataService — 新增 CloudError 枚举

`hasData()` 当前签名: `func hasData() async throws -> Bool`

改造为返回值语义：

```swift
enum CloudError: Error {
    case noData       // 记录不存在 → 新用户（CloudKit 可用，只是没数据）
    case unavailable  // iCloud 不可用 → 网络/认证/权限失败
}
```

错误映射规则：
- `CKError.networkUnavailable`, `.notAuthenticated`, `.permissionFailure` → `.unavailable`
- 记录不存在（`CKError.unknownItem`）→ `.noData`
- JSON 解码失败 → `.noData`（数据存在但格式不对，非连接问题）

`hasData()` 改为 throws `CloudError` 而不是静默返回 `false`。

#### ContentView — AppState 枚举路由

将 `hasData: Bool?` 替换为：

```swift
enum AppState {
    case loading          // 初始/检测中 → 闪屏
    case ready            // 有数据 → DashboardView
    case noData           // CloudKit 可用但无数据 → WelcomeView
    case error(CloudError) // iCloud 不可用 → CloudErrorView
}
```

路由逻辑：
- `.loading` → 闪屏（app icon + "AI Pulse" + ProgressView + 最少 1.5s）
- `.ready` → DashboardView
- `.noData` → WelcomeView
- `.error` → CloudErrorView

#### CloudErrorView（新建）

iCloud 不可用时的专用页面：

- App icon (80x80, cornerRadius 18)
- "AI Pulse" 标题
- 错误说明文字（`I18n.t("cloud.error.title")`）
- 引导 checklist（`I18n.t("cloud.error.body")`）
- 重试按钮 → 重新调用 `hasData()` → 更新状态
- 视觉风格与 WelcomeView 一致（居中、VStack spacing、同字号层级）

#### WelcomeView

只更新图标引用（继续使用 `Image("Logo")`，素材层已指向 app icon）。

---

## 文件变更

| 操作 | 文件 | 说明 |
|------|------|------|
| 删除 | `Suites/iOS/Assets.xcassets/Logo.imageset/Logo.png` | 重复素材 |
| 新建(符号链接) | `Suites/iOS/Assets.xcassets/Logo.imageset/Logo.png → ../AppIcon.appiconset/AIPulse.png` | 指向 app icon |
| 编辑 | `Suites/iOS/App/CloudDataService.swift` | 新增 `CloudError`，`hasData()` 改为 throws |
| 编辑 | `Suites/iOS/App/AIPulse_iOSApp.swift` | `AppState` 枚举 + 路由逻辑 |
| 新建 | `Suites/iOS/UI/CloudErrorView.swift` | iCloud 错误页面 |
| 不变 | `Suites/iOS/UI/WelcomeView.swift` | Logo.imageset 已指向 app icon，代码不动 |

## 新增 I18n 键值

- `cloud.error.title` — 错误标题（例："无法连接到 iCloud"）
- `cloud.error.body` — 引导 checklist（例："请检查：\n• 网络连接是否正常\n• 设置中已登录 iCloud\n• iCloud Drive 已开启"）
- `cloud.error.retry` — 重试按钮文字（例："重试"）

## 不涉及

- macOS 端（素材和 CloudSync 均不受影响）
- DashboardView
- NotificationService

---

## 验收标准

1. 闪屏显示 app icon + "AI Pulse" + 加载指示器，至少保持 1.5s
2. iCloud 可用且有数据 → 进入 DashboardView
3. iCloud 可用但无数据 → 进入 WelcomeView（app icon + 欢迎引导）
4. iCloud 不可用 → 进入 CloudErrorView（app icon + 错误 + 引导 + 重试按钮）
5. 重试按钮成功恢复 → 跳转对应页面
6. `Logo.imageset/Logo.png` 是符号链接且指向 AIPulse.png
7. 构建成功
