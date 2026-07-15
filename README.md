# AI Pulse for macOS

[![CI](https://github.com/wxy/ai-pulse-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/wxy/ai-pulse-macos/actions/workflows/ci.yml)
[![App Store](https://img.shields.io/badge/App%20Store-AI%20Pulse-0D96F6?logo=apple)](https://apps.apple.com/us/app/ai-pulse/id6786290416?mt=12)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)]()
[![Swift](https://img.shields.io/badge/swift-6.0-orange)]()

Your AI coding fuel gauge — track exactly who's charging you, how much,
and whether your code output is worth it. **100% local, zero data leaves
your machine.**

## Download

[![Download on the Mac App Store](https://tools.applemediaservices.com/api/badges/download-on-the-mac-app-store/black/en-us?size=250x83)](https://apps.apple.com/us/app/ai-pulse/id6786290416?mt=12)

Requires macOS 14 Sonoma or later.

To build from source, see [Quick Start](#quick-start).

Also check out [AI Pulse for Chrome](https://github.com/wxy/ai-pulse) —
the browser extension that covers web-based AI tools like ChatGPT, Claude.ai,
DeepSeek Chat, and more.

## How It Works

AI Pulse discovers your AI spending through three layers, then attributes
every dollar to the right tool, provider, and repo:

```
┌─────────────────────────────────────────────────┐
│  Layer 1: Log Parsing (token-level accuracy)    │
│  Claude Code, aider — raw request/response logs │
├─────────────────────────────────────────────────┤
│  Layer 2: Balance API (exact dollar deltas)     │
│  DeepSeek, OpenAI, Kimi, Zhipu, Anthropic       │
├─────────────────────────────────────────────────┤
│  Layer 3: Subscription Detection (amortized)    │
│  Cursor, Copilot, Windsurf, Claude Code Pro     │
└─────────────────────────────────────────────────┘
                    ↓
           Arbitrator resolves
          each event to one CostSource
                    ↓
          CostSource (who's charging me?)
          • apiKey(providerId: "deepseek")
          • subscription(toolId: "cursor", tier: "Pro")
                    ↓
         ┌──────────┼──────────┐
      Dashboard    MenuBar     Dock
```

### CostSource Model

The 2-layer attribution system replaces the old A/B/C grade model:

- **Integration layer**: each integration declares what CostSources it
  provides — API keys with balance polling, subscriptions with monthly
  fee amortization
- **Arbitrator layer**: resolves every usage event to the most likely
  CostSource, priority: user-preferred API key → apiKey → subscription

Each CostSource carries a confidence level (`exact` > `estimated` >
`amortized` > `uncertain` > `incomplete`) so you always know how
reliable a number is.

## Features

### Dashboard
The 3-section home window gives you the full picture:
- **Donut chart** — spending breakdown by provider/tool with Mars Green and Deep Red palette
- **30-day trend chart** — daily spend stacked by API + subscription amortization
- **Repo & tool breakdown** — which projects and AI tools cost the most

### Menu Bar
- Quick-glance today/total spend in the menu bar
- Drill-down views by **provider**, **tool**, **repo**, and **week**
- All four views match the Dashboard totals perfectly (unified formula)

### Dock
- Fuel-gauge spending ring with log-scale progress
- Badge showing today's spending total
- Gold pulse animation on new data
- Right-click menu with quick cost breakdown

### Data Collection
| Tier | Sources | Method |
|------|---------|--------|
| Log parsing | Claude Code, aider | Token-level pricing from request logs |
| Balance API | DeepSeek, OpenAI, Kimi, Zhipu, Anthropic | Daily balance deltas |
| Subscription | Cursor, Copilot, Windsurf, Claude Code Pro | Monthly fee amortized to daily |

### Other Features
- **Anomaly detection** — spending spike alerts via macOS notification
- **Coin sounds** — satisfying audio feedback on data refresh (MP3)
- **Commit tracking** — libgit2-powered repo scanning, correlates code
  output with AI spending
- **Multi-language** — 中文 / English
- **Sandboxed** — Mac App Store compliant

## Requirements

- macOS 14 Sonoma or later
- Xcode 16.6+
- [Apple Developer Program](https://developer.apple.com) membership (for distribution)

## Quick Start

```bash
git clone https://github.com/wxy/ai-pulse-macos.git
cd ai-pulse-macos

# Command line
make build   # compile
make test    # run tests (56 tests)
make run     # launch in dev mode

# Or open in Xcode
open AIPulse/AIPulse.xcodeproj
```

## Distribution

AI Pulse is distributed through the [Mac App Store](https://apps.apple.com/us/app/ai-pulse/id6786290416?mt=12).
We recommend the App Store for automatic updates and sandbox security.

To build a DMG for direct distribution (requires Apple Developer membership):

```bash
cp .env.example .env
# Edit .env with your Apple ID and app-specific password
NOTARIZE=1 ./scripts/make-dmg.sh
```

## Architecture

```
Sources/
├── App/                AppDelegate, startup sequence
├── Engine/             Core logic
│   ├── CostSource      "Who's charging me?" — cost attribution model
│   ├── Arbitrator      Resolves events → CostSources via model name
│   ├── Integration*    Protocol (Detectable/Collectable) + Registry
│   ├── DataRefreshCoordinator  3-phase scheduler (30s/5min/1h)
│   ├── RepoDiscovery   Scans filesystem for git repos
│   ├── AnomalyDetector Spending spike detection
│   ├── CoinSound       MP3 coin effects on data refresh
│   ├── UsageMonitor    Tracks active AI tools (Claude cache, etc.)
│   └── EditorDetector  Infers editor-repo associations
├── GitMonitor/         libgit2-powered commit tracking
├── Ingest/
│   ├── LogWatcher      tail-style log scanner
│   ├── ApiPoller       Balance API polling
│   ├── PricingCatalog  Token pricing database
│   └── LogParsers/     Claude Code + aider log parsers
├── Integrations/       10 AI tool integrations
├── Store/              GRDB/SQLite persistence + StatsService
├── UI/
│   ├── Dashboard       3-section home window
│   ├── MenuBar         Cost breakdown in menu bar
│   ├── Dock            Fuel gauge + badge
│   ├── Settings        Per-integration configuration
│   ├── Onboarding      First-launch integration picker
│   └── Shared/         AppIconLoader, IntegrationRow
└── Utils/              I18n (zh/en), Logger
```

### Data Flow

```
LogWatcher        ──┐
ApiPoller         ──┤
GitMonitor        ──┤
RepoDiscovery     ──┤
                     ↓
        DataRefreshCoordinator
        (staggered 30s / 5min / 1h)
                     ↓
              .dataDidChange
                     ↓
    ┌────────┬────────┬────────┬──────────┐
 Dashboard  MenuBar   Dock   CoinSound  Anomaly
```

## Scripts

| Script | Purpose |
|---|---|
| `scripts/build-app.sh` | Build `.app` bundle from SPM |
| `scripts/release.sh` | Archive + sign + DMG + optional notarize |
| `scripts/make-dmg.sh` | DMG from `.app` with icon, layout, notarization |

## CI

| Workflow | Trigger | Does |
|----------|---------|------|
| `ci.yml` | Push / PR to `main` | Build + test |
| `release.yml` | `git tag v*` | Publish GitHub Release (App Store is primary distribution) |

## Related Projects

- [AI Pulse for Chrome](https://github.com/wxy/ai-pulse) — browser extension for web-based AI tools (ChatGPT, Claude.ai, DeepSeek Chat, etc.)

## License

Apache-2.0
