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

## Store Copy Handoff

- languages: en, zh-Hans, zh-Hant-TW, zh-Hant-HK, ja, ko, de, fr, es, pt-BR
- store_copy_contract:
  - promotional_text_max_chars: 170
  - description_max_chars: 4000
  - what_s_new_max_chars: 4000
  - keywords_max_chars: 100
  - plain_text_only: true
  - allowed_formatting: simple bullets and section separators only
  - promotional_text_before_description: true
  - separator_between_promotional_and_description: false
- version: 1.2.6
- tag: v1.2.6
- platforms: macOS, iOS, watchOS
- app_store_ids: {macOS: 6786290416, iOS: TBD}
- headline_en: More accurate spend alerts and clearer watchOS version info
- headline_zh: 更准确的支出告警与更清晰的 watchOS 版本信息
- features_en:
  - Spend-surge and balance-drop alerts now use the balance API for more accurate thresholds
  - watchOS displays the app and CloudKit version and aligns corner labels
- features_zh:
  - 花费激增与余额骤降告警现在基于余额 API，阈值更准确
  - watchOS 显示应用与 CloudKit 版本，并对齐角落标签
- fixes_en:
  - Correct cache-token pricing
  - Use Int64 session timestamps in the iCloud snapshot
  - Normalize percentage formatting and localization
  - Extract cross-platform shared core into AIPulseShared
- fixes_zh:
  - 修正缓存 token 计价
  - 在 iCloud 快照中使用 Int64 会话时间戳
  - 统一百分比格式与本地化
  - 抽取跨平台共享核心 AIPulseShared
- deployment_notes:
  - No CloudKit schema changes
  - Payload version remains 1.2.4
- verification:
  - tests: 137 passed
  - builds: macOS, iOS, watchOS, widget passed
- links:
  - GitHub: https://github.com/wxy/ai-pulse-macos
  - App Store: https://apps.apple.com/app/id6786290416
