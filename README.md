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
- Xcode 16+ (for building from source)

## Quick Start

```bash
# Clone and build
git clone https://github.com/wxy/ai-pulse-macos.git
cd ai-pulse-macos
make build

# Run tests
make test

# Run the app (dev mode)
make run
```

## Architecture

```
Sources/
├── App/           # AppDelegate, SparkleSetup
├── Engine/        # Core logic: DataRefreshCoordinator, AnomalyDetector,
│                  #   CoinSound, RepoDiscovery, AppHealthMonitor, …
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

## CI

| Workflow | Trigger | What |
|----------|---------|------|
| `ci.yml` | push / PR to `main` | Build + test (~1 min) |
| `release.yml` | `git tag v*` | Sign + notarize + DMG + GitHub Release |

## License

Apache-2.0
