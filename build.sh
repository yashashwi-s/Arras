#!/bin/bash
# build.sh — Build, test, and package Arras for macOS
# Usage:
#   ./build.sh           # Just build
#   ./build.sh --run     # Build + install to /Applications + launch
#   ./build.sh --release # Build + create .zip and .dmg in dist/

set -euo pipefail

APP_NAME="Arras"
SCHEME="Arras"
BUILD_DIR="build"
OUTPUT_DIR="dist"


# This UI deliberately uses the native macOS 27 TabView presentation. SwiftUI
# can select an older settings-window design when the same source is linked with
# an older SDK, so choosing whichever Xcode happens to be installed first
# makes local and exported apps visibly different.
for XCODE_PATH in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ ! -d "$XCODE_PATH" ]; then
        continue
    fi

    CANDIDATE_DEVELOPER_DIR="$XCODE_PATH/Contents/Developer"
    SDK_VERSION=$(DEVELOPER_DIR="$CANDIDATE_DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
    if [[ "$SDK_VERSION" == 27.* ]]; then
        export DEVELOPER_DIR="$CANDIDATE_DEVELOPER_DIR"
        break
    fi
done

if [ -z "${DEVELOPER_DIR:-}" ]; then
    echo "❌ Xcode with the macOS 27 SDK is required so exported builds use the intended UI"
    exit 1
fi

echo "🔧 Using Xcode at: $DEVELOPER_DIR"
echo "🎯 Linking against macOS SDK $SDK_VERSION"

# Generate Xcode project
echo "⚙️  Generating Xcode project..."
xcodegen generate 2>&1 | tail -1

# Build
echo "🏗️  Building $SCHEME (Release)..."
# A failed incremental build must never leave an older app in the location that
# the validation and packaging steps inspect.
rm -rf "$BUILD_DIR/Release/$APP_NAME.app" \
       "$BUILD_DIR/Release/$APP_NAME.app.dSYM" \
       "$BUILD_DIR/Release/$APP_NAME.swiftmodule"

xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  build 2>&1 | grep -E "BUILD|error:|warning:"

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
    # Staged with an /Applications symlink so the image is a drag-to-install.
    STAGE="$BUILD_DIR/dmg"
    rm -rf "$STAGE" && mkdir -p "$STAGE"
    cp -R "$APP_PATH" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"

    hdiutil create \
      -volname "$APP_NAME" \
      -srcfolder "$STAGE" \
      -ov -format UDZO \
      "$OUTPUT_DIR/$APP_NAME.dmg" 2>&1 | grep -v "WARNING" || true

    ZIP_SIZE=$(du -sm "$OUTPUT_DIR/$APP_NAME.app.zip" | cut -f1)
    DMG_SIZE=$(du -sm "$OUTPUT_DIR/$APP_NAME.dmg" | cut -f1)

    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
      "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "?")

    echo ""
    echo "✅ Local release artifacts ready (for testing only)"
    echo "   Zip: $OUTPUT_DIR/$APP_NAME.app.zip (${ZIP_SIZE}MB)"
    echo "   DMG: $OUTPUT_DIR/$APP_NAME.dmg (${DMG_SIZE}MB)"
    echo ""
    # Deliberately does NOT print a sha256 for appcast.json.
    #
    # Pushing a v* tag makes the Release workflow rebuild the app on its own
    # runner and overwrite the release assets, so a checksum computed here
    # describes a binary nobody will ever download. The updater then rejects
    # every download. The workflow stamps appcast.json itself.
    echo "To publish:  git tag v$VERSION && git push origin v$VERSION"
    echo "CI builds, uploads, and stamps appcast.json with the real checksum."
    echo ""
    exit 0
fi

echo ""
echo "✅ Build complete. Use --run to install+launch, or --release to package."
