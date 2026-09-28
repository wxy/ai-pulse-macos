# PR #91 iPhone dashboard deep-link verification (2026-09-28)

## Environment and repeatable input

- macOS with Xcode, iOS 26.5 Simulator and the `AIPulse_iOS` scheme from `Suites/AIPulse_Suites.xcodeproj`.
- Simulator: iPhone 17e, iOS 26.5. A fresh device was named `AI Pulse PR91 QA` for this run; any compatible iPhone simulator can be used.
- App launched with `--iphone-preview` so the dashboard has deterministic preview data and does not require iCloud.
- XcodeBuildMCP session defaults: project `Suites/AIPulse_Suites.xcodeproj`, scheme `AIPulse_iOS`, configuration `Debug`, simulator ID of the booted device, derived data under `$TMPDIR/ai-pulse-pr91-derived`, bundle ID `com.wxy.aipulse`.

Rebuild and run with XcodeBuildMCP `build_run_sim` using `extraArgs: ["CODE_SIGNING_ALLOWED=NO"]` and `launchArgs: ["--iphone-preview"]`. The build includes the iOS widget extension. Before routing, confirm the installed app declares `aipulse` under `CFBundleURLTypes`:

```sh
plutil -extract CFBundleURLTypes json -o - "$TMPDIR/ai-pulse-pr91-derived/Build/Products/Debug-iphonesimulator/AIPulse_iOS.app/Info.plist"
```

In the app, open Settings with the gear button. With the simulator booted, substitute its ID for `<DEVICE_ID>` and run:

```sh
xcrun simctl openurl <DEVICE_ID> 'aipulse://dashboard?range=30d'
xcrun simctl io <DEVICE_ID> screenshot docs/verification/artifacts/pr91-ios/dashboard-after-30d-link.png
```

For the default-range path, open Settings again. Set “启动时显示” to “今日” if needed, then run:

```sh
xcrun simctl openurl <DEVICE_ID> 'aipulse://dashboard'
```

## Observed result

The first build/run succeeded. Before `CFBundleURLTypes` was added, `simctl openurl` failed with `LSApplicationWorkspaceErrorDomain` code 115 because no app registered the scheme. After adding the URL declaration and rebuilding, `openurl` exited 0. The simulator presented an “Open in AI Pulse?” confirmation on the first invocation; tapping Open returned from Settings to the dashboard. The [Settings starting screenshot](artifacts/pr91-ios/settings-before-link.png) and [30-day result screenshot](artifacts/pr91-ios/dashboard-after-30d-link.png) show the navigation change and selected “30 天” segment with 53.9M preview tokens. A subsequent `aipulse://dashboard` invocation returned from Settings to the dashboard and showed the saved “今日” default with 2.5M preview tokens.

This proves URL registration, app routing, navigation return, and range selection on an iPhone simulator. The actual WidgetKit tap and notification-tap surfaces, VoiceOver spoken output, iCloud data, and a physical iPhone were not exercised.
