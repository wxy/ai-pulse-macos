# AI Pulse v1.2.8 - Dashboard Stability

## What's New

- Faster, steadier switching and scrolling across Today, This Week, and 30 Days
- Charts now restart safely for each time range instead of animating between unrelated snapshots

## Fixes & Engineering

- Keep Today, Week, and 30-day dashboard snapshots independent to prevent stale cross-range state
- Suppress redundant dashboard refreshes and record API balance snapshots only when spend changes
- Add usage-event indexes and consolidate tool-detail queries to reduce 30-day snapshot latency
- Cache Dock pulse frames and reduce repeated trend-axis work during dashboard rendering
- Disable Thread Sanitizer in the shared macOS debug scheme

## Deployment Notes

- This is a macOS-only stability release; iOS, watchOS, and widget builds are unchanged
- No CloudKit record type, field, index, subscription, or record-name changes
- `CKSchema.payloadVersion` remains `1.2.4`
- App Store submission should use `MARKETING_VERSION = 1.2.8` and `CURRENT_PROJECT_VERSION = 31`

## Verification

- Tests: `swift test` - 163 passed
- Builds: macOS `AIPulse_macOS` Debug build for `platform=macOS`
