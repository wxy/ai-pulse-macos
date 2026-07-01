#!/usr/bin/env python3
"""
Generate macOS 26 app icon: place the square AIPulse.png into an 824×824 rounded
body centered on a 1024 canvas (100px transparent margin, corner radius 185.4px),
produce all 10 iconset sizes, and package into AIPulse.icns.

Usage:  python3 scripts/generate-icons.py [--chrome]
  --chrome   Generate Chrome extension icons (robot-only, no white body)
             at 16/32/48/128px → ../../public/icons/
  (default)  Generate macOS .iconset + .icns → Resources/
"""

import os
import sys
import subprocess
from PIL import Image, ImageDraw

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(PROJECT_ROOT, "Resources")
SOURCE_PNG = os.path.join(RESOURCES, "AIPulse.png")
ICONSET = os.path.join(RESOURCES, "AIPulse.iconset")
ICNS = os.path.join(RESOURCES, "AIPulse.icns")

CANVAS = 1024
# macOS 26 icon grid: an 824×824 rounded body centered in a 1024 canvas,
# leaving a 100px transparent margin on every side (matches every stock app
# icon in the Dock). The system adds the drop shadow, so we bake none.
BODY = 824
MARGIN = (CANVAS - BODY) // 2  # 100
CORNER_RADIUS = 185.4  # continuous corner radius of the 824px body (≈22.5%)
COVERAGE = 0.72  # artwork span as a fraction of the body

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


def make_rounded_icon(source: Image.Image) -> Image.Image:
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
    return canvas


def make_chrome_icon(source: Image.Image, size: int) -> Image.Image:
    """Crop the robot artwork and place it centered on a white square canvas."""
    canvas = Image.new("RGBA", (size, size), (255, 255, 255, 255))

    # Crop robot out of its white margins.
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

    print(f"Loading source: {SOURCE_PNG}")
    source = Image.open(SOURCE_PNG).convert("RGBA")
    print(f"  Size: {source.size}, Mode: {source.mode}")

    if chrome_mode:
        print("Generating Chrome extension icons (robot-only, white bg)...")
        generate_chrome_icons(source)
        print(f"  → {CHROME_OUTPUT_DIR}/")
        print("Done.")
        return

    # Compose the 824px rounded body on the 1024 canvas.
    print(f"Composing {BODY}px rounded body (r={CORNER_RADIUS}px, margin={MARGIN}px)...")
    rounded = make_rounded_icon(source)

    # Write iconset
    os.makedirs(ICONSET, exist_ok=True)
    for logical, scale, filename in SIZES:
        px = logical * scale
        img = rounded.resize((px, px), Image.LANCZOS)
        path = os.path.join(ICONSET, filename)
        img.save(path, "PNG")
        print(f"  {filename:24s}  {px}x{px}")

    # Generate .icns via iconutil
    print(f"\nGenerating .icns via iconutil...")
    subprocess.run(["iconutil", "-c", "icns", ICONSET], check=True)
    print(f"  → {ICNS}")
    print("Done.")


if __name__ == "__main__":
    main()
