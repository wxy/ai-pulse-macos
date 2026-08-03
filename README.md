# AI Pulse for macOS

[![CI](https://github.com/wxy/ai-pulse-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/wxy/ai-pulse-macos/actions/workflows/ci.yml)
[![Mac App Store](https://img.shields.io/badge/Mac%20App%20Store-AI%20Pulse-0D96F6?logo=apple)](https://apps.apple.com/us/app/ai-pulse/id6786290416?mt=12)
[![iOS App Store](https://img.shields.io/badge/iOS%20App%20Store-AI%20Pulse-0D96F6?logo=apple)](https://apps.apple.com/us/app/ai-pulse-coding-cost-tracker/id6786290416?mt=8)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20%2F%20iOS%2016%2B-lightgrey)]()
[![Swift](https://img.shields.io/badge/swift-6.0-orange)]()

**Your AI coding cost tracker.** See exactly what you spend on AI coding tools —
Claude Code, Cursor, Copilot, DeepSeek, and more — and whether the output is worth it.
**100% local — zero data leaves your machine.**

## Screenshots

| Dashboard · Today | Dashboard · This Week | Settings |
|:---:|:---:|:---:|
| ![Dashboard Today](docs/screenshots/macos-dashboard-today-en.jpg) | ![Dashboard This Week](docs/screenshots/macos-dashboard-week-en.jpg) | ![Settings](docs/screenshots/macos-settings-en.jpg) |

## Download

[![Download on the Mac App Store](https://tools.applemediaservices.com/api/badges/download-on-the-mac-app-store/black/en-us?size=250x83)](https://apps.apple.com/us/app/ai-pulse/id6786290416?mt=12)
[![Download on the App Store](https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83)](https://apps.apple.com/us/app/ai-pulse-coding-cost-tracker/id6786290416?mt=8)

- **macOS** — requires macOS 14 Sonoma or later
- **iOS** — requires iOS 16 or later, and the macOS version as its data source

💡 **Universal Purchase — buy once, use on both platforms.** A single purchase
covers iOS and macOS. If you already own the Mac version and still see a price
button on your iPhone or iPad, don't worry — as long as you're signed in with
the same Apple ID, the App Store will recognize your existing purchase and let
you download for free. You will never be charged twice.

## Features

### Dashboard

Your home screen — styled as a robot head — shows the full picture at a glance:

- **Today / This Week / 30 Days** — switch time ranges with one click
- **Donut chart** — subscription vs. API spending split, plus a per-provider breakdown
- **Trend chart** — daily costs stacked by API + subscription (Week and 30 Days tabs)
- **Tool & repo ranking** — which AI tools and projects cost the most, with **Cost Per Line (CPL)**
- **Live stats** — net lines of code, added/deleted lines, request count, and token usage
- **Balances & quotas** — remaining API balance and subscription utilization (e.g. Claude, Copilot) on the Today tab

### Dock

The Dock icon is a living gauge for your spending:

- **Spending ring** — a progress ring around the icon fills with today's spend vs. your daily rate
- **Badge** — today's total, right on the icon
- **Right-click stats menu** — today/week summaries and drill-downs by tool, provider, and repo
- **Gold pulse** — a brief glow whenever new data arrives

### iOS Companion

A read-only companion that mirrors your spending to your iPhone or iPad via iCloud —
today, this week, and 30-day trends, donut charts, and per-repo breakdowns. It never
collects or uploads anything on its own; it only reads what your Mac has synced.

| iOS Dashboard · Today | iOS Dashboard · 30 Days |
|:---:|:---:|
| ![iOS Dashboard Today](docs/screenshots/ios-dashboard-today-en.jpg) | ![iOS Dashboard 30 Days](docs/screenshots/ios-dashboard-30d-en.jpg) |

### Supported Tools

AI Pulse tracks 13 AI tools today across three collection methods:

| Collection method | Tools |
|---|---|
| **Log parsing** (token-level pricing) | Claude Code, aider, Codex CLI, OpenCode, Qwen Code |
| **Balance API** (exact balance deltas) | DeepSeek, OpenAI, Kimi, Zhipu (ChatGLM), Anthropic\* |
| **Subscription detection** (monthly fee, amortized) | Cursor, GitHub Copilot, Windsurf (+ Trae, Augment Code) |

\* Anthropic has no balance API, so its usage is estimated from token pricing.

## Getting Started

1. **Install** — download from the Mac App Store (requires macOS 14 or later).
2. **Onboarding** — on first launch, a short walkthrough detects your installed AI tools
   across four steps: AI providers, dev tools, repos, and a summary. Detected tools are
   enabled automatically.
3. **Grant Home access** — to read logs from Claude Code, Codex, OpenCode, Qwen, and aider
   inside the sandbox, allow Home-folder access when prompted.
4. **Add API keys** — Settings → Integrations → **AI Providers**. Keys are stored locally
   and validated with a live balance check.
5. **Choose plans** — Settings → Integrations → **Dev Tools** lets you pick your subscription
   plan (e.g. Cursor Pro) and preferred API key.
6. **Explore the Dashboard** — switch between Today, This Week, and 30 Days.
7. **Right-click the Dock icon** anytime for a quick stats menu.
8. **On the go?** Install the iOS companion with the same Apple ID — your spending
   syncs automatically via iCloud.

## Data & Privacy

- **100% local** — everything is processed on your Mac; no data leaves your machine.
- **API keys** are stored locally and used only to query your own balances.
- **iOS companion is read-only** — it never collects anything itself, and iCloud sync
  happens only between your own devices signed in with the same Apple ID.

## Requirements

- macOS 14 Sonoma or later
- The iOS companion requires iOS 16 or later (plus the macOS version as its data source)

## Related Projects

- [AI Pulse for Chrome](https://github.com/wxy/ai-pulse) — browser extension for
  web-based AI tools (ChatGPT, Claude.ai, DeepSeek Chat, and more)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, architecture, and how to
add new integrations.

## License

Apache-2.0
