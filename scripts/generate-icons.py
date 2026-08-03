#!/usr/bin/env python3
"""
Generate AI Pulse app icons from a single source artwork.

The source of truth is Resources/AIPulse.png (the square robot on a white
background). This script derives every platform icon from it:

  release (default)   python3 scripts/generate-icons.py
    macOS   Resources/AIPulse.iconset + AIPulse.icns  and  AIPulse/Assets.xcassets/AppIcon.appiconset
    iOS     Suites/iOS/Assets.xcassets/AppIcon.appiconset/AIPulse.png
    Widget  Suites/AIPulseWidget/Assets.xcassets/AppIcon.appiconset/AIPulse.png
            (watchOS icon is committed separately and left untouched)

  debug               python3 scripts/generate-icons.py --debug
    Same outputs, but an orange diagonal notch is drawn across the top-left
    corner so a dev build is visually distinguishable from the release build
    (which is how we tell them apart on the Home screen / Dock, since all
    builds share the same bundle identifier and display name).
    macOS   AIPulse-Debug.iconset/.icns/.png  +  AIPulse/Assets.xcassets/AppIcon-Debug.appiconset
    iOS     Suites/iOS/Assets.xcassets/AppIcon-Debug.appiconset/AIPulse.png
    Watch   Suites/watchOS/Assets.xcassets/AppIcon-Debug.appiconset/AIPulse.png
    Widget  Suites/AIPulseWidget/Assets.xcassets/AppIcon-Debug.appiconset/AIPulse.png

  chrome              python3 scripts/generate-icons.py --chrome
    Chrome extension icons (robot-only, no white body)
    at 16/32/48/128px → ../../public/icons/

The Xcode projects pick the debug vs release set per build configuration
(ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon / AppIcon-Debug on iOS, watch,
widget and macOS; macOS also has CFBundleIconFile = $(ICON_NAME) for the
scripted SPM build).
"""

import os
import sys
import subprocess
import shutil
from PIL import Image, ImageChops, ImageDraw

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(PROJECT_ROOT, "Resources")
SOURCE_PNG = os.path.join(RESOURCES, "AIPulse.png")
IOS_ASSETS = os.path.join(PROJECT_ROOT, "Suites", "iOS", "Assets.xcassets")
WATCH_ASSETS = os.path.join(PROJECT_ROOT, "Suites", "watchOS", "Assets.xcassets")
WIDGET_ASSETS = os.path.join(PROJECT_ROOT, "Suites", "AIPulseWidget", "Assets.xcassets")
MAC_ASSETS = os.path.join(PROJECT_ROOT, "AIPulse", "Assets.xcassets")

CANVAS = 1024
# macOS 26 icon grid: an 824×824 rounded body centered in a 1024 canvas,
# leaving a 100px transparent margin on every side (matches every stock app
# icon in the Dock). The system adds the drop shadow, so we bake none.
BODY = 824
MARGIN = (CANVAS - BODY) // 2  # 100
CORNER_RADIUS = 185.4  # continuous corner radius of the 824px body (≈22.5%)
COVERAGE = 0.72  # artwork span as a fraction of the body

# Debug-build marker: an orange diagonal cut across the top-left corner.
# Fraction is of the rounded BODY on macOS and of the full canvas on iOS.
NOTCH_FRACTION = 0.32
NOTCH_COLOR = (255, 149, 0, 255)  # system orange

# Standard macOS iconset sizes: (logical, scale, filename)
SIZES = [
    (16,  1, "icon_16x16.png"),
    (16,  2, "icon_16x16@2x.png"),
    (32,  1, "icon_32x32.png"),
    (32,  2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

# Chrome extension icon sizes (robot-only, no white body, transparent bg)
CHROME_SIZES = [16, 32, 48, 128]
CHROME_OUTPUT_DIR = os.path.join(PROJECT_ROOT, "..", "public", "icons")


def mac_appicon_contents():
    """Contents.json for a macOS AppIcon.appiconset (10 raster slots)."""
    return {
        "images": [
            {"filename": f, "idiom": "mac", "scale": scale, "size": size}
            for _, _, f, size, scale in [
                (16, 1, "icon_16x16.png", "16x16", "1x"),
                (16, 2, "icon_16x16@2x.png", "16x16", "2x"),
                (32, 1, "icon_32x32.png", "32x32", "1x"),
                (32, 2, "icon_32x32@2x.png", "32x32", "2x"),
                (128, 1, "icon_128x128.png", "128x128", "1x"),
                (128, 2, "icon_128x128@2x.png", "128x128", "2x"),
                (256, 1, "icon_256x256.png", "256x256", "1x"),
                (256, 2, "icon_256x256@2x.png", "256x256", "2x"),
                (512, 1, "icon_512x512.png", "512x512", "1x"),
                (512, 2, "icon_512x512@2x.png", "512x512", "2x"),
            ]
        ],
        "info": {"author": "xcode", "version": 1},
    }


def write_json(path, data):
    import json
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def rounded_rect_mask(size, radius):
    """Create an alpha mask: white rounded rect on transparent background."""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([(0, 0), (size - 1, size - 1)], radius=radius, fill=255)
    return mask


def content_bbox(im: Image.Image):
    """Bounding box of the visible (opaque, non-white) artwork."""
    px = im.load()
    w, h = im.size
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a > 10 and (r + g + b) < 3 * 245:
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
    if maxx < minx:
        return (0, 0, w, h)
    return (minx, miny, maxx + 1, maxy + 1)


def draw_debug_notch(im: Image.Image, cut: int):
    """Fill an orange triangle in the top-left corner as the dev-build marker."""
    draw = ImageDraw.Draw(im)
    draw.polygon([(0, 0), (cut, 0), (0, cut)], fill=NOTCH_COLOR)


def notched_copy(im: Image.Image, debug: bool = False) -> Image.Image:
    """Full-bleed 1024×1024 icon (iOS/watch/widget mask the corners themselves)."""
    icon = im.copy()
    if debug:
        draw_debug_notch(icon, round(NOTCH_FRACTION * CANVAS))
    return icon


def draw_rounded_debug_notch(canvas: Image.Image):
    """Cut a diagonal orange marker into the body's top-left corner.

    The triangle is clipped to the body's alpha so the marker follows the
    rounded corner instead of bleeding into the transparent margin. The result
    is a bold diagonal slice from the body's top edge to its left edge.
    """
    alpha = canvas.getchannel("A")
    tri = Image.new("L", (CANVAS, CANVAS), 0)
    cut = MARGIN + round(NOTCH_FRACTION * BODY)
    ImageDraw.Draw(tri).polygon(
        [(MARGIN, MARGIN), (cut, MARGIN), (MARGIN, cut)], fill=255)
    mask = ImageChops.multiply(tri, alpha)
    orange = Image.new("RGBA", (CANVAS, CANVAS), NOTCH_COLOR)
    return Image.composite(orange, canvas, mask)


def make_rounded_icon(source: Image.Image, debug: bool = False) -> Image.Image:
    """Center the cropped artwork in an 824px white rounded body on a 1024 canvas."""
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    # White rounded body.
    body = Image.new("RGBA", (BODY, BODY), (255, 255, 255, 255))

    # Crop the robot out of its wide white margins, then size it to COVERAGE.
    robot = source.crop(content_bbox(source))
    cw, ch = robot.size
    scale = (COVERAGE * BODY) / max(cw, ch)
    nw, nh = round(cw * scale), round(ch * scale)
    robot = robot.resize((nw, nh), Image.LANCZOS)
    body.alpha_composite(robot, ((BODY - nw) // 2, (BODY - nh) // 2))

    # Round the corners and drop the body onto the transparent canvas.
    body.putalpha(rounded_rect_mask(BODY, CORNER_RADIUS))
    canvas.paste(body, (MARGIN, MARGIN), body)

    if debug:
        canvas = draw_rounded_debug_notch(canvas)
    return canvas


def generate_macos(source: Image.Image, debug: bool = False):
    """macOS: Resources iconset + .icns (SPM build) and the asset-catalog icon (Xcode)."""
    suffix = "-Debug" if debug else ""
    rounded = make_rounded_icon(source, debug)

    # Resources/.iconset + .icns (used by scripts/build-app.sh and as fallback)
    iconset = os.path.join(RESOURCES, f"AIPulse{suffix}.iconset")
    os.makedirs(iconset, exist_ok=True)
    for logical, scale, filename in SIZES:
        px = logical * scale
        img = rounded.resize((px, px), Image.LANCZOS)
        img.save(os.path.join(iconset, filename), "PNG")
        print(f"  {filename:24s}  {px}x{px}")
    icns = os.path.join(RESOURCES, f"AIPulse{suffix}.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset], check=True)
    print(f"  → {icns}")

    # Asset-catalog AppIcon set (drives the Xcode scheme dropdown + Xcode build icon)
    appiconset = os.path.join(MAC_ASSETS, f"AppIcon{suffix}.appiconset")
    os.makedirs(appiconset, exist_ok=True)
    for logical, scale, filename in SIZES:
        px = logical * scale
        img = rounded.resize((px, px), Image.LANCZOS)
        img.save(os.path.join(appiconset, filename), "PNG")
    write_json(os.path.join(appiconset, "Contents.json"), mac_appicon_contents())
    print(f"  → {appiconset}")

    if debug:
        png = os.path.join(RESOURCES, "AIPulse-Debug.png")
        notched_copy(source, debug=True).save(png, "PNG")
        print(f"  → {png}")


def generate_ios(source: Image.Image, debug: bool = False):
    """iOS main app: the 1024px icon in the asset catalog's appicon set."""
    suffix = "-Debug" if debug else ""
    appiconset = os.path.join(IOS_ASSETS, f"AppIcon{suffix}.appiconset")
    os.makedirs(appiconset, exist_ok=True)
    dest = os.path.join(appiconset, "AIPulse.png")
    if debug:
        notched_copy(source, debug=True).save(dest, "PNG")
    else:
        # Release icon is byte-identical to the source artwork — copy, don't
        # re-encode, to keep the committed file unchanged.
        shutil.copy(SOURCE_PNG, dest)
    print(f"  → {dest}")


def generate_watch(source: Image.Image, debug: bool = False):
    """watchOS app icon. Release is committed separately; debug derives from it."""
    if not debug:
        print("  (release watch icon is committed separately — skipped)")
        return
    release = Image.open(
        os.path.join(WATCH_ASSETS, "AppIcon.appiconset", "AIPulse.png")
    ).convert("RGBA")
    appiconset = os.path.join(WATCH_ASSETS, "AppIcon-Debug.appiconset")
    os.makedirs(appiconset, exist_ok=True)
    notched_copy(release, debug=True).save(
        os.path.join(appiconset, "AIPulse.png"), "PNG")
    # Template Contents.json (same structure as the release watch set)
    shutil.copy(
        os.path.join(WATCH_ASSETS, "AppIcon.appiconset", "Contents.json"),
        os.path.join(appiconset, "Contents.json"))
    print(f"  → {appiconset}")


def generate_widget(source: Image.Image, debug: bool = False):
    """Widget extension icon (so the debug build's widget is notched too)."""
    suffix = "-Debug" if debug else ""
    appiconset = os.path.join(WIDGET_ASSETS, f"AppIcon{suffix}.appiconset")
    os.makedirs(appiconset, exist_ok=True)
    dest = os.path.join(appiconset, "AIPulse.png")
    if debug:
        notched_copy(source, debug=True).save(dest, "PNG")
    else:
        shutil.copy(SOURCE_PNG, dest)
    # Template Contents.json (same structure as the iOS main app icon)
    shutil.copy(
        os.path.join(IOS_ASSETS, "AppIcon.appiconset", "Contents.json"),
        os.path.join(appiconset, "Contents.json"))
    print(f"  → {appiconset}")


def make_chrome_icon(source: Image.Image, size: int) -> Image.Image:
    """Crop the robot artwork and place it centered on a transparent square canvas."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Crop robot out of its transparent margins.
    robot = source.crop(content_bbox(source))
    cw, ch = robot.size

    # Scale to fit the canvas, keeping aspect ratio, with 10% padding.
    pad = 0.90
    scale = (pad * size) / max(cw, ch)
    nw, nh = round(cw * scale), round(ch * scale)
    robot = robot.resize((nw, nh), Image.LANCZOS)

    canvas.alpha_composite(robot, ((size - nw) // 2, (size - nh) // 2))
    return canvas


def generate_chrome_icons(source: Image.Image):
    """Generate Chrome extension icons at 16, 32, 48, 128 px."""
    os.makedirs(CHROME_OUTPUT_DIR, exist_ok=True)
    for size in CHROME_SIZES:
        icon = make_chrome_icon(source, size)
        path = os.path.join(CHROME_OUTPUT_DIR, f"icon-{size}.png")
        icon.save(path, "PNG")
        print(f"  icon-{size}.png  {size}×{size}")


def main():
    chrome_mode = "--chrome" in sys.argv
    debug = "--debug" in sys.argv

    print(f"Loading source: {SOURCE_PNG}")
    source = Image.open(SOURCE_PNG).convert("RGBA")
    print(f"  Size: {source.size}, Mode: {source.mode}")

    if chrome_mode:
        print("Generating Chrome extension icons (robot-only, transparent bg)...")
        generate_chrome_icons(source)
        print(f"  → {CHROME_OUTPUT_DIR}/")
        print("Done.")
        return

    flavor = "debug" if debug else "release"
    print(f"Generating {flavor} app icons...")
    print("macOS:")
    generate_macos(source, debug)
    print("iOS:")
    generate_ios(source, debug)
    print("watchOS:")
    generate_watch(source, debug)
    print("Widget:")
    generate_widget(source, debug)
    print("Done.")


if __name__ == "__main__":
    main()
