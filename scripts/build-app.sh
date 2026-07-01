#!/bin/bash
set -e

BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$BUILD_DIR/.build/AIPulse.app"
BINARY_NAME="AIPulse"

echo "=== Building $BINARY_NAME ==="
cd "$BUILD_DIR"
swift build -c release --product "$BINARY_NAME"

echo "=== Creating .app bundle ==="
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

# Copy binary
cp "$BUILD_DIR/.build/arm64-apple-macosx/release/$BINARY_NAME" "$APP_DIR/Contents/MacOS/"

# Copy Info.plist
cp "$BUILD_DIR/Resources/Info.plist" "$APP_DIR/Contents/"

# Copy icons (AppIconLoader needs .png at runtime; .icns for system)
cp "$BUILD_DIR/Resources/AIPulse.icns" "$APP_DIR/Contents/Resources/"
cp "$BUILD_DIR/Resources/AIPulse.png" "$APP_DIR/Contents/Resources/"
# Copy pricing catalog (bundle resource lookup)
cp "$BUILD_DIR/../shared/pricing-catalog.json" "$APP_DIR/Contents/Resources/"

# Copy libgit2 dylib
cp "$BUILD_DIR/Libraries/libgit2/lib/libgit2.1.9.dylib" "$APP_DIR/Contents/Frameworks/"

# Fix libgit2 dylib install name to use @rpath
install_name_tool -id @rpath/libgit2.1.9.dylib "$APP_DIR/Contents/Frameworks/libgit2.1.9.dylib" 2>/dev/null || true

# Fix binary's reference to libgit2
install_name_tool -change \
    "$BUILD_DIR/Libraries/libgit2/lib/libgit2.1.9.dylib" \
    @rpath/libgit2.1.9.dylib \
    "$APP_DIR/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true

# Add rpath to binary
install_name_tool -add_rpath @executable_path/../Frameworks "$APP_DIR/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true

echo "=== Done ==="
echo "App bundle: $APP_DIR"
echo ""
echo "To run: open $APP_DIR"
echo "To codesign: codesign --deep --force --verify --verbose --sign 'Developer ID Application' $APP_DIR"
