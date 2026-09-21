# AI Pulse 2.0 screenshot matrix

This is the approved baseline from the completed 2.0 screenshot run. Reconfirm it when a later release changes devices, store requirements, or product scope.

## Locales

Use one folder per locale, with these exact identifiers:

`en`, `zh-Hans`, `zh-Hant-TW`, `zh-Hant-HK`, `ja`, `ko`, `de`, `fr`, `es`, `pt-BR`

## Output root

`artifacts/app-store-screenshots/2.0/<platform>/<locale>/`

Screenshot artifacts remain untracked by default.

## Required files

| Platform | Screen | Fixed filename | Expected pixels |
| --- | --- | --- | --- |
| iPhone | 30-day dashboard | `iphone-30d.png` | 1206 × 2622 |
| iPad | 30-day dashboard | `ipad-30-days.png` | 2064 × 2752 |
| Watch | Today dashboard | `watch-today.png` | 416 × 496 |
| macOS | 30-day dashboard | `mac-30-days.png` | 1080 × 1280 |
| macOS | GitHub Copilot tool detail | `mac-tool-detail.png` | 1080 × 1280 |
| macOS | Developer Tools, first screen | `mac-settings-developer-tools.png` | 1624 × 1288 |
| macOS | Accounts & fixed costs, first screen | `mac-settings-account-fixed-costs.png` | 1624 × 1288 |

Total: 70 PNG files.

## Product and capture decisions

- iPhone and iPad use 30 days because Today can be visually sparse.
- Watch uses Today because it is the compact single-screen product surface.
- The iPad's 600pt regular-width content cap is runtime product behavior, not a screenshot-only transform.
- macOS omits widgets and the menu bar to avoid tiny content and unrelated desktop pixels.
- macOS screenshots use an opaque black canvas behind the irregular dashboard/window shadow.
- Settings pages capture only the first visible screen; do not scroll to create a composite.
- Tool detail uses a neutral GitHub Copilot session view rather than a Codex session that might expose prompt content.
- API keys must remain secure-field bullets. Account observation amounts may be real, but never equate them with a complete bill or remaining quota.

## Visual acceptance

- Correct locale and time range are visibly selected.
- No truncation that changes meaning; investigate unexpected ellipses rather than assuming they are harmless.
- No loading, expired, unavailable, demo, or unsupported state unless that is the intended fact.
- Data should be representative without being fabricated. If the user approves staged data, label it as staged in the handoff.
- Mobile PNGs may contain an alpha channel only when every pixel is fully opaque. macOS outputs must not contain alpha.
- No desktop clutter, notifications, permission sheets, selection rings, or debug overlays.
