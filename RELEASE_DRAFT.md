# AI Pulse 2.0.0 — One Pulse Across Mac, iPhone, and Apple Watch

> Draft only. Do not publish until the remaining device acceptance checks pass.

## What's New

- A unified fact-first dashboard across macOS and the iPhone companion app
- iPhone, Apple Watch, iPhone widget, Watch widgets, and macOS widget support
- Independent Today, This Week, and 30 Days snapshots with aligned token and code-change rhythms
- Tool, model, repository, and captured-session details without fabricated cost estimates
- Current activity, observed balances, quotas, and declared subscriptions kept as separate facts
- Ten complete interface localizations: English, Simplified Chinese, Traditional Chinese for Taiwan and Hong Kong, Japanese, Korean, German, French, Spanish, and Brazilian Portuguese

## Privacy and Data Semantics

- Local logs and authorized Git repositories are processed on the Mac
- Private iCloud sync carries derived dashboard summaries to the user's own devices
- API keys are not included in synchronized dashboard payloads
- Missing or stale observations are not presented as zero usage
- Balance decreases remain native-currency sampling facts, not per-request charges

## Deployment Notes

- All Apple targets use version 2.0.0 (build 32)
- No Russian localization is included
- `Tokens`, `Lines`, currency codes, and explicit product identifiers intentionally remain stable where specified
- `Sources/Localizable.xcstrings` is the single localization source of truth
- No CloudKit schema or payload-version migration is introduced by the localization work

## Verification

- Localization validation: 743 active translatable keys, 10 locales, no missing translations, no stale entries, and matching format placeholders
- Tests: `swift test` — 419 executed, 4 optional real-data tests skipped, 0 failures
- macOS: `AIPulse_macOS` Debug and Release unsigned builds passed; both include the macOS widget
- Mobile suite: `AIPulse_iOS` Debug and Release simulator builds passed; the aggregate scheme includes the iPhone widget, Watch app, and Watch widget
- Product inspection: all six app surfaces contain the expected 10 localization bundles; app privacy manifests are packaged where required
- Device acceptance: macOS widget passed; iPhone, iPhone widget, Watch app, and Watch widget remain pending
