#!/bin/bash
# Build the current checkout. --release packages locally; --pilot BUILD packages a private telemetry test.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)"
MODE="${1:-build}"
PILOT_BUILD=0
case "$MODE" in
  build|--release|--run) [ "$#" -le 1 ] || { echo 'Unexpected arguments' >&2; exit 1; } ;;
  --pilot)
    [[ "${2:-}" =~ ^[0-9]+$ ]] && [ "${2:-0}" -ge 2203 ] && [ "$#" -eq 2 ] || {
      echo 'Usage: ./build.sh --pilot BUILD (2203 or newer)' >&2; exit 1;
    }
    PILOT_BUILD="$2" ;;
  *) echo 'Usage: ./build.sh [--release | --run | --pilot BUILD]' >&2; exit 1 ;;
esac

for XCODE_PATH in /Applications/Xcode.app /Applications/Xcode-beta.app; do
  [ -d "$XCODE_PATH" ] || continue
  CANDIDATE_DEVELOPER_DIR="$XCODE_PATH/Contents/Developer"
  SDK_VERSION=$(DEVELOPER_DIR="$CANDIDATE_DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
  if [[ "$SDK_VERSION" == 27.* ]]; then export DEVELOPER_DIR="$CANDIDATE_DEVELOPER_DIR"; break; fi
done
[ -n "${DEVELOPER_DIR:-}" ] || { echo 'Xcode with macOS 27 SDK is required' >&2; exit 1; }
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
[[ "$SDK_VERSION" == 27.* ]] || { echo "Required SDK 27, found $SDK_VERSION" >&2; exit 1; }

BUILD_ROOT="$PWD/build/current"
[ "$PILOT_BUILD" = 0 ] || BUILD_ROOT="$PWD/build/pilot-$PILOT_BUILD"
APP_PATH="$BUILD_ROOT/Release/Arras.app"
# Replacing a running test bundle can invalidate macOS permission identity and
# leave its process loading resources from a different build. Fail before edits.
python3 - "$APP_PATH" <<'PYRUNNING'
from pathlib import Path
import subprocess, sys
target = (Path(sys.argv[1]) / 'Contents/MacOS/Arras').resolve()
try:
    processes = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True)
except subprocess.CalledProcessError:
    sys.exit('Cannot check running app copies. Run the build with process-inspection access.')
if any(Path(line.strip()).resolve() == target for line in processes.splitlines() if line.strip().startswith('/')):
    sys.exit(f'Quit the app at {sys.argv[1]} before rebuilding it. No build output was changed.')
PYRUNNING
mkdir -p "$BUILD_ROOT" "$PWD/dist"
xcodegen generate
# Never allow an earlier executable to survive a failed rebuild in the packaging location.
rm -rf "$APP_PATH"
xcodebuild -project Arras.xcodeproj -scheme Arras -configuration Release \
  -derivedDataPath "$BUILD_ROOT/DerivedData" CONFIGURATION_BUILD_DIR="$BUILD_ROOT/Release" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO ARRAS_PRIVATE_PILOT_BUILD="$PILOT_BUILD" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' \
  build > "$BUILD_ROOT/build.log" 2>&1 || {
    tail -45 "$BUILD_ROOT/build.log" >&2; exit 1;
  }
# Bash 3.2 treats an empty array as unset under nounset. Always pass the project.
VALIDATION=(--project "$PWD/project.yml")
[ "$PILOT_BUILD" = 0 ] || VALIDATION+=(--pilot-build "$PILOT_BUILD")
python3 scripts/validate_app_bundle.py "$APP_PATH" "${VALIDATION[@]}"
python3 - "$APP_PATH/Contents/MacOS/Arras" <<'PYARCH'
import subprocess, sys
assert set(subprocess.check_output(["lipo", "-archs", sys.argv[1]], text=True).split()) == {"arm64", "x86_64"}, "Expected universal Apple Silicon + Intel executable"
PYARCH
codesign --verify --deep --strict "$APP_PATH"
echo "Built and verified: $APP_PATH"
# A manually extracted app may remain beside new archives. Never silently imply
# that rebuilding the archives has updated that independently running copy.
if [ -d "$PWD/dist/Arras.app" ] && ! python3 scripts/validate_app_bundle.py "$PWD/dist/Arras.app" "${VALIDATION[@]}" >/dev/null 2>&1; then
  echo "ATTENTION: dist/Arras.app is an older extracted copy and was not updated." >&2
  echo "Quit that copy and test the verified app at: $APP_PATH" >&2
fi

if [ "$MODE" = --run ]; then
  # Launch the validated local build directly; installing must not erase an existing app.
  open "$APP_PATH"
  exit 0
fi
if [ "$MODE" = --release ] || [ "$MODE" = --pilot ]; then
  NAME=Arras
  if [ "$PILOT_BUILD" != 0 ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
    NAME="Arras-$VERSION-Telemetry-Pilot-$PILOT_BUILD"
  fi
  ZIP="$PWD/dist/$NAME.app.zip"
  DMG="$PWD/dist/$NAME.dmg"
  STAGE="$BUILD_ROOT/dmg-stage"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  ditto "$APP_PATH" "$STAGE/Arras.app"
  ln -s /Applications "$STAGE/Applications"
  python3 scripts/validate_app_bundle.py "$STAGE/Arras.app" "${VALIDATION[@]}"
  codesign --verify --deep --strict "$STAGE/Arras.app"
  rm -f "$ZIP" "$DMG"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  unzip -tq "$ZIP"
  hdiutil verify "$DMG"
  python3 scripts/verify_distribution.py "$APP_PATH" "$ZIP" "$DMG" "${VALIDATION[@]}"
  shasum -a 256 "$ZIP" "$DMG" > "$PWD/dist/$NAME.sha256"
  cp "$APP_PATH/Contents/Resources/ArrasBuildProvenance.json" "$PWD/dist/$NAME.provenance.json"
  echo "Validated local packages: $ZIP and $DMG. Nothing was published."
fi
