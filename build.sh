#!/bin/bash
# build.sh — Build, test, and package Tableau for macOS
# Usage:
#   ./build.sh           # Just build
#   ./build.sh --run     # Build + install to /Applications + launch
#   ./build.sh --release # Build + create .zip and .dmg in dist/
#   ./build.sh --mas     # Build the Mac App Store variant (no self-updater)

set -euo pipefail

APP_NAME="Tableau"
SCHEME="Tableau"
BUILD_DIR="build"
OUTPUT_DIR="dist"

# The MAS target strips the appcast updater and the network entitlement, so it
# gets its own build dir to avoid clobbering the Developer ID artifact.
if [ "${1:-}" = "--mas" ]; then
    SCHEME="Tableau-MAS"
    BUILD_DIR="build/mas"
fi

# Auto-detect Xcode path
if [ -d "/Applications/Xcode.app" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
elif [ -d "/Applications/Xcode-beta.app" ]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
else
    echo "❌ No Xcode installation found in /Applications"
    exit 1
fi

echo "🔧 Using Xcode at: $DEVELOPER_DIR"

# Generate Xcode project
echo "⚙️  Generating Xcode project..."
xcodegen generate 2>&1 | tail -1

# Build
echo "🏗️  Building $SCHEME (Release)..."
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  build 2>&1 | grep -E "BUILD|error:|warning:" || true

APP_PATH="$BUILD_DIR/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "❌ Build failed — $APP_NAME.app not found"
  exit 1
fi

APP_SIZE=$(du -sm "$APP_PATH" | cut -f1)
echo "✅ Built: $APP_PATH (${APP_SIZE}MB)"

# Sanity check
if [ "$APP_SIZE" -lt 1 ]; then
  echo "❌ Build output is suspiciously small (${APP_SIZE}MB). Something went wrong."
  exit 1
fi

# --run: Install and launch
if [ "${1:-}" = "--run" ]; then
    echo "📲 Installing to /Applications..."
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_PATH" "/Applications/$APP_NAME.app"
    xattr -cr "/Applications/$APP_NAME.app"
    echo "🚀 Launching $APP_NAME..."
    open "/Applications/$APP_NAME.app"
    echo "✅ Done! $APP_NAME is running."
    exit 0
fi

# --release: Package for distribution
if [ "${1:-}" = "--release" ]; then
    mkdir -p "$OUTPUT_DIR"
    rm -f "$OUTPUT_DIR/$APP_NAME.app.zip" "$OUTPUT_DIR/$APP_NAME.dmg"

    echo "📦 Creating zip..."
    cd "$BUILD_DIR/Release"
    ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "../../$OUTPUT_DIR/$APP_NAME.app.zip"
    cd ../..

    echo "💿 Creating DMG..."
    hdiutil create \
      -volname "$APP_NAME" \
      -srcfolder "$APP_PATH" \
      -ov -format UDZO \
      "$OUTPUT_DIR/$APP_NAME.dmg" 2>&1 | grep -v "WARNING" || true

    ZIP_SIZE=$(du -sm "$OUTPUT_DIR/$APP_NAME.app.zip" | cut -f1)
    DMG_SIZE=$(du -sm "$OUTPUT_DIR/$APP_NAME.dmg" | cut -f1)

    echo ""
    echo "✅ Release artifacts ready!"
    echo "   Zip: $OUTPUT_DIR/$APP_NAME.app.zip (${ZIP_SIZE}MB)"
    echo "   DMG: $OUTPUT_DIR/$APP_NAME.dmg (${DMG_SIZE}MB)"
    echo ""
    echo "Upload these to GitHub Releases."
    exit 0
fi

echo ""
echo "✅ Build complete. Use --run to install+launch, or --release to package."
