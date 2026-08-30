# Arras

Arras puts photos on the macOS desktop as borderless widgets at their real
aspect ratio. Each photo keeps its own size, position, depth, appearance, and
display placement without using WidgetKit's fixed grid or fixed sizes.

<p align="center">
  <img src="assets/demo.gif" alt="Arras photo widgets on a macOS desktop" width="100%" />
</p>

![macOS](https://img.shields.io/badge/macOS-14.0+-black?style=flat-square&logo=apple) ![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift) ![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square) ![Version](https://img.shields.io/badge/Version-2.4.6-green?style=flat-square)

Arras was previously Photo Widget OSX and Tableau. The bundle identifier and
storage location stayed the same, so existing layouts remain compatible.

## Current build

Version 2.4.6 is the current release:

- native glass Settings with Photos, Preferences, and Privacy tabs;
- one Settings window that opens on the active desktop Space;
- independent photo widgets with true-ratio resizing, four depth levels,
  opacity, locking, snapping, and per-display restoration;
- Spaces that rotate several images in one widget with dynamic or fixed sizing;
- frame presets, shape masks, mats, two-layer shadows, borders, edge fade, and
  tilt;
- Photos library, file picker, clipboard, drag-and-drop, screen-region, PDF,
  GIF, and APNG input;
- global visibility shortcut, Shortcuts actions, privacy controls, and portable
  `.arras` layout backups;
- daily verified automatic updates, local layout recovery, per-photo schedules,
  and durable replacement of the current image in a Space;
- unit, persistence-integration, compatibility, and real-app Settings UI tests.

The exhaustive shipped contract and honest remaining work live in
[FEATURES.md](FEATURES.md).

## Install

Requirements: macOS 14 Sonoma or later. Public artifacts are Apple Silicon;
source builds also work on Intel.

### Homebrew

```sh
brew tap yashashwi-s/tap
brew install --cask arras
xattr -dr com.apple.quarantine /Applications/Arras.app
```

### Direct download

1. Download `Arras.dmg` from the [latest release](https://github.com/yashashwi-s/Arras/releases/latest).
2. Open it and drag Arras onto the Applications shortcut.
3. If macOS blocks the first launch, open System Settings → Privacy & Security
   and choose Open Anyway, or clear quarantine:

```sh
xattr -dr com.apple.quarantine /Applications/Arras.app
```

Arras is ad-hoc signed and not notarized because the project does not currently
have a paid Apple Developer certificate.

### Updates

In current source, verified automatic updates default on and check daily. Turn
automatic installation off to keep background checks without installation; the
default cadence is daily, and a newly available version produces one macOS
notification containing its human-authored release summary. The cadence can
also be changed or disabled in Settings, and Check Now remains available.

Every public version owns `release-notes/<version>.json`; CI rejects missing or
placeholder copy. The same metadata becomes the GitHub release body, and the
release workflow stamps its validated title and summary into `appcast.json`
after uploading the artifact.

## Use

Arras is a menu bar agent. It has no Dock icon and does not appear in Command-Tab.

- Add from the menu, drop image files onto the status item, or paste with
  Command-V.
- Drag a widget to move it; drag any corner to resize without changing ratio.
- Scroll over a widget to change opacity.
- Right-click a desktop widget for lock, layering, and removal actions; use its
  Settings row or menu bar submenu for rename, replacement, duplication, and
  Space navigation.
- Double-click a Space to advance when its interval is set to On Click.
- Open Settings for full frame, global behavior, backup, and privacy controls.

## Run and verify

The intended Settings appearance is linked-SDK dependent. Use Xcode with the
macOS 27 SDK and install XcodeGen.

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

`./build.sh --run` installs the local build into Applications and launches it.
`./build.sh --release` creates local ZIP and DMG artifacts in `dist/`.

## Source map

- `Sources/App/PhotoItem.swift`: backward-compatible persisted widget model.
- `Sources/App/ImageManager.swift`: `PhotoManager`, the main state and window
  owner.
- `Sources/App/DesktopPhotoWindow.swift`: desktop window and interactive canvas.
- `Sources/App/FrameStyle.swift` and `PhotoAppearanceControls.swift`: frame model
  and mutations.
- `Sources/App/PhotoIngest.swift` and `PhotoImport.swift`: normalized import
  pipeline.
- `Sources/App/LayoutArchive.swift` and `BackupFormat.swift`: portable `.arras`
  bundles.
- `Sources/App/MainWindowView.swift`, `ContentView.swift`, `FrameInspector.swift`,
  `PreferencesView.swift`, and `PrivacyView.swift`: Settings UI.
- `Sources/App/SnapEngine.swift`, `DisplayManager.swift`, and
  `PresenceManager.swift`: placement and environment behavior.
- `Tests/Unit/`: model, scheduling, persistence, layout, and compatibility tests.
- `Tests/UI/`: launched-app Settings integration test.

Runtime ownership flows:

`input → stored media + PhotoItem → PhotoManager → AppKit windows → Core Animation`

SwiftUI edits state through `PhotoManager`; it does not own desktop windows or
persistence. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full contract.

## Project documents

- [FEATURES.md](FEATURES.md): shipped behavior, limits, and prioritized remaining work.
- [ARCHITECTURE.md](ARCHITECTURE.md): owners, dependency boundaries, persistence,
  windows, performance, and verification.
- [CHANGELOG.md](CHANGELOG.md): public version history.
- [CLAUDE.md](CLAUDE.md): repository-specific engineering and agent rules.
- [LICENSE](LICENSE): MIT license.

## Working rules

- Generate `Arras.xcodeproj` from `project.yml`; never hand-edit the project.
- Preserve backward decoding for every `PhotoItem` field.
- Use isolated storage for tests; never point a harness at the user's real
  Application Support directory.
- Keep idle work event-, timer-, or render-server-driven.
- Update README, FEATURES, and ARCHITECTURE whenever product truth or ownership
  changes.
- Keep this README at or below 200 lines.

## What remains

The researched near-term candidates are rotation policies, click actions,
captions, format validation, energy-aware behavior, richer import reporting,
image metadata, and stronger Shortcuts. Living Collage, multi-selection, saved
scenes, live albums/video, wallpaper engines, and the widget-platform roadmap
remain deferred product work.
