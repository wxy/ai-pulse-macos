# AI Pulse for macOS

[![CI](https://github.com/wxy/ai-pulse-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/wxy/ai-pulse-macos/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)]()
[![Swift](https://img.shields.io/badge/swift-6.0-orange)]()

Your AI coding fuel gauge. Tracks spending on AI coding tools and
compares it against your code output — always know your cost-per-line.

100% local, zero data leaves your machine.

## Features

- **Dock fuel gauge** — real-time spending ring with log-scale progress
- **Dashboard** — cost charts, code change charts, and CPL (cost-per-line)
- **Tiered data collection**
  - **A-grade**: log parsing (Claude Code, aider) for token-level cost
  - **B-grade**: balance API polling (DeepSeek, OpenAI, Kimi, Zhipu)
  - **C-grade**: subscription detection (Cursor, Windsurf, Copilot, Trae, Augment Code)
- **Anomaly detection** — spending spike alerts via macOS notification
- **Multi-language** — 中文 / English
- **Sandboxed** — ready for Mac App Store distribution

## Requirements

- macOS 14 Sonoma or later
- Xcode 16.6+ (for building from source)
- Paid Apple Developer Program membership (for distribution)

## Quick Start

```bash
# Clone
git clone https://github.com/wxy/ai-pulse-macos.git
cd ai-pulse-macos

# Build & run (command line)
make build
make run

# Or open in Xcode
open AIPulse/AIPulse.xcodeproj
# Product → Run (⌘R)
```

```bash
# Run tests
make test
```

## Building for Distribution

### Prerequisites

1. **Developer ID Application certificate** in Keychain
2. **App-specific password** for notarization: [appleid.apple.com](https://appleid.apple.com) → Sign-In & Security → App-Specific Passwords
3. Create `.env` from template:

```bash
cp .env.example .env
# Edit .env with your Apple ID and app-specific password
```

### 1. Archive in Xcode

```
Product → Archive (⌘⌥⇧A)
Distribute App → Direct Distribution
```

This exports a notarized `AIPulse.app` to `dist/`.

### 2. Package as DMG

```bash
# Build DMG only
./scripts/make-dmg.sh

# Build DMG + notarize + staple + verify
NOTARIZE=1 ./scripts/make-dmg.sh
```

Output: `dist/AIPulse-{version}.dmg`

### All-in-one via release script

```bash
# Build + sign + DMG (no notarization)
make release VERSION=1.0.1 BUILD_NUM=2

# Build + sign + DMG + notarize
NOTARIZE=1 make release
```

## Architecture

```
Sources/
├── App/           # AppDelegate, SparkleSetup
├── Engine/        # Core logic: CostSource, Arbitrator, DataRefreshCoordinator,
│                  #   AnomalyDetector, CoinSound, RepoDiscovery, AppHealthMonitor
├── GitMonitor/    # libgit2 commit scanner
├── Ingest/        # LogWatcher, ApiPoller, PricingCatalog, ProviderRegistry
├── Integrations/  # ClaudeCode, Aider, B/C-grade integrations
├── Store/         # AppDatabase (GRDB/SQLite), StatsService
├── UI/            # Dashboard, Dock, MenuBar, Settings, Onboarding, AppIconLoader
└── Utils/         # Logger, I18n
```

### Data Flow

```
LogWatcher (Claude Code logs)  ──┐
GitMonitor (commits)            ──┤
ApiPoller (balance APIs)        ──┤
RepoDiscovery (new repos)       ──┤
                                  ↓
                     DataRefreshCoordinator
                     (30s / 5min / 1h phases)
                                  ↓
                         .dataDidChange
                                  ↓
               ┌──────────┬──────────┬──────────┐
           Dashboard    MenuBar     Dock      CoinSound
```

## Scripts

| Script | Purpose |
|---|---|
| `scripts/build-app.sh` | Build `.app` bundle from Swift Package |
| `scripts/release.sh` | Archive + sign + DMG + optional notarization |
| `scripts/make-dmg.sh` | Create a nicely-formatted DMG from an `.app` |

## CI

| Workflow | Trigger | What |
|----------|---------|------|
| `ci.yml` | push / PR to `main` | Build + test (~1 min) |
| `release.yml` | `git tag v*` | Sign + notarize + DMG + GitHub Release |

## License

Apache-2.0
