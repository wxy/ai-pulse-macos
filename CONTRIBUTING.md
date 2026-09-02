# Contributing to AI Pulse

Thanks for considering a contribution! This document is for developers and
covers the technical side of the project. For features and user guidance, see
the [README](README.md).

## Contributor License Agreement

By submitting a pull request — or any other contribution — you agree to the
[Individual Contributor License Agreement](CLA.md). In short: you grant the
project a perpetual, irrevocable, sublicensable license to your contribution,
including the right to use it in the **paid** App Store product, while you keep
the copyright to your own code.

AI Pulse is **open source (Apache-2.0), but the App Store product is paid
software** — contributions are made without expectation of payment.

This agreement applies to **third-party contributors**; the project owner's and
maintainers' own contributions are not subject to it.

Pull requests are not merged until the CLA has been accepted; the maintainers
may ask you to confirm acceptance in the pull request thread. Contributors
whose pull requests are merged are listed in the app's **Acknowledgments**
page (Settings → About → Acknowledgments).

## Quick Start

Requirements: macOS 14+, Xcode 16.6+ (and an [Apple Developer Program](https://developer.apple.com)
membership if you plan to distribute).

```bash
git clone https://github.com/wxy/ai-pulse-macos.git
cd ai-pulse-macos

make build   # compile (swift build)
make test    # build tests + run the full suite
make run     # launch in dev mode
```

To work in Xcode, open `AIPulse/AIPulse.xcodeproj` (macOS) or
`AIPulse.xcworkspace` (macOS + iOS/watchOS/widget targets, pick a scheme to
build any platform).

## Repository Layout

Monorepo — the macOS app plus the mobile suite:

```
Sources/              macOS app
  App/                AppDelegate, startup sequence, main menu
  Engine/             Core logic (integration registry, refresh, attribution)
  GitMonitor/         libgit2-powered commit tracking
  Ingest/             Log watcher, API poller, pricing catalog, log parsers
  Integrations/       One struct per supported AI tool
  Store/              GRDB/SQLite persistence + StatsService
  Sync/               iCloud/CloudKit sync
  UI/                 Dashboard, Dock, MenuBar menu, Settings, Onboarding
  Utils/              I18n, Logger, shared helpers
Suites/
  iOS/                iOS companion app
  watchOS/            watchOS glance app
  AIPulseWidget/      WidgetKit widget
  Shared/             Cross-target models + CloudKit schema
Libraries/
  libgit2/            Vendored arm64 libgit2 (linked via -Xcc / rpath)
Tests/                16 test files, ~91 test methods
docs/                 Design + App Store description docs
scripts/              Build / release / DMG scripts
```

## How It Works

### Three collection layers

Every AI spending event is discovered through one of three layers:

1. **Log parsing** (token-level accuracy) — Claude Code, aider, Codex CLI,
   OpenCode, Qwen Code request/response logs in `~` (scanned via
   `Ingest/LogWatcher` + `Ingest/LogParsers/`).
2. **Balance API** (exact balance deltas) — DeepSeek, OpenAI, Kimi, Zhipu,
   Anthropic daily balance polling (`Ingest/ApiPoller`).
3. **Subscription detection** (monthly fee amortized to daily) — Cursor,
   GitHub Copilot, Windsurf (plus Trae and Augment Code as detectable tiers)
   (`Engine` + `Store`).

### Cost attribution

Each usage event is resolved by the **Arbitrator** to a single `CostSource`
(`Engine/CostSource`) — either `apiKey(providerId:)` or `subscription(toolId:tier:)`.
Every CostSource carries a confidence level
(`exact > estimated > amortized > uncertain > incomplete`) so consumers always
know how reliable a number is. Cost attribution for subscription tools is
described in more detail in `docs/costsource-model.md`.

### Refresh cycle

`DataRefreshCoordinator` (in `Engine`) runs three staggered phases —
~30s / ~5min / ~1h — and publishes `.dataDidChange` so the Dashboard, Dock
icon, badge, coin sound, and anomaly detector all refresh from one signal.

### Dock ring & badge

`UI/Dock/DockManager` renders a progress ring around the Dock icon that fills
with today's spend vs. the daily rate (derived from the 30-day average), with
multiple "laps" allowed. `UI/Shared/AppIconLoader` renders the badge. The
stats menu you see on Dock right-click is built by `UI/MenuBar/MenuBarController`
via `applicationDockMenu(_:)` — there is no status-bar icon.

## Platform Suite

The macOS app writes dashboard snapshots; iOS / watchOS / widget read them:

- **CloudKit**: schema in `Packages/AIPulseShared/Sources/AIPulseShared/CloudKitSchema.swift` — a single
  record type `DashboardCache_v2`, one record per time range
  (`snapshot-today` / `snapshot-week` / `snapshot-30d`), JSON blob + `updatedAt`.
  The 2.x contract is isolated from the 1.x `DashboardCache_v1` series.
  Container `iCloud.com.wxy.aipulse` (private database).
- **macOS → iCloud**: one-way write, throttled ~5 min
  (`Sync/CloudSyncService`). Mobile targets are read-only.
- **iOS**: also caches locally (`dashboard_cache.json`) with a copy in App
  Group `group.com.wxy.aipulse` for the widget.
- **Push notifications**: iOS registers a CloudKit query subscription
  (`dashboard-v2-changes`, silent `content-available`) → background refresh +
  optional coin sound (`Suites/iOS/App/Notifications.swift`).
- Entitlements: `com.apple.developer.icloud-services` + `aps-environment` on
  the iOS target.

## Adding a New Integration

To track a new AI tool, implement a struct conforming to the `Detectable`
protocol (see existing examples, then register it in
`Sources/Engine/IntegrationRegistry.swift` under the right UI category —
`apiKeys` or `devTools`). For log-based tools, add a parser under
`Sources/Ingest/LogParsers/` (good reference points: the recent
Codex / OpenCode / Qwen Code integrations), plus parser tests in `Tests/`.
The integration row UI in `Sources/UI/Shared/IntegrationRow.swift` adapts
automatically to whether the integration provides an API key, subscription
tiers, or log detection.

## Testing

`make test` builds the test bundle with the vendored libgit2 include/rpath
injected, then runs `swift test --skip-build`. Suites live in `Tests/`:

- Parser tests: `ClaudeCodeParserTests`, `AiderParserTests`, `CodexParserTests`,
  `OpenCodeParserTests`, `QwenCodeParserTests`
- Engine/store: `CostSourceArbiterTests`, `StatsServiceTests`,
  `DataRefreshCoordinatorTests`, `PricingCatalogTests`, `UsageMonitorTests`
- Git: `GitMonitorTests`, `GitRepoScannerTests`
- Other: `DockManagerTests`, `ApiKeyIntegrationTests`, `CalendarTests`,
  `StableHashTests`

CI runs the same suite on macOS 15 / Xcode 26.3 (`.github/workflows/ci.yml`).

## Scripts & CI

| Script / target | Purpose |
|---|---|
| `python3 scripts/generate-icons.py` | Regenerate macOS + iOS + watch + widget icons from `Resources/AIPulse.png` |
| `python3 scripts/generate-icons.py --debug` | Same, with the orange corner notch that marks debug builds |
| `make release VERSION=x BUILD_NUM=y` (`scripts/release.sh`) | Archive + sign + DMG |
| `make release-notarize` | Same, plus notarization (needs `APPLE_ID` / `APPLE_APP_PASSWORD`) |
| `make restart` / `make hup` | Graceful SIGHUP restart (keeps DB connections clean) |

GitHub Actions: `ci.yml` (build + test on push/PR to `main`) and
`release.yml` (tag `v*` → GitHub Release).

## Distribution

- **Primary**: Mac App Store
  (`https://apps.apple.com/us/app/ai-pulse/id6786290416?mt=12`). The macOS app
  is sandboxed for App Store compliance.
- **Direct DMG**: `make release-notarize` for signed + notarized DMG.

App Store description copy is maintained in `docs/appstore-description.md`
(macOS) and `docs/appstore-description-ios.md` (iOS companion).

## License

Apache-2.0. See [LICENSE](LICENSE).
