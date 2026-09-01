# AI Pulse v1.2.8 - Dashboard Stability

## What's New

- Faster, steadier switching and scrolling across Today, This Week, and 30 Days
- Charts now restart safely for each time range instead of animating between unrelated snapshots
- Fix an iOS crash when switching dashboard time ranges while snapshots refresh

## Fixes & Engineering

- Keep Today, Week, and 30-day dashboard snapshots independent to prevent stale cross-range state
- Read range-local iOS snapshots directly and rebuild range-specific Charts after data changes
- Suppress redundant dashboard refreshes and record API balance snapshots only when spend changes
- Add usage-event indexes and consolidate tool-detail queries to reduce 30-day snapshot latency
- Cache Dock pulse frames and reduce repeated trend-axis work during dashboard rendering
- Disable Thread Sanitizer in the shared macOS debug scheme

## Deployment Notes

- Align iOS, watchOS, and widget builds with macOS at 1.2.8 (build 31)
- watchOS and widget behavior is unchanged
- No CloudKit record type, field, index, subscription, or record-name changes
- `CKSchema.payloadVersion` remains `1.2.4`
- App Store submission should use `MARKETING_VERSION = 1.2.8` and `CURRENT_PROJECT_VERSION = 31`

## Verification

- Tests: `swift test` - 163 passed
- Builds: macOS `AIPulse_macOS` Debug build for `platform=macOS`
- Builds: iOS `AIPulse_iOS` Debug build for a connected iPhone; the iOS scheme also builds the embedded watchOS app and widget extension
