# Dashboard tooltip sizing verification — 2026-10-23

## Change and scope

The dashboard's shared `robotHelp` renderer forced every tooltip to 280 pt wide and used a 190 pt positioning wrapper. It now measures the padded text's natural width, caps it at 280 pt (or the available width), wraps long text, and positions the result using its actual dimensions with a 12 pt container margin. Hover preferences, accessibility hints and noninteractive tooltip behavior are preserved.

Only the macOS dashboard layout changed. No authorization, scanning, parsing, persistence or loading-state behavior changed.

## Verification

Environment: macOS 26.6.2, Xcode 27.1 (27A9275), arm64.

```sh
xcodebuild -workspace AIPulse.xcworkspace -scheme AIPulse_macOS \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/aipulse-tooltip-qa/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=xingyu.wang.aipulse.runtimeqa build
git diff --check
```

Both passed. The separate sandbox UI QA copy launched with `-app_language zh-Hans -demo_mode_manual NO`; the actual dashboard showed its preferences button and home-authorization action. Its widget was removed before local ad-hoc signing, cloud access was disabled, and existing normal/QA data outside this new sandbox container was not used.

The native automation interface did not reliably trigger SwiftUI's hover state. This prevents claiming a successful automated hover end-to-end check. Since the changed system is tooltip measurement/placement, its rendering was checked separately using an interactive temporary AppKit/SwiftUI fixture. No unit tests were added after implementation.

Before creating that fixture, the layout failure cases were: short text retaining the old width; long text failing to wrap; explicit line breaks clipping; stale dimensions after switching text; overflow at upper/lower and left/right edges; and measurement disagreeing with larger dashboard typography.

Fixture generation: copy `RobotTooltipLayout`, `RobotTooltipHint`, `RobotTooltipPreference` from `DashboardView.swift` and the unchanged `DashboardScaledFont.swift` into a temporary `main.swift`. Host a 560 × 640 pt SwiftUI view with the same 11 pt dashboard font, 3 pt line spacing, vertical fixed-size text, 12 pt padding, rounded background and border. Buttons at the top right, top center, top left, bottom right and bottom left select the hint and supply its bounds anchor; the preference overlay calls the production layout unchanged. This replaces only the unreliable automated hover trigger. Compile the temporary fixture with:

```sh
swiftc -target arm64-apple-macos14.0 -framework SwiftUI -framework AppKit \
  /private/tmp/aipulse-tooltip-qa/main.swift \
  -o /private/tmp/aipulse-tooltip-qa/TooltipLayoutQA.app/Contents/MacOS/TooltipLayoutQA
```

| Synthetic input / interaction | Actual visual result |
| --- | --- |
| `偏好设置…` at top right | Compact single-line panel; no fixed-width empty tail. |
| `授权真实目录` at top center | Width grows with the longer label while remaining compact. |
| `各工具可确认的词元用量及占比；不是额度、账单或工作效率。缓存词元属于输入，不重复累加。` at top left | Wraps, full text visible, panel remains inside the left boundary. |
| Four lines: current AI intensity / recent confirmed facts / supported readable data only / intensity independent of the selected range, at bottom right | All lines visible; panel appears above its anchor and inside the right boundary. |
| `Authorize the actual folder to resume reading local activity and repository history.` at bottom left, `.accessibility3` | Larger text wraps without clipping and stays inside the left boundary. |
| Switch from the larger English description back to `偏好设置…` | Panel returns to its compact width and height. |

Observations are visual; no exact pixel measurements are claimed. Full live hover interaction remains a manual check. The existing hover modifier was not changed. No broader ingestion/database/platform regression was run because it does not address the changed layout risk.

## Cleanup

The temporary QA applications, fixture source, screenshots/logs, DerivedData and newly created sandbox container Data are removed after verification. No widget from either QA app was registered. OS-managed container metadata is left to macOS. Only this report is retained as verification material; no process artifacts enter Git.
