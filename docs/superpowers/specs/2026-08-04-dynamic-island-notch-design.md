# AI Pulse · Dynamic Island / 刘海区域交互设计

- **日期**：2026-08-04
- **状态**：设计稿，暂不实现
- **相关代码**：`Sources/App/AIPulseApp.swift`（AppDelegate / Dock 菜单 / 窗口路由）、`Sources/UI/MenuBar/MenuBarController.swift`（`DashboardWindowManager`、`MenuBarController`）、`Sources/UI/Dashboard/DashboardView.swift`、`Sources/UI/Shared/AppIconLoader.swift`

---

## 1. 背景与问题

AI Pulse 是常驻 Dock 的 macOS 应用：

- 主交互是 Dashboard 窗口（`DashboardWindowManager.openOrBringToFront`）。
- 实时信息目前通过 **Dock 角标**（今日花费数字）和 **Dock 右键菜单**（`MenuBarController.menu`，30s 刷新的统计菜单）展示。
- 没有菜单栏状态项图标。

**问题**：

1. **Dock 角标只能显示一个数字**，没有交互，信息密度低。
2. 想看到完整仪表盘必须打开窗口。
3. 受 Mac 上「Dynamic Island」类应用启发（[Vibe Island](https://vibeisland.app/)、[BoringNotch](https://github.com/TheBoredTeam/boring.notch)），把常驻信息放到**屏幕顶部刘海区域**、点击下拉展开仪表盘，可能是比 Dock 角标更直观的形态。

## 2. 目标

提供一个「**常驻实时信息 + 点击展开仪表盘**」的交互，让用户不打开窗口也能掌握 Claude 花费状态，同时**不牺牲**无刘海机型和无窗口偏好的用户体验。

## 3. 三态模式（核心设计）

因为**刘海是硬件特性、并非所有 Mac 都有**，且常驻浮层有侵入性，设计为**用户可选的三态**：

| 模式 | 载体 | 适用机型 | 特点 |
|---|---|---|---|
| **窗口模式** | Dashboard 窗口 | 所有 Mac（默认） | 现状，零改动 |
| **菜单栏状态项** | 菜单栏右侧 `NSStatusItem` | 所有 Mac | 通用兜底：常驻图标 + 点击弹统计面板 |
| **灵动岛模式** | 刘海位置浮层窗口 | 仅刘海机型，用户 opt-in | 增强版：锚定刘海，可下拉完整仪表盘 |

- 设置中提供模式选择。
- 灵动岛模式仅在「检测到刘海机型或用户手动开启」时可用。
- 窗口模式始终作为兜底保留。

## 4. 灵动岛技术机制

### 4.1 窗口

- **无边框透明浮层**：`NSWindow(styleMask: .borderless)`、`isOpaque = false`、`backgroundColor = .clear`、`hasShadow = false`。
- **折叠态（pill）**：宽 ≈ 刘海宽度，高 ≈ 菜单栏/刘海高度，定位在屏幕顶部正中，常驻显示迷你信息（今日花费 + 迷你进度环，复用现有视觉语言）。
- **展开态（dropdown）**：把窗口 frame 向下/两侧扩大，装 `NSHostingView(rootView: DashboardView(...))`，即完整仪表盘。

### 4.2 层级与空间

- `window.level` 抬到菜单栏之上（参考 BoringNotch 的实现：菜单栏之上、应用内容之下的层级，或 `.statusBar` 级）。
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`：在所有空间、以及其它应用全屏时都可见。
- 透明区域 `ignoresMouseEvents = true`，让点击穿透到下面的菜单栏/应用。

### 4.3 交互路由

- **Dock 点击**：`applicationShouldHandleReopen(_:hasVisibleWindows:)` 在岛模式下改为「展开灵动岛下拉」，而非 `openDashboard()` 开窗口。
- **点击 pill** → 展开下拉；**点击外部 / 收起按钮** → 折叠回 pill。
- 状态切换不重建窗口，只改 frame 与内容（折叠态显示迷你视图，展开态显示 DashboardView）。

### 4.4 复用

- **统计菜单**：复用 `MenuBarController.menu`（当前即 Dock 右键菜单内容，30s 刷新）。
- **仪表盘**：展开面板直接复用 `DashboardView`。
- **进度环 / 图标视觉**：复用 `AppIconLoader` 的绘制。

## 5. 刘海硬件事实（参考数据）

- 刘海 = 屏幕顶部一条居中切口，**高 74 物理像素 = 37pt**（Retina 2x），由分辨率数学得出（14" 3024×1964、16" 3456×2234，减去顶部 74px 后恰为 16:10）。
- **宽度约 35–45pt**：Apple 未公布，社区实测与高度相当，略接近正方形。
- 真正不可显示的区域就是这一小块；**其余屏幕全部可显示**。
- 岛应用的「扩展显示范围」本质是**把浮层窗口的 frame 拉大**，极限是整块屏幕——不是突破物理限制。
- 全屏时 `NSScreen.safeAreaInsets.top` ≈ 32–37pt（系统给应用避让刘海的参考值）。

## 6. 刘海检测（诚实结论）

**没有可靠的公共 API 在窗口模式检测刘海。**

- `NSScreen.safeAreaInsets`：官方 API，但**窗口模式下返回 0，即使刘海机型也是 0**（iTerm2 源码亦抱怨此点）；仅在进入全屏后非零（≈32pt）。
- `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` 类似，也不适合启动时检测。

可选手段：

| 手段 | 可靠性 | 代价 |
|---|---|---|
| 硬件型号匹配（`sysctl hw.model` → 维护刘海机型列表：`MacBookPro18,*`、`Mac14,*`（Air M2）、`Mac15,*` 等） | 对已知机型可靠 | 新机型需更新列表 |
| 进全屏后查 `safeAreaInsets` | 可靠但滞后 | 不能启动时用 |

**推荐**：不依赖自动检测。设置里直接提供「灵动岛模式」开关；可加一个**最佳努力默认**（型号匹配到明显刘海机型就默认高亮该选项），但最终由用户决定。选错无害——无刘海机器上开启，用户会发现岛位置不合适并关掉，窗口模式始终兜底。

## 7. 兼容性与降级

| 类别 | 机型 |
|---|---|
| 有刘海 | MacBook Pro 14"/16"（2021 及之后）、MacBook Air（M2 2022 及之后）、M4 系列 |
| 无刘海 | iMac、Mac mini、Mac Studio、Mac Pro、旧款 MacBook Pro 13"/Air M1、**所有外接显示器** |

- 无刘海机型：灵动岛模式不可用 → 回退窗口模式或菜单栏状态项。
- 菜单栏状态项是「常驻信息 + 点击展开」的**通用版本**，所有 Mac 都有菜单栏，与硬件无关，是灵动岛的兜底。

## 8. UX 权衡

- **侵入性**：灵动岛浮在其它应用之上，对不习惯的用户是干扰 → 必须 opt-in，不做默认。
- **菜单栏遮挡**：折叠 pill 会盖住菜单栏**中央的菜单标题**（BoringNotch 用户接受的代价）。
- **范式变化**：岛模式「常驻 + 下拉」没有传统窗口，设置等小面板需放进岛内，或暂时保留一个小窗口——设计取舍。
- **多屏 / 外接**：岛应只在主屏（内置刘海屏）显示，或允许用户选择显示在哪块屏。

## 9. 未决问题（实现前需定）

1. 设置面板放岛内，还是保留一个小窗口？
2. 岛在其它应用全屏时是否也显示？（`fullScreenAuxiliary` 的取舍）
3. 折叠 pill 的精确尺寸：匹配物理刘海 vs 略宽（影响视觉与菜单栏遮挡程度）。
4. 多显示器行为：岛锚定主屏还是用户可选。
5. 岛模式下 Dock 角标是否仍显示（避免信息重复）。
6. 菜单栏状态项与灵动岛是否允许**同时开启**（信息冗余度）。

## 10. 范围

本文档仅记录设计与讨论结论，**暂不实现**。实现时建议先做最小原型（常驻 pill + 点击展开 + 三态切换），验证交互后再完整落地。

---

### 参考

- [Vibe Island](https://vibeisland.app/)：把刘海区变成 AI 代理控制面板的同类应用
- [BoringNotch](https://github.com/TheBoredTeam/boring.notch)：开源「Dynamic Island for Mac」
- [safeAreaInsets | Apple Developer Documentation](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets)
- [Detect MacBook notch (Stack Overflow)](https://stackoverflow.com/feeds/question/69685094)
- [Ars Technica：从 16:10 比例推导刘海高 74px](https://arstechnica.com/civis/threads/apple-intros-14-and-16-inch-macbook-pros-with-display-notches-m1-pro-and-m1-max.1479927/)
