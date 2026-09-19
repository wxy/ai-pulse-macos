#!/usr/bin/env python3
"""Validate the shared String Catalog used by every AI Pulse surface."""

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


def placeholders(value: str) -> list[str]:
    return sorted(PLACEHOLDER.findall(value))


def main() -> int:
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

    if failures:
        print(f"Localization validation failed ({len(failures)} issues):", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"Localization validation passed: {checked} active keys, {len(SUPPORTED_LOCALES)} locales")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
