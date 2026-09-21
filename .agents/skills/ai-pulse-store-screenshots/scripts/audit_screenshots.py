#!/usr/bin/env python3
"""Audit the approved AI Pulse 2.0 screenshot matrix and build contact sheets."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError as error:
    raise SystemExit("Pillow is required: python3 -m pip install Pillow") from error


LOCALES = (
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

SPECS = {
    "iPhone": {"iphone-30d.png": (1206, 2622)},
    "iPad": {"ipad-30-days.png": (2064, 2752)},
    "Watch": {"watch-today.png": (416, 496)},
    "macOS": {
        "mac-30-days.png": (1080, 1280),
        "mac-tool-detail.png": (1080, 1280),
        "mac-settings-developer-tools.png": (1624, 1288),
        "mac-settings-account-fixed-costs.png": (1624, 1288),
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, help="Screenshot root containing platform folders")
    parser.add_argument("--contact-sheet-dir", type=Path)
    return parser.parse_args()


def is_fully_opaque(image: Image.Image) -> bool:
    if "A" not in image.getbands():
        return True
    return image.getchannel("A").getextrema() == (255, 255)


def make_contact_sheet(paths: list[tuple[str, Path]], output: Path) -> None:
    tile_width, tile_height = 420, 360
    sheet = Image.new("RGB", (tile_width * 5, tile_height * 2), "black")
    for index, (locale, path) in enumerate(paths):
        with Image.open(path) as source:
            preview = source.convert("RGB")
            preview.thumbnail((406, 322))
        tile = Image.new("RGB", (tile_width, tile_height), "#181818")
        tile.paste(preview, ((tile_width - preview.width) // 2, 28))
        ImageDraw.Draw(tile).text((12, 8), locale, fill="white")
        sheet.paste(tile, ((index % 5) * tile_width, (index // 5) * tile_height))
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output)


def main() -> int:
    args = parse_args()
    failures: list[str] = []
    expected_paths: set[Path] = set()

    for platform, files in SPECS.items():
        for filename, expected_size in files.items():
            contact_paths: list[tuple[str, Path]] = []
            for locale in LOCALES:
                path = args.root / platform / locale / filename
                expected_paths.add(path)
                if not path.is_file():
                    failures.append(f"missing: {path}")
                    continue
                try:
                    with Image.open(path) as image:
                        if image.format != "PNG":
                            failures.append(f"not PNG: {path} ({image.format})")
                        if image.size != expected_size:
                            failures.append(f"wrong size: {path} {image.size}, expected {expected_size}")
                        if not is_fully_opaque(image):
                            failures.append(f"contains transparent pixels: {path}")
                        if platform == "macOS" and "A" in image.getbands():
                            failures.append(f"macOS output still has alpha: {path}")
                except OSError as error:
                    failures.append(f"unreadable: {path}: {error}")
                    continue
                contact_paths.append((locale, path))

            if args.contact_sheet_dir and len(contact_paths) == len(LOCALES):
                stem = Path(filename).stem
                make_contact_sheet(contact_paths, args.contact_sheet_dir / f"{platform}-{stem}.png")

    actual_paths = set(args.root.glob("*/*/*.png"))
    for unexpected in sorted(actual_paths - expected_paths):
        failures.append(f"unexpected PNG: {unexpected}")

    if failures:
        print("Screenshot audit failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"Verified {len(expected_paths)} screenshots across {len(LOCALES)} locales.")
    if args.contact_sheet_dir:
        print(f"Contact sheets: {args.contact_sheet_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
