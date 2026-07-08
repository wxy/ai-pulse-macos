#!/bin/bash
# make-dmg.sh — Create a nicely-formatted, signed DMG from an .app bundle.
#
# Prerequisites:
#   - A notarized AIPulse.app in dist/ (or set APP_SRC)
#   - AIPulse.icns in Resources/
#
# Usage:
#   ./scripts/make-dmg.sh                        # use dist/AIPulse.app
#   APP_SRC=path/to/AIPulse.app ./scripts/make-dmg.sh
#
# Output: dist/AIPulse-{version}.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP_SRC="${APP_SRC:-dist/AIPulse.app}"
ICNS_FILE="Resources/AIPulse.icns"

if [ ! -d "$APP_SRC" ]; then
    echo "ERROR: App bundle not found at $APP_SRC"
    echo "  Either place AIPulse.app in dist/ or set APP_SRC=path/to/AIPulse.app"
    exit 1
fi

VERSION=$(defaults read "$(pwd)/$APP_SRC/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")
VOLUME_NAME="AI Pulse"
APP_NAME="AIPulse.app"
DMG_FINAL="dist/AIPulse-${VERSION}.dmg"
DMG_RW="dist/.AIPulse-rw.dmg"

echo "=== Building DMG for ${VOLUME_NAME} v${VERSION} ==="

# Cleanup previous
rm -f "$DMG_RW" "$DMG_FINAL"
hdiutil detach "/Volumes/${VOLUME_NAME}" 2>/dev/null || true

# 1. Create writable DMG
echo "--- Creating writable disk image ---"
hdiutil create -volname "$VOLUME_NAME" \
  -size 50m \
  -fs "HFS+" \
  -type UDIF \
  "$DMG_RW"

# 2. Mount
echo "--- Mounting ---"
hdiutil attach "$DMG_RW" -nobrowse -noautoopen -mountpoint "/Volumes/${VOLUME_NAME}"

# 3. Copy app + Applications symlink
echo "--- Copying app ---"
cp -R "$APP_SRC" "/Volumes/${VOLUME_NAME}/"
ln -s /Applications "/Volumes/${VOLUME_NAME}/Applications"

# 4. Volume icon (visible when DMG is mounted)
cp "$ICNS_FILE" "/Volumes/${VOLUME_NAME}/.VolumeIcon.icns"
SetFile -a C "/Volumes/${VOLUME_NAME}" 2>/dev/null || true

# 5. Finder window layout
echo "--- Setting Finder layout ---"
osascript <<END_SCRIPT
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

# 6. Permissions
chmod -Rf go-w "/Volumes/${VOLUME_NAME}" 2>/dev/null || true
sync

# 7. Detach
echo "--- Detaching ---"
hdiutil detach "/Volumes/${VOLUME_NAME}" -force

# 8. Convert to compressed read-only
echo "--- Compressing ---"
hdiutil convert "$DMG_RW" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_FINAL"

rm -f "$DMG_RW"

# 9. Set Finder icon on the DMG file itself
echo "--- Setting DMG file icon ---"
osascript <<END_SCRIPT
use framework "AppKit"
use scripting additions
set iconImage to current application's NSImage's alloc()'s initWithContentsOfFile:"$ICNS_FILE"
current application's NSWorkspace's sharedWorkspace()'s setIcon:iconImage forFile:"$DMG_FINAL" options:0
END_SCRIPT

echo "=== Done: $DMG_FINAL ==="
ls -lh "$DMG_FINAL"
echo ""
echo "Next steps (optional):"
echo "  Notarize:  xcrun notarytool submit \"$DMG_FINAL\" --apple-id ... --team-id ... --password ... --wait"
echo "  Staple:    xcrun stapler staple \"$DMG_FINAL\""
echo "  Verify:    xcrun stapler validate \"$DMG_FINAL\""
