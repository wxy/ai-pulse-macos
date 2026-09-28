# PR #91 iPhone Widget layout verification (2026-09-28)

## Environment and repeatable input

- Xcode `AIPulse_iOS` Debug scheme in `Suites/AIPulse_Suites.xcodeproj`; iPhone 17e Simulator on iOS 26.5, set to `Asia/Shanghai`. This run used simulator `1E2EA4C8-82DC-4A79-BEB6-E147DCC97EC3`.
- Use a task-specific DerivedData directory, for example `$TMPDIR/ai-pulse-pr91-widget-layout-signed-derived`. Keep normal development signing enabled so the installed app retains its `group.com.wxy.aipulse` App Group. An unsigned build compiled and launched but its installed app had no App Group container and the widget picker remained blank.
- With XcodeBuildMCP, set the project, `AIPulse_iOS` scheme, Debug configuration, simulator and DerivedData path as session defaults. Run `build_run_sim({launchArgs:["--iphone-preview"]})` without `CODE_SIGNING_ALLOWED=NO`. This launches the app with the synthetic `PhonePreviewData.install` snapshots and pulse; no iCloud account or private Mac usage data is needed. Stop the app to return to the Home Screen.
- On the Home Screen, long press the AI Pulse app icon and select **中尺寸小组件**. Repeat with **大尺寸小组件**. To regenerate the screenshots, substitute the simulator ID and run:

```sh
xcrun simctl io <DEVICE_ID> screenshot docs/verification/pr-91-widget-medium-2026-09-28.png
xcrun simctl io <DEVICE_ID> screenshot docs/verification/pr-91-widget-large-2026-09-28.png
```

Capture the medium screenshot before adding the large widget so each size can be inspected at native resolution. `PhonePreviewData` writes `dashboard_cache.json` and `current_pulse_v2.json` into the signed App Group; inspect those files in the task simulator to confirm the widget is reading the intended synthetic input.

## Observed result

- The final signed iPhone build and launch succeeded with no reported warnings or errors. Its installed App Group container was present.
- [Medium screenshot](pr-91-widget-medium-2026-09-28.png): Today's ring and four curved corner facts remain on the left. The right side is vertically centered and shows this week's tokens, lines and each ratio against last week. It has no duplicate activity text.
- [Large screenshot](pr-91-widget-large-2026-09-28.png): The same Today/Week header sits above the 30-day two-row rhythm. Tokens are the upper green row and lines the lower red row, following the iPhone dashboard's mouth chart; both rows have visible labels. The chart is centered in the lower area.
- The installed synthetic cache showed Today `2,450,000` tokens and Week `12,250,000` tokens on 2026-09-28. The debug fixture's period totals and individual daily rhythm points are generated independently, so the displayed comparison multipliers in these screenshots prove rendering but do not validate real-data ratio accuracy. Source review verified that the widget uses the previous complete Monday-to-Monday period and suppresses ratios when the baseline is unavailable or zero.

The physical iPhone, real Mac-to-iPhone CloudKit transfer, WidgetKit tap/deep link and spoken VoiceOver output were not exercised in this run. The source-level checks `swiftc -frontend -parse Suites/AIPulseWidget/WidgetViews.swift Suites/AIPulseWidget/AIPulseWidget.swift` and `git diff --check` also passed.
