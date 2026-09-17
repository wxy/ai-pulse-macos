# Contributing to AI Pulse

Current scope: macOS 2.0 consumption pulse. Read the [product design](docs/PRODUCT_DESIGN.md), [data contract](docs/data-facts-and-surfaces.md), and [closure plan](docs/macos-v2-closure-plan.md) first. iOS, watchOS, and Widget development is paused until macOS acceptance; their existing code is not proof that they support the current payload.

## Contributor License Agreement

By submitting a contribution, you agree to the [Individual Contributor License Agreement](CLA.md): the project may use it in the paid App Store product, while you keep copyright to your code. Contributions have no expectation of payment. This applies to third-party contributors, not the project owner's or maintainers' own work. Pull requests are not merged until the CLA is accepted; maintainers may request explicit confirmation.

## Build and verification

Use a Mac with the supported Xcode toolchain and macOS 14 or later. Open `AIPulse/AIPulse.xcodeproj`, scheme `AIPulse_macOS`. Local verification commands:

```sh
swift test
xcodebuild -project AIPulse/AIPulse.xcodeproj -scheme AIPulse_macOS -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build -quiet
xcodebuild -project AIPulse/AIPulse.xcodeproj -scheme AIPulse_macOS -configuration Release -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build -quiet
git diff --check
```

These are local tests and unsigned builds, not signed distribution or runtime acceptance. Normal app launches may access configured providers, migrate the local database, and start collection. Do not replace a user's running app or use their production database for fixtures. Dedicated Debug runtime QA uses a separate bundle and database; its disabled collectors cannot prove real collection works. See [runtime evidence and its limits](docs/macos-runtime-qa-2026-09-17.md).

CI currently performs Swift parsing and shell/Python/workflow syntax checks on Ubuntu; it does not build the macOS app or run the full Swift tests. A green CI check cannot replace local builds, tests, or runtime checks. Do not hard-code a historical test count as coverage.

## Repository layout

```text
Sources/                  macOS app
  App/                    Startup, application lifecycle and QA isolation
  Engine/                 Current pulse, refresh, health and sound policy
  GitMonitor/             Local commit and code facts
  Ingest/                 Logs, provider observations and model descriptors
  Store/                  SQLite, period statistics and derived cache
  Sync/                   Optional private CloudKit summaries
  UI/                     Dashboard, details, menus, Dock and settings
Packages/AIPulseShared/    Current shared payload and period contract
Resources/                Visual assets and model-catalog.json
Resources/Sounds/         Local-only audio; provenance document is tracked
Tests/                    Parser, accounting, period, Git, sound and store tests
Suites/                   Existing paused clients; not current acceptance scope
docs/archive/             Historical specifications and promotional copy
```

## Data and feedback rules

- Tokens are source-aware facts. Cache and reasoning meanings differ by host; test normalization against original fields. ModelCatalog identifies models and providers, not prices or account payments.
- Balance decreases are interval net changes, kept in original currency. Declared monthly fees are separate context, never a daily charge. No token pricing, cost-per-line, per-session bills, forecasts, or amount arbitration.
- Use explicit local period bounds and a common observation cutoff. Retain separate today/week/30-day snapshots; switching selects one, never overwrites another. Query failure or stale collection is not zero activity.
- Git root identity is the canonical full path, authorized inside configured development directories. Display labels are not keys. Commits and line changes are separate facts; neither proves AI authorship or value.
- Worker-queue event commits precede checkpoint advancement. Failed batches retry through deduplication; complete-line cursors survive partial UTF-8 writes and restarts. Replaying history or refreshing UI is not new consumption.
- Current pulse has independent freshness, not the selected period's totals. Dock and menus must use the same current-state semantics. Mute applies to every app sound; automatic cues and explicit previews have distinct policies.
- Preserve original usage, balances, quotas, Git history, preferences, and manual assets. Invalidate only derived state when contracts change; 2.0 does not require 1.0 financial payload compatibility.

## Integration and sync changes

Register integrations in `Sources/Engine/IntegrationRegistry.swift`; parsers live in `Sources/Ingest/LogParsers/`. Test absent components, duplicate replay, source identity, repository authorization, future timestamps, and failure recovery. Do not infer payments from tool installation or model names.

Current CloudKit payload is 2.0.0. Period records and current pulse are separate contracts. Private sync can send derived summaries including repository paths; API keys are not included. Debug cloud writes are disabled. Changes to the macOS contract may invalidate paused clients; record that limitation instead of silently adding compatibility or claiming cross-platform support.

## Distribution and assets

Shipping requires separate signed-build, permission, cloud, continuous-operation, sound, and user-experience acceptance. Release scripts can create external artifacts; review them and obtain explicit authority before signing, uploading or releasing. Local App Store drafts are not published metadata.

Audio stays local and is bundled for functional cues, not uploaded as repository files or standalone assets. A fresh clone must obtain the recordings described in [sound provenance](Resources/Sounds/README.md); code licensing does not license those recordings. Preserve local audio before repository cleanup.

Source code: [Apache-2.0](LICENSE). Historical contribution guidance is [archived](docs/archive/CONTRIBUTING-v1.md), not the current implementation contract.
