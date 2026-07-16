# Multilingual String Catalog Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate from custom I18n.swift dictionaries to Apple String Catalog (.xcstrings), add 8 new languages, fix build settings, bump to 1.1.

**Architecture:** Keep `I18n.t(key)` public API unchanged; replace dictionary lookup with `Bundle.localizedString(forKey:)` which reads from compiled `.xcstrings`. Language switching uses `AppleLanguages` UserDefaults. "Follow System" mode (stored as `"auto"`) removes the override so macOS system language takes effect. String Catalog (`Localizable.xcstrings`) becomes the single source of truth for all translations.

**UX:** Settings → General → Language dropdown: "Follow System" (default) + 10 manual choices. Picker changed from segmented control to menu-style dropdown.

**Tech Stack:** Swift 6, Xcode 16, AppKit + SwiftUI, String Catalogs (.xcstrings)

## Global Constraints

- `SWIFT_VERSION = 6.0`
- `MACOSX_DEPLOYMENT_TARGET = 14.0`
- `CFBundleShortVersionString = 1.1`, `CFBundleVersion = 4`
- 10 languages: en, zh-Hans, zh-Hant-TW, zh-Hant-HK, ja, ko, de, fr, es, pt-BR
- Translations MUST be concise — avoid layout overflow
- All ~200 existing `I18n.t("key")` call sites remain unchanged
- Build must pass with Swift 6 strict concurrency

---

### Task 1: Fix Xcode Build Settings

**Files:**
- Modify: `AIPulse/AIPulse.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: Correct build settings for subsequent tasks

- [ ] **Step 1: Fix MACOSX_DEPLOYMENT_TARGET (project-level, Debug + Release)**

In `project.pbxproj`, find the Debug project-level config (line ~238) and change:
```
MACOSX_DEPLOYMENT_TARGET = 26.5;
```
to:
```
MACOSX_DEPLOYMENT_TARGET = 14.0;
```

Same change for Release project-level config (line ~298).

- [ ] **Step 2: Fix SWIFT_VERSION (target-level, Debug + Release)**

Find the Debug target config (line ~346) and change:
```
SWIFT_VERSION = 5.0;
```
to:
```
SWIFT_VERSION = 6.0;
```

Same change for Release target config (line ~390).

- [ ] **Step 3: Bump version numbers (target-level, Debug + Release)**

In Debug target config, change:
```
CURRENT_PROJECT_VERSION = 3;
```
to:
```
CURRENT_PROJECT_VERSION = 4;
```
And:
```
MARKETING_VERSION = 1.0;
```
to:
```
MARKETING_VERSION = 1.1;
```

Same changes for Release target config.

- [ ] **Step 4: Verify build settings**

```bash
cd AIPulse && xcodebuild -project AIPulse.xcodeproj -scheme AIPulse -showBuildSettings 2>/dev/null | grep -E "SWIFT_VERSION|MACOSX_DEPLOYMENT_TARGET|MARKETING_VERSION|CURRENT_PROJECT_VERSION"
```

Expected output includes:
```
SWIFT_VERSION = 6.0
MACOSX_DEPLOYMENT_TARGET = 14.0
MARKETING_VERSION = 1.1
CURRENT_PROJECT_VERSION = 4
```

- [ ] **Step 5: Commit**

```bash
git add AIPulse/AIPulse.xcodeproj/project.pbxproj
git commit -m "chore: fix build settings — Swift 6.0, macOS 14.0 target, bump to 1.1"
```

---

### Task 2: Add CFBundleLocalizations to Info.plist

**Files:**
- Modify: `AIPulse/AIPulse-Info.plist`

**Interfaces:**
- Produces: `CFBundleLocalizations` array declaring all 10 supported languages

- [ ] **Step 1: Add CFBundleLocalizations**

In `AIPulse/AIPulse-Info.plist`, add after `<dict>`:

```xml
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>zh-Hans</string>
		<string>zh-Hant-TW</string>
		<string>zh-Hant-HK</string>
		<string>ja</string>
		<string>ko</string>
		<string>de</string>
		<string>fr</string>
		<string>es</string>
		<string>pt-BR</string>
	</array>
```

- [ ] **Step 2: Verify the plist is valid**

```bash
plutil -lint AIPulse/AIPulse-Info.plist
```

Expected: `AIPulse/AIPulse-Info.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add AIPulse/AIPulse-Info.plist
git commit -m "feat: declare 10 supported languages in Info.plist"
```

---

### Task 3: Create String Catalog from Existing Dictionaries

**Files:**
- Create: `Resources/Localizable.xcstrings`
- Read: `Sources/Utils/I18n.swift` (existing en + zh-Hans dictionaries)

**Interfaces:**
- Produces: `Localizable.xcstrings` with all ~200 keys, en (source) and zh-Hans populated

- [ ] **Step 1: Create Python extraction script**

Create a temporary script (run once, not committed):

```python
#!/usr/bin/env python3
"""Extract I18n.swift dictionaries → Localizable.xcstrings initial skeleton."""
import json, re, subprocess, sys

i18n_path = "Sources/Utils/I18n.swift"
with open(i18n_path) as f:
    text = f.read()

def extract_dict(var_name):
    """Extract [String: String] dict content for given variable."""
    pattern = rf'{var_name}:\s*\[String:\s*String\]\s*=\s*\[(.*?)\]'
    match = re.search(pattern, text, re.DOTALL)
    if not match:
        print(f"ERROR: could not find {var_name} dict", file=sys.stderr)
        sys.exit(1)
    content = match.group(1)
    pairs = {}
    key_pattern = re.compile(r'"([^"]+)"\s*:\s*"((?:[^"\\]|\\.)*)"')
    for m in key_pattern.finditer(content):
        key, value = m.group(1), m.group(2)
        value = value.replace('\\"', '"').replace('\\n', '\n')
        pairs[key] = value
    return pairs

en = extract_dict("en")
zh = extract_dict("zh")

print(f"Extracted {len(en)} en keys, {len(zh)} zh keys")

# Verify all zh keys exist in en
missing = set(zh.keys()) - set(en.keys())
extra = set(en.keys()) - set(zh.keys())
if missing:
    print(f"WARNING: zh keys not in en: {missing}")
if extra:
    print(f"INFO: en-only keys: {extra}")

xcstrings = {
    "sourceLanguage": "en",
    "strings": {},
    "version": "1.0"
}

COMMENT = "ⓘ Keep translation short — UI label, avoid layout overflow"
LANGUAGES = ["en", "zh-Hans", "zh-Hant-TW", "zh-Hant-HK", "ja", "ko", "de", "fr", "es", "pt-BR"]

for key in sorted(en.keys()):
    entry = {
        "extractionState": "manual",
        "comment": COMMENT,
        "localizations": {}
    }
    # Populate source language (en)
    entry["localizations"]["en"] = {
        "stringUnit": {
            "state": "translated",
            "value": en[key]
        }
    }
    # Populate zh-Hans if available
    if key in zh:
        entry["localizations"]["zh-Hans"] = {
            "stringUnit": {
                "state": "translated",
                "value": zh[key]
            }
        }
    # Mark remaining 8 languages as needing translation
    for lang in LANGUAGES:
        if lang not in ("en", "zh-Hans"):
            entry["localizations"][lang] = {
                "stringUnit": {
                    "state": "needs_review",
                    "value": ""
                }
            }
    xcstrings["strings"][key] = entry

output_path = "Resources/Localizable.xcstrings"
with open(output_path, "w") as f:
    json.dump(xcstrings, f, indent=2, ensure_ascii=False)

print(f"Written {len(en)} entries to {output_path}")
```

- [ ] **Step 2: Run extraction script**

```bash
python3 /tmp/extract_i18n_to_xcstrings.py
```

Expected: `Extracted ~200 en keys, ~200 zh keys. Written ~200 entries to Resources/Localizable.xcstrings`

- [ ] **Step 3: Commit skeleton**

```bash
git add Resources/Localizable.xcstrings
git commit -m "feat: add Localizable.xcstrings skeleton with en + zh-Hans"
```

---

### Task 4: Populate Translations for 8 New Languages

**Files:**
- Modify: `Resources/Localizable.xcstrings` (populate zh-Hant-TW, zh-Hant-HK, ja, ko, de, fr, es, pt-BR)

**Interfaces:**
- Consumes: `Resources/Localizable.xcstrings` from Task 3
- Produces: Complete `.xcstrings` with all 10 languages

- [ ] **Step 1: Run AI batch translation**

Read `Resources/Localizable.xcstrings`, extract all keys whose en `value` is populated but target language `value` is empty. For each target language (zh-Hant-TW, zh-Hant-HK, ja, ko, de, fr, es, pt-BR), translate all ~200 strings from English.

Guidelines embedded in prompt:
- Keep translations concise — these are UI labels, buttons, menu items
- Match the tone of the English (casual/informative, not formal)
- Preserve placeholders: `%@`, `%d`, `$%@`
- Do NOT translate: `AI Pulse` brand name, provider names (Claude Code, aider, Copilot, etc.), technical acronyms (CPL, API, CPLK, DB), file paths
- For ja/ko/de: prefer shorter alternatives when available — compound words can overflow UI

Save the complete catalog back to `Resources/Localizable.xcstrings`.

- [ ] **Step 2: Review critical translations**

Spot-check these keys across all languages for accuracy:

| Key | Critical because |
|-----|-----------------|
| `settings.language_auto` | New key — "Follow System" label for picker |
| `integrations.group_api_key` | Complex UI label (AI Provider Balance) |
| `dashboard.cpl_card` | Technical term (CPL — Cost Per K Lines) |
| `demo.banner` | User-facing, contains emoji |
| `onboarding.welcome` | First impression for new users |
| `health.critical` | Error state — must be clear |
| `settings.language_zh` / `settings.language_en` | Language names in each target language |

- [ ] **Step 3: Commit**

```bash
git add Resources/Localizable.xcstrings
git commit -m "feat: add translations for 8 languages (ja, ko, de, fr, es, pt-BR, zh-Hant-TW, zh-Hant-HK)"
```

---

### Task 5: Modify I18n.swift to Delegate to String Catalog

**Files:**
- Modify: `Sources/Utils/I18n.swift`

**Interfaces:**
- Consumes: `Localizable.xcstrings` in bundle
- Produces: `I18n.t(key)` returns `Bundle.main.localizedString(forKey:)`; `I18n.setLang()` also sets `AppleLanguages` UserDefault

- [ ] **Step 1: Replace I18n.swift implementation**

Replace the entire file content:

```swift
import Foundation

enum I18n {
    static let didChangeLanguage = Notification.Name("I18nDidChangeLanguage")

    private static let langKey = "app_language"
    private static let langLock = NSLock()
    private static nonisolated(unsafe) var _currentLang: String?

    /// All languages the app supports (for Settings picker).
    /// Tag is the language code; label is shown in native script.
    static let supportedLanguages: [(code: String, label: String)] = [
        ("auto",           "跟随系统 / Follow System"),  // placeholder — UI uses t("settings.language_auto")
        ("en",             "English"),
        ("zh-Hans",        "简体中文"),
        ("zh-Hant-TW",     "繁體中文（台灣）"),
        ("zh-Hant-HK",     "繁體中文（香港）"),
        ("ja",             "日本語"),
        ("ko",             "한국어"),
        ("de",             "Deutsch"),
        ("fr",             "Français"),
        ("es",             "Español"),
        ("pt-BR",          "Português (Brasil)"),
    ]

    /// Set the app language. "auto" = follow system; otherwise an explicit code.
    /// Posts `didChangeLanguage` notification so views rebuild.
    static func setLang(_ lang: String) {
        langLock.lock()
        _currentLang = lang
        langLock.unlock()
        UserDefaults.standard.set(lang, forKey: langKey)
        if lang == "auto" {
            // Remove override — let system language take effect
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }
        NotificationCenter.default.post(name: didChangeLanguage, object: nil)
    }

    /// Get the stored language preference. "auto" = follow system; nil → auto.
    /// Resolved language for actual display can differ from this value.
    static func getLang() -> String {
        langLock.lock()
        if let l = _currentLang { langLock.unlock(); return l }
        langLock.unlock()

        let saved = UserDefaults.standard.string(forKey: langKey)
        let lang = saved ?? "auto"

        langLock.lock()
        _currentLang = lang
        langLock.unlock()
        return lang
    }

    /// The effectively resolved language code (never "auto").
    /// Used internally when we need to know which language is actually active.
    static func resolvedLang() -> String {
        let stored = getLang()
        if stored != "auto" { return stored }
        let preferred = Locale.preferredLanguages.first ?? ""
        if preferred.hasPrefix("zh-Hant-HK") { return "zh-Hant-HK" }
        if preferred.hasPrefix("zh-Hant")    { return "zh-Hant-TW" }
        if preferred.hasPrefix("zh")         { return "zh-Hans" }
        if preferred.hasPrefix("ja")         { return "ja" }
        if preferred.hasPrefix("ko")         { return "ko" }
        if preferred.hasPrefix("de")         { return "de" }
        if preferred.hasPrefix("fr")         { return "fr" }
        if preferred.hasPrefix("es")         { return "es" }
        if preferred.hasPrefix("pt")         { return "pt-BR" }
        return "en"
    }

    /// Localized string for key. Reads from compiled .xcstrings via Bundle.
    /// Bundle uses AppleLanguages (or system locale if "auto") to pick language.
    static func t(_ key: String) -> String {
        return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}
```

- [ ] **Step 2: Verify I18n.swift compiles**

```bash
cd AIPulse && xcodebuild -project AIPulse.xcodeproj -scheme AIPulse -configuration Debug -derivedDataPath /tmp/ai-pulse-l10n-build build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Spot-check call sites still compile**

Verify that typical `I18n.t("...")` calls in SwiftUI views still work (they aren't affected by the change, but let's confirm):

```bash
grep -c 'I18n\.t(' Sources/UI/Dashboard/DashboardView.swift
grep -c 'I18n\.t(' Sources/UI/Settings/SettingsView.swift
```

No errors expected — the `I18n.t(_:)` signature is unchanged.

- [ ] **Step 4: Commit**

```bash
git add Sources/Utils/I18n.swift
git commit -m "refactor: I18n.t() delegates to String Catalog via Bundle.localizedString"
```

---

### Task 6: Update Settings Language Picker

**Files:**
- Modify: `Sources/UI/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `I18n.getLang()` returns `"auto"` or language code; `I18n.supportedLanguages` array
- Produces: Dropdown picker with "Follow System" + 10 languages

- [ ] **Step 1: Replace segmented picker with menu dropdown**

In `Sources/UI/Settings/SettingsView.swift`, find the language picker section (around line 192–201):

**Old code:**
```swift
HStack {
    Text(I18n.t("general.language_label"))
        .frame(width: 100, alignment: .leading)
    Picker("", selection: $lang) {
        Text(I18n.t("settings.language_zh")).tag("zh")
        Text(I18n.t("settings.language_en")).tag("en")
    }
    .pickerStyle(.segmented)
    .frame(width: 160)
}
```

Replace with:
```swift
HStack {
    Text(I18n.t("general.language_label"))
        .frame(width: 100, alignment: .leading)
    Picker("", selection: $lang) {
        ForEach(I18n.supportedLanguages, id: \.code) { lang in
            if lang.code == "auto" {
                Text(I18n.t("settings.language_auto")).tag("auto")
            } else {
                Text(lang.label).tag(lang.code)
            }
        }
    }
    .pickerStyle(.menu)
    .frame(width: 200)
}
```

- [ ] **Step 2: Update the initial State and binding**

The `@State private var lang = I18n.getLang()` at line 9 is fine — `getLang()` now returns `"auto"` or a language code. The `langBinding` at lines 19–21 needs updating:

**Old:**
```swift
var langBinding: Binding<String> {
    Binding(get: { lang }, set: { v in lang = v; I18n.setLang(v) })
}
```

The binding is no longer used directly (Picker uses `$lang`), so remove `langBinding` and replace references. Check if `langBinding` is used elsewhere in the file:

```bash
grep -n "langBinding" Sources/UI/Settings/SettingsView.swift
```

If only used in the old picker, remove the `langBinding` computed property entirely. If used elsewhere, update accordingly.

- [ ] **Step 3: Add new i18n key for "Follow System"**

Add to both `I18n.swift` old dictionaries's corresponding `.xcstrings` entries (Task 4 should already include this key). If not, add:

Key: `settings.language_auto`
- en: `"Follow System"`
- zh-Hans: `"跟随系统"`

- [ ] **Step 4: Build and verify the picker looks correct**

```bash
cd AIPulse && xcodebuild -project AIPulse.xcodeproj -scheme AIPulse -configuration Debug -derivedDataPath /tmp/ai-pulse-l10n-build build 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/Settings/SettingsView.swift
git commit -m "feat: language picker → dropdown with Follow System + 10 languages"
```

---

### Task 7: Verify Build and Runtime Behavior (I18n + Settings)

**Files:**
- No code changes — verification only

**Interfaces:**
- Consumes: All changes from Tasks 1–5

- [ ] **Step 1: Full clean build with Swift 6**

```bash
cd AIPulse && xcodebuild -project AIPulse.xcodeproj -scheme AIPulse -configuration Debug -derivedDataPath /tmp/ai-pulse-l10n-build clean build 2>&1 | grep -E "error:|warning:|BUILD"
```

Expected: `BUILD SUCCEEDED` with zero errors.

- [ ] **Step 2: Run tests**

```bash
cd AIPulse && xcodebuild -project AIPulse.xcodeproj -scheme AIPulse -configuration Debug -derivedDataPath /tmp/ai-pulse-l10n-build test 2>&1 | grep -E "Test Suite|passed|failed|error:"
```

Expected: All tests pass.

- [ ] **Step 3: Verify .xcstrings is in the built bundle**

```bash
find /tmp/ai-pulse-l10n-build/Build/Products/Debug -name "*.lproj" -type d 2>/dev/null
# Or check for compiled .strings files
find /tmp/ai-pulse-l10n-build/Build/Products/Debug -path "*/Localizable*" -type f 2>/dev/null
```

Expected: At least one `.lproj` directory or compiled `.strings` file exists in the bundle.

- [ ] **Step 4: Verify Info.plist has CFBundleLocalizations**

```bash
plutil -p /tmp/ai-pulse-l10n-build/Build/Products/Debug/AIPulse.app/Contents/Info.plist 2>/dev/null | grep CFBundleLocalizations
# Alternative: use defaults read
defaults read /tmp/ai-pulse-l10n-build/Build/Products/Debug/AIPulse.app/Contents/Info.plist CFBundleLocalizations 2>/dev/null
```

Expected: Array of 10 language codes.

- [ ] **Step 5: Commit (if any fixes needed) or mark complete**

If all checks pass, no additional commit needed.

---

### Task 8: Smoke Test Runtime

**Files:**
- No code changes — manual verification

- [ ] **Step 1: Launch the app**

```bash
open /tmp/ai-pulse-l10n-build/Build/Products/Debug/AIPulse.app
```

- [ ] **Step 2: Verify en → zh-Hans language switch works**

1. Open Settings → General
2. Switch language to 中文
3. Confirm Dashboard and Settings UI reflect Chinese text
4. Switch back to English
5. Confirm UI reverts to English

- [ ] **Step 3: Verify new language fallback**

If macOS system language is set to `ja` (Japanese), launch the app — japasese translations should show. If not, check that fallback to English works.

- [ ] **Step 4: Verify no layout breakage**

Check Dashboard cards, Settings labels, Menu bar items — no text truncation or overflow. Especially check de (long compound words) and ja (taller character height).

---

### Task 9: Final Review & Cleanup

- [ ] **Step 1: Run tests one final time**

```bash
swift test 2>&1
```

Expected: All tests pass.

- [ ] **Step 2: Verify git status is clean**

```bash
git status
```

- [ ] **Step 3: Final commit if any cleanup needed**

```bash
git add -A && git diff --cached --stat
git commit -m "chore: final cleanup for multilingual string catalog migration"
```
