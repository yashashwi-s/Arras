# Arras

[Website](https://arras.yashashwi.me/) · [FAQ](https://arras.yashashwi.me/faqs) · [Security & Privacy](https://arras.yashashwi.me/security)

Arras places photos on the macOS desktop as independent, borderless widgets at
their natural aspect ratios. Each widget keeps its own position, size, depth,
appearance, display placement, and desktop Space behavior; it does not use
WidgetKit's fixed grid or fixed sizes.

<p align="center">
  <img src="assets/demo.gif" alt="Arras photo widgets on a macOS desktop" width="100%" />
</p>

![macOS](https://img.shields.io/badge/macOS-14.0+-black?style=flat-square&logo=apple) ![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square) ![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square) [![Latest release](https://img.shields.io/github/v/release/yashashwi-s/Arras?style=flat-square)](https://github.com/yashashwi-s/Arras/releases/latest)

## Download

**[Download the current DMG](https://github.com/yashashwi-s/Arras/releases/latest/download/Arras.dmg)** · [Release notes and ZIP](https://github.com/yashashwi-s/Arras/releases/latest)

The public download requires macOS 14 Sonoma or later. The current DMG and ZIP
contain a universal executable for Apple Silicon (`arm64`) and Intel (`x86_64`).

The public app is ad-hoc signed and is not notarized. On first launch, verify
that the file came from the official GitHub release, then use System Settings →
Privacy & Security → Open Anyway if Gatekeeper blocks it. See the
[installation guide](https://arras.yashashwi.me/#install) for the current steps.

## Highlights

- Independent, true-ratio widgets with movement, resizing, snapping, locking,
  opacity, hover reveal, four depth levels, stack order, and per-display restore.
- Slideshows (“Spaces”) with click or timed advance, previous/next navigation,
  crossfade, and dynamic or fixed sizing.
- Presets, masks, mats, borders, gradient strokes, two-layer shadows, edge fade,
  corner control, and tilt.
- Finder, Photos, clipboard, drag-and-drop, GIF/APNG, PDF page, and screen-region
  input. Transparent still images keep alpha-aware PNG storage when re-encoded.
- Local `.arras` backups, global visibility shortcut, Shortcuts actions, and
  privacy controls for screen capture, conferencing apps, and fullscreen apps.
- Verified in-place updates whose automatic-install and notification-only modes
  both follow the frequency selected in Settings.

The reviewed current behavior, including limits and permission requirements, is
the [shipped feature contract](FEATURES.md). Release-by-release history belongs
in the [changelog](CHANGELOG.md) and [GitHub releases](https://github.com/yashashwi-s/Arras/releases).

## Basic use

Arras is a menu bar agent. It has no Dock icon and does not appear in
Command-Tab.

1. Use **Add** in the menu bar, drop image files on the status item, paste with
   Command-V, or add from Photos in Settings.
2. Drag a widget to move it and drag a corner to resize without changing its
   ratio. Scroll over it to adjust opacity.
3. Right-click a widget for lock, stack, and removal commands. Use the
   **Widgets** menu for naming, replacement, duplication, and slideshow controls;
   Settings also exposes appearance and all four depths.
4. Open Settings for appearance, snapping, the global shortcut, backups,
   updates, and privacy controls.

Arras was previously Photo Widget OSX and Tableau. Its bundle identifier and
Application Support location remain unchanged so existing layouts continue to
load.

## Build and test

Arras uses Apple frameworks and has no third-party runtime dependencies. The
project file is generated from `project.yml` with XcodeGen. The current Settings
appearance requires Xcode with the macOS 27 SDK.

```sh
brew install xcodegen
xcodegen generate
./build.sh

/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project Arras.xcodeproj \
  -scheme Arras \
  -destination 'platform=macOS' \
  test
```

`./build.sh --run` installs and launches a local build. `./build.sh --release`
creates local ZIP and DMG artifacts in `dist/`; it does not publish a release.

## Project documents

- [FEATURES.md](FEATURES.md): exhaustive current shipped behavior and limits.
- [ARCHITECTURE.md](ARCHITECTURE.md): state, window, media, update, and release ownership.
- [SECURITY.md](SECURITY.md): download trust, data and network behavior, and private vulnerability reporting.
- [CONTRIBUTING.md](CONTRIBUTING.md): focused build, test, and documentation rules.
- [CHANGELOG.md](CHANGELOG.md): historical public release record.
- [LICENSE](LICENSE): MIT license.

Arras is published by [Yashashwi Singhania](https://yashashwi.me/) and developed
in the open at [yashashwi-s/Arras](https://github.com/yashashwi-s/Arras).
