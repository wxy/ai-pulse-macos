#!/usr/bin/env python3
"""Validate the shared String Catalog used by every AI Pulse surface.

Also inventories the inline zh/en bilingual pairs (pulseText / SetupCopy.text /
WidgetCopy.text / I18n.prototype call shapes) that the string catalog does not
cover yet: `--dump-inline PATH` writes the migration worklist as JSON, and the
default run enforces basic invariants so a broken pair cannot land silently.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Sources" / "Localizable.xcstrings"
SUPPORTED_LOCALES = (
    "en",
    "zh-Hans",
    "zh-Hant-TW",
    "zh-Hant-HK",
    "ja",
    "ko",
    "de",
    "fr",
    "es",
    "pt-BR",
)
TRANSLATED_LOCALES = SUPPORTED_LOCALES[1:]
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|(?:\.\d+)?f|%)")
RAW_PERCENT_FORMAT = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|(?:\.\d+)?f)%%")
SIMPLE_PERCENT_INTERPOLATION = re.compile(
    r'Text\(\s*"\\\([A-Za-z_][A-Za-z0-9_.]*\)%"'
)
CJK = re.compile(r"[\u4e00-\u9fff]")
# A Chinese string literal followed by ", <string literal>" on one line —
# the shape of every inline bilingual call site. Line-scoped on purpose:
# cross-line matching would need real Swift parsing to avoid false pairs.
INLINE_PAIR = re.compile(r'"((?:[^"\\\n]|\\.)*)"\s*,\s*"((?:[^"\\\n]|\\.)*)"')


def placeholders(value: str) -> list[str]:
    return sorted(PLACEHOLDER.findall(value))


def strip_line_comment(line: str) -> str:
    """Cut a trailing // comment, ignoring // inside string literals."""
    masked = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    cut = masked.find("//")
    return line if cut < 0 else line[:cut]


def scan_inline_pairs() -> list[dict]:
    """Collect inline zh/en pairs from UI-layer Swift sources."""
    entries: list[dict] = []
    for swift_root in ("Sources", "Suites", "AIPulse/AIPulseMacWidget"):
        for path in (ROOT / swift_root).rglob("*.swift"):
            relative = str(path.relative_to(ROOT))
            for number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(), 1
            ):
                for match in INLINE_PAIR.finditer(strip_line_comment(line)):
                    zh, en = match.group(1), match.group(2)
                    if not CJK.search(zh):
                        continue
                    entries.append(
                        {"file": relative, "line": number, "zh": zh, "en": en}
                    )
    return entries


def main() -> int:
    dump_path = None
    if "--dump-inline" in sys.argv:
        dump_path = Path(sys.argv[sys.argv.index("--dump-inline") + 1])

    document = json.loads(CATALOG.read_text(encoding="utf-8"))
    failures: list[str] = []
    checked = 0

    format_only_keys = {"%@ · %@ %@ · %@ %@ · %@", "%lld %@"}

    if document.get("sourceLanguage") != "en":
        failures.append("sourceLanguage must be en")

    for key, entry in document.get("strings", {}).items():
        if "ru" in entry.get("localizations", {}):
            failures.append(f"{key!r}: unexpected ru localization")
        if entry.get("extractionState") == "stale":
            failures.append(f"{key!r}: stale entry must be removed or marked manual")
        if key in format_only_keys and entry.get("shouldTranslate") is not False:
            failures.append(f"{key!r}: format-only composition must not be translated")
        if entry.get("shouldTranslate") is False:
            continue
        checked += 1
        source = (
            entry.get("localizations", {})
            .get("en", {})
            .get("stringUnit", {})
            .get("value", key)
        )
        if RAW_PERCENT_FORMAT.search(source):
            failures.append(
                f"{key!r}: format the percentage in Swift and pass it as a string placeholder"
            )
        expected_placeholders = placeholders(source)
        for locale in TRANSLATED_LOCALES:
            unit = entry.get("localizations", {}).get(locale, {}).get("stringUnit", {})
            value = unit.get("value")
            if not isinstance(value, str) or not value.strip():
                failures.append(f"{key!r}: missing {locale}")
                continue
            if unit.get("state") != "translated":
                failures.append(f"{key!r}: {locale} is not marked translated")
            if RAW_PERCENT_FORMAT.search(value):
                failures.append(
                    f"{key!r}: {locale} embeds a raw percent sign in a format string"
                )
            if placeholders(value) != expected_placeholders:
                failures.append(
                    f"{key!r}: {locale} placeholders {placeholders(value)} != {expected_placeholders}"
                )

    swift_roots = ("Sources", "Suites", "AIPulse/AIPulseMacWidget")
    percent_formatters = {
        ROOT / "Sources" / "Utils" / "I18n.swift",
        ROOT / "Suites" / "Shared" / "I18n" / "I18n.swift",
    }
    for swift_root in swift_roots:
        for path in (ROOT / swift_root).rglob("*.swift"):
            source = path.read_text(encoding="utf-8")
            relative = path.relative_to(ROOT)
            if path not in percent_formatters and ".formatted(.percent" in source:
                failures.append(
                    f"{relative}: format percentages through I18n.percent"
                )
            if 'String(format: "' in source and re.search(
                r'String\(format:\s*"(?:[^"\\]|\\.)*%%', source
            ):
                failures.append(
                    f"{relative}: raw %% percentage formatting is not locale-aware"
                )
            if SIMPLE_PERCENT_INTERPOLATION.search(source):
                failures.append(
                    f"{relative}: percentage Text interpolation must use I18n.percent"
                )

    inline = scan_inline_pairs()
    if dump_path is not None:
        dump_path.write_text(
            json.dumps(inline, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(f"Inline pair inventory written to {dump_path} ({len(inline)} pairs)")

    # The inline bilingual helpers (pulseText / SetupCopy.text / t(...)) bridge
    # through the catalog by using their English literal AS the catalog key —
    # see I18n.prototype. That only translates when the key exists, so every
    # static inline pair must be a catalog key. Interpolated literals
    # (`\(x)`) cannot be catalog keys; they are a known structural gap and are
    # reported separately instead of failing.
    catalog_keys = set(document.get("strings", {}).keys())
    interpolated = 0
    for entry in inline:
        if not entry["en"].strip():
            failures.append(
                f"{entry['file']}:{entry['line']}: empty en fallback for {entry['zh']!r}"
            )
            continue
        if entry["en"] == entry["zh"]:
            failures.append(
                f"{entry['file']}:{entry['line']}: en fallback equals the zh literal"
            )
        if r"\(" in entry["en"] or r"\(" in entry["zh"]:
            interpolated += 1
            continue
        if entry["en"] not in catalog_keys:
            failures.append(
                f"{entry['file']}:{entry['line']}: inline pair {entry['en']!r} is not a "
                "catalog key — add it with all locales so the bridge translates"
            )

    if failures:
        print(f"Localization validation failed ({len(failures)} issues):", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(
        f"Localization validation passed: {checked} active keys, "
        f"{len(SUPPORTED_LOCALES)} locales, {len(inline)} inline pairs "
        f"({interpolated} interpolated)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
