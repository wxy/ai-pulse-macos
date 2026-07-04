#!/bin/bash
# Release build script — produces a signed, notarized DMG.
# Used by CI (github workflows) and can be run locally for testing.
#
# Prerequisites:
#   - Xcode 16+
#   - Developer ID Application certificate in keychain
#   - App Store Connect API key for notarization (optional, only for MAS)
#
# Usage:
#   ./scripts/release.sh                    # build + DMG (no notarization)
#   NOTARIZE=1 ./scripts/release.sh         # build + DMG + notarize
#   APPCAST=1 ./scripts/release.sh          # also generate appcast.xml
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(defaults read "$(pwd)/AIPulse/AIPulse.xcodeproj/../AIPulse-Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")}"
BUILD_NUM="${BUILD_NUM:-1}"
APP_NAME="AI Pulse"
DMG_NAME="AIPulse-${VERSION}"

echo "=== Building ${APP_NAME} v${VERSION} (${BUILD_NUM}) ==="

# ── Build .app via xcodebuild ──────────────────────────────────
SCHEME="AIPulse"
ARCHIVE_PATH="./.build/AIPulse.xcarchive"
EXPORT_PATH="./.build/AIPulse-export"

xcodebuild archive \
  -project AIPulse/AIPulse.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-YUUWV9L8M8}" \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  MARKETING_VERSION="$VERSION"

# Export .app from archive
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist <(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM:-YUUWV9L8M8}</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF
)

APP_BUNDLE="$EXPORT_PATH/${APP_NAME}.app"
echo "=== .app exported to $APP_BUNDLE ==="

# ── DMG ─────────────────────────────────────────────────────────
DMG_TEMP="./.build/${DMG_NAME}-temp.dmg"
DMG_FINAL="./.build/${DMG_NAME}.dmg"

rm -f "$DMG_TEMP" "$DMG_FINAL"

# Create a temporary folder for DMG layout
DMG_SRC="./.build/dmg-src"
rm -rf "$DMG_SRC"
mkdir -p "$DMG_SRC"
cp -R "$APP_BUNDLE" "$DMG_SRC/"
ln -s /Applications "$DMG_SRC/Applications"

hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_SRC" \
  -ov -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_TEMP"

# Add a nice icon layout (optional, needs AppleScript/osascript)
# For now, just produce the compressed DMG
mv "$DMG_TEMP" "$DMG_FINAL"
echo "=== DMG created at $DMG_FINAL ==="

# ── Notarization (optional) ────────────────────────────────────
if [ "${NOTARIZE:-0}" = "1" ]; then
  echo "=== Submitting for notarization ==="
  xcrun notarytool submit "$DMG_FINAL" \
    --apple-id "${APPLE_ID:?}" \
    --team-id "${DEVELOPMENT_TEAM:-YUUWV9L8M8}" \
    --password "${APPLE_APP_PASSWORD:?}" \
    --wait

  echo "=== Stapling notarization ticket ==="
  xcrun stapler staple "$DMG_FINAL"
  echo "=== Notarization complete ==="
fi

# ── Appcast (for Sparkle) ──────────────────────────────────────
if [ "${APPCAST:-0}" = "1" ]; then
  APPCAST_FILE="./.build/appcast.xml"
  DMG_SIZE=$(stat -f%z "$DMG_FINAL")
  DMG_URL="https://github.com/wxy/ai-pulse-macos/releases/download/v${VERSION}/${DMG_NAME}.dmg"
  RELEASE_NOTES="https://github.com/wxy/ai-pulse-macos/releases/tag/v${VERSION}"

  # Generate minimal Sparkle 2.x appcast item
  cat > "$APPCAST_FILE" <<APPCASTXML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>${APP_NAME}</title>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:releaseNotesLink>${RELEASE_NOTES}</sparkle:releaseNotesLink>
      <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S GMT")</pubDate>
      <enclosure
        url="${DMG_URL}"
        sparkle:version="${BUILD_NUM}"
        sparkle:shortVersionString="${VERSION}"
        length="${DMG_SIZE}"
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCASTXML
  echo "=== Appcast generated at $APPCAST_FILE ==="
fi

echo "=== Release build complete: $DMG_FINAL ==="
