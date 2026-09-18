# watchOS 表盘小组件 — Xcode 操作清单

> 目标：给 Suites 的 watch app 加一个 WidgetKit 扩展，表盘上显示
> 今日消费环（档位配色）+ 原生消费脉搏。维护中的实现位于：
> `Suites/AIPulseWatchWidget/AIPulseWatchWidget.swift`。

## 一、添加 target（一次性，约 2 分钟）

1. 打开 `Suites/AIPulse_Suites.xcodeproj`（不是 workspace 也行）
2. File → New → **Target…**
3. 模板选 **watchOS** 标签页 → **Widget Extension** → Next
4. Product Name 填：`AIPulseWatchWidget`
5. **取消勾选** "Include Configuration App Intent"（不需要可配置项）
   - 若有 "Embed in Application" 选项 → 选 watch app（`AIPulse_Suites`）
6. Finish → 弹窗 "Activate scheme?" 选 **Activate**

Xcode 会自动：创建 `Suites/AIPulseWatchWidget/` 文件夹 + 模板代码 +
把新 target 嵌入 watch app + 生成它的 Info.plist。

## 二、替换模板代码

1. 删除 Xcode 生成的 Swift 模板文件（保留 `Info.plist`）
2. 将 `Suites/AIPulseWatchWidget/AIPulseWatchWidget.swift` 加入新 target；
   该文件包含 Bundle、Provider 与各尺寸视图

## 三、链接共享框架

1. 选新 target `AIPulseWatchWidget` → General → **Frameworks and Libraries**
2. `+` → 选 **AIPulseShared**（watchOS 平台的）→ Add

## 四、Entitlements（两处能力）

选新 target → Signing & Capabilities → `+ Capability`：

1. **iCloud**：勾选 CloudKit；Containers 勾 `iCloud.com.wxy.aipulse`
   （小组件自读私有库的 `snapshot-v2-today` 记录，必须与 app 同容器）
2. （可选）Push Notifications —— 若以后想用远程推送即时刷新再加

> 最省事的替代：把 `Suites/AIPulse_watchOS.entitlements` 的内容复制到
> 新 target 的 entitlements 文件（它已含 aps + iCloud 容器 + CloudKit）。

## 五、构建验证

1. Scheme 切到 `AIPulseWatchWidget`（或 watch app scheme）→ Build
2. 模拟器/真机表盘 → 长按表盘 → 编辑 → 添加复杂功能槽位 → 选
   **AI Pulse 燃烧率** → 选 Circular / Rectangular / Inline 样式
3. 数据来自 iCloud 私有库 `snapshot-v2-today`（Mac 端 Phase 4 每 5 分钟
   刷新快照；表盘按系统预算约 15 分钟后再取）

## 常见坑

| 症状 | 原因/解法 |
|---|---|
| Build 报 `Cannot find DashboardSnapshot` | 第三步漏了：AIPulseShared 未链接到新 target |
| 表盘显示 $0.00 / 无数据 | iCloud 未登录、容器 id 不一致，或 Mac 端还没写过 today 快照（先让 Mac app 跑一轮 Phase 4） |
| 圆环不动 | 环的分子是 todayCost / dailyRate，dailyRate 来自快照 prediction；新装无 30 天历史时预测为 0 |
| 新 target 的文件出现两份 | 模板文件没删干净就又粘贴了同名类型 —— 删模板再粘 |
