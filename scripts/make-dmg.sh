#!/bin/bash
# make-dmg.sh — Create a nicely-formatted, notarized DMG from an .app bundle.
#
# Prerequisites:
#   - A notarized AIPulse.app in dist/ (or set APP_SRC)
#   - AIPulse.icns in Resources/
#   - .env file with credentials (for notarization, see .env.example)
#
# Usage:
#   ./scripts/make-dmg.sh             # build DMG only
#   NOTARIZE=1 ./scripts/make-dmg.sh  # build DMG + notarize + staple + verify
#   APP_SRC=... ./scripts/make-dmg.sh # use custom .app path
#
# Output: dist/AIPulse-{version}.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

# ── Helpers ───────────────────────────────────────────────────────
TOTAL_STEPS=0
CURRENT_STEP=0

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    printf "\n\033[1;36m[%d/%d]\033[0m %s\n" "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
}

fail() {
    printf "\n\033[1;31m✗ FAILED at step %d/%d:\033[0m %s\n" "$CURRENT_STEP" "$TOTAL_STEPS" "$1" >&2
    exit 1
}

ok() {
    printf "    \033[32m✓\033[0m %s\n" "$1"
}

# ── Load credentials ──────────────────────────────────────────────
if [ "${NOTARIZE:-0}" = "1" ]; then
    if [ ! -f ".env" ]; then
        fail "NOTARIZE=1 but .env not found. Run: cp .env.example .env && edit .env"
    fi
    # shellcheck disable=SC1091
    source .env
    if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_APP_PASSWORD:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; then
        fail "APPLE_ID, APPLE_APP_PASSWORD, or APPLE_TEAM_ID not set in .env"
    fi
fi

# ── Validate inputs ───────────────────────────────────────────────
APP_SRC="${APP_SRC:-dist/AIPulse.app}"

if [ ! -d "$APP_SRC" ]; then
    fail "App bundle not found at $APP_SRC"
fi

ICNS_FILE="Resources/AIPulse.icns"
if [ ! -f "$ICNS_FILE" ]; then
    fail "Icon not found at $ICNS_FILE"
fi

VERSION=$(defaults read "$(pwd)/$APP_SRC/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")
VOLUME_NAME="AI Pulse"
APP_NAME="AIPulse.app"
DMG_FINAL="dist/AIPulse-${VERSION}.dmg"
DMG_RW="dist/.AIPulse-rw.dmg"

# Calculate total steps
BUILD_STEPS=9
NOTARY_STEPS=3  # submit, staple, verify
if [ "${NOTARIZE:-0}" = "1" ]; then
    TOTAL_STEPS=$((BUILD_STEPS + NOTARY_STEPS))
else
    TOTAL_STEPS=$BUILD_STEPS
fi

# ── Cleanup trap ──────────────────────────────────────────────────
cleanup() {
    hdiutil detach "/Volumes/${VOLUME_NAME}" 2>/dev/null || true
    rm -f "$DMG_RW"
}
trap cleanup EXIT

echo "=========================================="
echo "  Building DMG for ${VOLUME_NAME} v${VERSION}"
echo "  Notarize: ${NOTARIZE:-0}"
echo "  Steps:    ${TOTAL_STEPS}"
echo "=========================================="

# ── Cleanup previous ──────────────────────────────────────────────
rm -f "$DMG_RW" "$DMG_FINAL"
hdiutil detach "/Volumes/${VOLUME_NAME}" 2>/dev/null || true
ok "Cleaned up previous artifacts"

# ── [1] Create writable disk image ────────────────────────────────
step "Creating writable disk image"
if hdiutil create -volname "$VOLUME_NAME" \
    -size 50m \
    -fs "HFS+" \
    -type UDIF \
    "$DMG_RW" >/dev/null; then
    ok "Created writable image: $DMG_RW"
else
    fail "hdiutil create failed"
fi

# ── [2] Mount ─────────────────────────────────────────────────────
step "Mounting disk image"
DEVICE=$(hdiutil attach "$DMG_RW" -nobrowse -noautoopen \
    -mountpoint "/Volumes/${VOLUME_NAME}" 2>&1 | grep Apple_HFS | awk '{print $1}')
if [ -n "$DEVICE" ]; then
    ok "Mounted at /Volumes/${VOLUME_NAME} ($DEVICE)"
else
    fail "Failed to mount $DMG_RW"
fi

# ── [3] Copy app + symlink ────────────────────────────────────────
step "Copying app bundle"
cp -R "$APP_SRC" "/Volumes/${VOLUME_NAME}/" || fail "Failed to copy $APP_SRC"
ln -s /Applications "/Volumes/${VOLUME_NAME}/Applications" || fail "Failed to create Applications symlink"
ok "Copied $APP_NAME + Applications symlink"

# ── [4] Set volume icon ───────────────────────────────────────────
step "Setting volume icon"
cp "$ICNS_FILE" "/Volumes/${VOLUME_NAME}/.VolumeIcon.icns" || fail "Failed to copy volume icon"
SetFile -a C "/Volumes/${VOLUME_NAME}" 2>/dev/null || true
ok "Volume icon set"

# ── [5] Configure Finder layout ───────────────────────────────────
step "Configuring Finder window layout"
osascript <<END_SCRIPT || fail "AppleScript layout failed"
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set bounds of container window to {400, 200, 900, 600}
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set position of item "$APP_NAME" to {140, 160}
        set position of item "Applications" to {360, 160}
        update without registering applications
        delay 1
        close
    end tell
end tell
END_SCRIPT
ok "Finder layout configured (window 500×400, icons at 96px)"

# ── [6] Fix permissions ───────────────────────────────────────────
step "Setting permissions"
chmod -Rf go-w "/Volumes/${VOLUME_NAME}" 2>/dev/null || true
sync
ok "Permissions set"

# ── [7] Detach ────────────────────────────────────────────────────
step "Detaching disk image"
if hdiutil detach "$DEVICE" -force 2>/dev/null; then
    ok "Detached $DEVICE"
else
    fail "Failed to detach $DEVICE"
fi

# ── [8] Convert to compressed read-only ───────────────────────────
step "Converting to compressed read-only DMG"
if hdiutil convert "$DMG_RW" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_FINAL" >/dev/null; then
    ok "Compressed DMG created"
else
    fail "hdiutil convert failed"
fi
rm -f "$DMG_RW"

# ── [9] Set DMG file icon ─────────────────────────────────────────
step "Setting DMG file icon"
osascript <<END_SCRIPT || fail "Failed to set DMG file icon"
use framework "AppKit"
use scripting additions
set iconImage to current application's NSImage's alloc()'s initWithContentsOfFile:"$ICNS_FILE"
current application's NSWorkspace's sharedWorkspace()'s setIcon:iconImage forFile:"$DMG_FINAL" options:0
END_SCRIPT
ok "DMG file icon set"

echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │  DMG built: $(basename "$DMG_FINAL")"
echo "  │  Size:      $(du -h "$DMG_FINAL" | cut -f1)"
echo "  └─────────────────────────────────────────┘"

# ══════════════════════════════════════════════════════════════════
# ── Notarization ──────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════
if [ "${NOTARIZE:-0}" != "1" ]; then
    echo ""
    echo "  Skipped notarization (set NOTARIZE=1 to enable)."
    exit 0
fi

# ── [10] Submit for notarization ──────────────────────────────────
step "Submitting for notarization"
SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG_FINAL" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait 2>&1) || fail "notarytool submit failed"

SUBMIT_ID=$(echo "$SUBMIT_OUTPUT" | grep "  id:" | head -1 | awk '{print $2}')
SUBMIT_STATUS=$(echo "$SUBMIT_OUTPUT" | grep "  status:" | tail -1 | awk '{print $2}')

if [ "$SUBMIT_STATUS" != "Accepted" ]; then
    echo "$SUBMIT_OUTPUT"
    fail "Notarization rejected (status: $SUBMIT_STATUS)"
fi
ok "Notarization accepted (id: $SUBMIT_ID)"

# ── [11] Staple ticket ────────────────────────────────────────────
step "Stapling notarization ticket"
STAPLE_OUTPUT=$(xcrun stapler staple "$DMG_FINAL" 2>&1) || fail "stapler staple failed"
ok "$STAPLE_OUTPUT"

# ── [12] Verify ───────────────────────────────────────────────────
step "Verifying notarized DMG"
VALIDATE_OUTPUT=$(xcrun stapler validate "$DMG_FINAL" 2>&1) || fail "stapler validate failed"
ok "Ticket validation: $VALIDATE_OUTPUT"

# Verify the .app inside as well
hdiutil attach "$DMG_FINAL" -nobrowse -mountpoint "/Volumes/${VOLUME_NAME}" >/dev/null 2>&1 || fail "Failed to mount DMG for verification"
APP_CHECK=$(spctl -a -t exec -v "/Volumes/${VOLUME_NAME}/${APP_NAME}" 2>&1) || true
hdiutil detach "/Volumes/${VOLUME_NAME}" -force >/dev/null 2>&1

if echo "$APP_CHECK" | grep -q "accepted"; then
    ok "App signature: $APP_CHECK"
else
    fail "App signature check: $APP_CHECK"
fi

echo ""
echo "  ╔═════════════════════════════════════════╗"
echo "  ║  🎉  All ${TOTAL_STEPS} steps passed                    ║"
echo "  ║  DMG: $(basename "$DMG_FINAL")"
printf "  ║  Size:     %-30s ║\n" "$(du -h "$DMG_FINAL" | cut -f1)"
echo "  ║  Notarized + Stapled + Verified        ║"
echo "  ╚═════════════════════════════════════════╝"
