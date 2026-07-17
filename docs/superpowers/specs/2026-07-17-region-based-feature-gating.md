# Spec: Region-Based Feature Gating

**Date:** 2026-07-17
**Status:** Draft (deferred)

## Motivation

Certain AI service providers (e.g., OpenAI) are not legally available in certain regions (e.g., China). The app should not show these providers at all in restricted regions, rather than showing a "not available" message.

## Design

1. Add `restrictedRegions: Set<String>` to `ProviderDef` (ISO 3166-1 country codes)
2. Detect App Store region via `Storefront.current?.countryCode`
3. Filter out restricted providers in:
   - Integration list (Settings → Integrations)
   - API key input fields
   - Balance polling (`ApiPoller.fetchBalance`)
4. In restricted regions, the provider simply doesn't appear — no "unavailable" placeholder

## Implementation Notes

- Use `StoreKit.Storefront.current` for reliable region detection (not `Locale.current`)
- Fallback to `Locale.current.region?.identifier` if Storefront unavailable
- Cache the detected region to avoid repeated async calls
- Filter at UI layer AND at API call layer (defense in depth)

## Deferred

Implement after current release cycle.
