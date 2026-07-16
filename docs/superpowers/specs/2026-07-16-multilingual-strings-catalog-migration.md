# Spec: Multilingual String Catalog Migration

**Date:** 2026-07-16
**Status:** Draft

## Motivation

Two App Store listing issues for v1.0:

1. **App Store shows only English** — the app supports zh+en at runtime via custom `I18n.swift` dictionaries, but App Store scans only standardized language markers (`CFBundleLocalizations`, `.lproj`, `.xcstrings`), none of which exist in the bundle.
2. **No multilingual breadth** — app should serve the global developer community with 10 languages.

Additionally, the Xcode project has accumulated two stale settings:
- `SWIFT_VERSION = 5.0` (should be `6.0` — codebase is already Swift 6–ready)
- `MACOSX_DEPLOYMENT_TARGET = 26.5` (invalid — should be `14.0`, matching `Package.swift` and `Info.plist`)

## Goals

- Migrate from custom `I18n.swift` dictionaries to Apple's standard String Catalog (`.xcstrings`)
- Support 10 languages: `en`, `zh-Hans`, `zh-Hant-TW`, `zh-Hant-HK`, `ja`, `ko`, `de`, `fr`, `es`, `pt-BR`
- Translate all ~200 strings with AI batch + manual review
- Keep translations concise to avoid layout breakage
- Fix `SWIFT_VERSION` 5.0 → 6.0 and `MACOSX_DEPLOYMENT_TARGET` 26.5 → 14.0

## Version

Bump to **1.1** (CFBundleShortVersionString → `1.1`, CFBundleVersion → `4`).

## Non-Goals

- Re-architecting the I18n runtime (language switching, `didChangeLanguage` notification) — stays as-is
- Plural/variation support (`.xcstrings` supports it, but we don't need it yet)
- Changing how `NSLocalizedString`/`String(localized:)` integrates with the existing lang-switch mechanism

## Architecture

### Before

```
I18n.swift
├── zh: [String: String]  (~200 entries)
├── en: [String: String]  (~200 entries)
├── getLang() / setLang()
└── t(_ key:) → dict[key]
```

Used as `I18n.t("menu.loading")` throughout the codebase.

### After

```
Localizable.xcstrings       ← NEW: Xcode-managed String Catalog
├── en (source)             ← default language, extracted from code
├── zh-Hans / zh-Hant-TW / zh-Hant-HK
├── ja / ko / de / fr / es / pt-BR

I18n.swift                  ← KEPT: language-switch runtime
├── getLang() / setLang()   ← unchanged
├── didChangeLanguage       ← unchanged
└── t(_ key:) → String(localized:key)  ← CHANGED: delegates to system
```

### Key Design Decision: Keep `I18n.t()`, Delegate to `String(localized:)`

We keep the `I18n.t(key)` public API and change its implementation to use `String(localized:key)`. This means:

- **All ~200 call sites remain untouched** — no sweeping replacement of `I18n.t("key")`
- Runtime language switching continues to work via the existing `didChangeLanguage` notification
- System `Bundle` localization machinery handles the catalog lookup
- `Info.plist` gets `CFBundleLocalizations` so App Store sees all 10 languages

### How Runtime Language Switching Works

`.xcstrings` is compiled at build time into the app bundle as optimized `.strings` files.
At runtime, `Bundle.localizedString(forKey:)` reads from those files.
The language is determined by `UserDefaults` `AppleLanguages` key.

```swift
// I18n.swift — after migration
static func setLang(_ lang: String) {
    langLock.lock()
    _currentLang = lang
    langLock.unlock()
    UserDefaults.standard.set(lang, forKey: langKey)
    // Tell Bundle to use the selected language
    UserDefaults.standard.set([lang], forKey: "AppleLanguages")
    NotificationCenter.default.post(name: didChangeLanguage, object: nil)
}

static func t(_ key: String) -> String {
    // Bundle.localizedString reads from the compiled .xcstrings
    return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}
```

- The `didChangeLanguage` notification still fires, and views that observe it rebuild themselves (existing mechanism unchanged).
- `AppleLanguages` UserDefault is already the standard way AppKit apps override the system language at runtime.
- `Bundle.localizedString` caches per-language — changing `AppleLanguages` invalidates the cache.

### String Catalog Structure

`Resources/Localizable.xcstrings` → single catalog with all 10 languages. Each string entry has:
- `key`: the localization key (same as current I18n dictionary keys, e.g. `"menu.loading"`)
- `sourceLanguage`: `en`
- `localizations`: per-language translations

### Builder Hint for Concise Translations

Add a `comment` field to each entry: `"⚠ Keep short — UI label, avoid layout overflow"` so translators (and future AI passes) are reminded.

## Files Changed

| File | Change |
|------|--------|
| `Resources/Localizable.xcstrings` | **NEW** — String Catalog with 10 languages |
| `Resources/Info.plist` | **ADD** `CFBundleLocalizations` array, fix `MACOSX_DEPLOYMENT_TARGET` reference |
| `Sources/Utils/I18n.swift` | **MODIFY** — `t()` delegates to `String(localized:)`, remove hardcoded dictionaries |
| `AIPulse/AIPulse.xcodeproj/project.pbxproj` | **FIX** `SWIFT_VERSION` → 6.0, `MACOSX_DEPLOYMENT_TARGET` → 14.0 |

## Language Set

| Code | Language | Notes |
|------|----------|-------|
| `en` | English | Source language (no change) |
| `zh-Hans` | 简体中文 | Keep existing translations |
| `zh-Hant-TW` | 繁體中文（台灣） | New |
| `zh-Hant-HK` | 繁體中文（香港） | New |
| `ja` | 日本語 | New — keep short, Japanese text can be verbose |
| `ko` | 한국어 | New |
| `de` | Deutsch | New — watch compound word length |
| `fr` | Français | New |
| `es` | Español | New |
| `pt-BR` | Português (Brasil) | New |

## Translation Process

1. Extract all ~200 keys from `I18n.swift` en dictionary
2. AI batch-translate to 8 target languages (zh-Hans already done)
3. Review: spot-check technical terms (provider names, "CPL", "token usage", etc.)
4. Populate `.xcstrings` with all translations
5. Verify build compiles with Swift 6

## Xcode Build Settings Fix

In `project.pbxproj`, both Debug and Release configurations:

```
SWIFT_VERSION = 6.0;           // was 5.0
MACOSX_DEPLOYMENT_TARGET = 14.0;  // was 26.5
```

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| `String(localized:)` with runtime lang-switch | Test zh↔en switch at runtime; may need `Bundle.localizedString(forKey:value:table:)` override |
| Xcode 15 vs 16 `.xcstrings` format | Use Xcode 16 (current toolchain) compatible format |
| Layout overflow with verbose translations | Add comment hints; review ja/de for compound words |
| Swift 6 strict concurrency | Code already has `nonisolated(unsafe)`, `@MainActor`, `NSLock` — verify build passes |
