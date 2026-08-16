# AI Pulse v1.2.6 — Spend Alert Accuracy & watchOS Polish

## What's New

- More accurate spend-surge and balance-drop alerts driven by the balance API
- watchOS now shows the app/CloudKit version and aligns the corner labels

## Fixes & Engineering

- Correct cache-token pricing in cost calculations
- Use Int64 session timestamps in the iCloud dashboard snapshot
- Normalize percentage formatting and localization
- Extract the cross-platform shared core into `AIPulseShared`

## Deployment Notes

- No CloudKit record type, field, index, or subscription changes
- `CKSchema.payloadVersion` remains `1.2.4`
- App Store submission should use `MARKETING_VERSION = 1.2.6` and
  `CURRENT_PROJECT_VERSION = 29`

## Verification

- Tests: `swift test` — 137 passed
- Builds:
  - macOS `AIPulse_macOS`
  - iOS `AIPulse_iOS`
  - watchOS `AIPulse_watchOS`
  - Widget `AIPulseWidgetExtension`
