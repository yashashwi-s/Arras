# Tableau

> Place any photo on your macOS desktop as a perfectly fitted, borderless widget — exactly the right aspect ratio, no cropping, no black bars.
> 
> *Note: Tableau was formerly named as **Photo Widget OSX**.*

<p align="center">
  <img src="assets/demo.gif" alt="Tableau Action Demo" width="100%" />
</p>

![macOS](https://img.shields.io/badge/macOS-14.0+-black?style=flat-square&logo=apple) ![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift) ![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square) ![Version](https://img.shields.io/badge/Version-2.0.0-green?style=flat-square)

## What is this?

Tableau is a lightweight macOS menu bar app that places photos directly on your desktop as **borderless, always-on-desktop overlays** that perfectly match each image's native aspect ratio.

Unlike Apple's built-in WidgetKit widgets (which lock you to 4 fixed sizes and crop your images), Tableau creates a custom-sized window for each photo — so a 16:9 landscape stays 16:9, a 3:4 portrait stays 3:4, and a panorama stays a panorama.

## Download

**[⬇️ Download latest release](https://github.com/yashashwi-s/Tableau/releases/latest)**

## Installation

Since Tableau is free and open source (not distributed through the App Store), macOS Gatekeeper blocks it on first launch. This is normal for any app downloaded outside the App Store.

**On macOS 15 Sequoia and later you must use the Terminal step below.** Tableau is ad-hoc signed, so macOS reports it as *"damaged and can't be opened"* rather than offering an **Open Anyway** button. The app is not damaged — the message is what Gatekeeper shows for any app without a paid Developer ID certificate.

### Install

1. Download and unzip `Tableau.zip` from the [latest release](https://github.com/yashashwi-s/Tableau/releases/latest)
2. Drag `Tableau.app` to your **Applications** folder
3. Open Terminal and run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Tableau.app
   ```
4. Double-click the app — it opens normally from now on

Tableau is a menu bar app with no Dock icon, so on first launch look for the 📷 icon in your **menu bar** (top right), not in the Dock.

### On macOS 14 Sonoma and earlier

Right-click (or Control-click) the app → **Open** → **Open** again. Apple removed this shortcut in macOS 15, which is why newer versions need the Terminal command.

> **Why does this happen?** Apple charges $99/year for a Developer ID certificate, and notarizing an app requires one. Since Tableau is free and open source, we use ad-hoc signing instead. The app is fully open source — you can audit every line of code and [build it yourself](#building-from-source) if you prefer.

## Quick Start

1. Launch the app — a 📷 icon appears in your **menu bar**
2. Click **Add Photo…** to pick images from Finder, **Add Folder…** for a rotating set, or **Photos** to pick from your Photos library
3. Your photos appear on your desktop — **drag them anywhere**
4. **Right-click** any photo to lock its position or remove it
5. **Drag corners** to resize (aspect ratio is always maintained)
6. **Scroll** on a photo to adjust its opacity
7. Click **Settings…** in the menu to customize each photo individually

## Features

### Core
- 🖼️ **Any aspect ratio** — no cropping, no black bars, ever
- 📌 **Multiple photos** — add as many as you want, each fully independent
- 🔒 **Lock position** — right-click photo or use menu bar to lock/unlock
- ↔️ **Corner resize** — drag any corner to resize (aspect ratio locked)
- 💾 **Remembers everything** — photos, positions, sizes, all settings persist across relaunches
- 🪶 **Ultra lightweight** — ~20MB RAM, zero CPU when idle

### Floating Mode
- 🪟 **Float above windows** — turn any photo into a floating reference (above all windows)
- 👆 **Click-through** — photos pass mouse events through so they never steal focus
- ⌥ **Option key override** — hold Option to interact with a click-through photo at any time
- 🎚️ **Per-photo opacity** — scroll wheel on any photo to adjust (10%–100%)

### Smart Canvas (Folders)
- 📁 **Folder import** — point a widget at any folder, only images are used
- 🔄 **Rotation** — on click, 30s, 5m, hourly, daily, or custom interval (minimum 5s)
- 🖱️ **Double-click to advance** — double-click any folder photo to go to the next image
- 📐 **Per-image position & size** — each image in a folder remembers its own layout independently
- ✨ **GPU crossfade** — smooth Core Animation transition between images
- 🔲 **Sizing modes** — Dynamic (each image resizes to its true ratio) or Fixed Frame (images crop to fill a locked frame)
- ⬅️ **Previous/Next navigation** — step through folder images from settings or menu bar

### Aesthetics (Per Photo)
- 🎨 **Corner radius** — 0px (sharp) to 50px
- 🌑 **Shadow** — toggle + blur/opacity controls
- 🖼️ **Border** — adjustable width with color picker
- 🌫️ **Edge fade** — subtle vignette that blends into your wallpaper

### App Shell
- 🚀 **Launch at Login** — starts automatically with your Mac
- 🖥️ **Mission Control** — photos fly away naturally in Mission Control and App Exposé
- 📱 **Photos.app integration** — pick directly from your Photos library (up to 20 at once)
- 🔽 **Hide menu bar icon** — reopen from Spotlight to restore
- 🔄 **Live menu sync** — menu bar always reflects current state with thumbnails and status badges
- 🔍 **Reveal in Finder** — right-click any photo row to jump to the source file or folder

## Why not the App Store?

Apple's WidgetKit (what powers desktop widgets) only supports 4 fixed sizes. Tableau bypasses this entirely using borderless desktop windows — which Apple's sandboxing rules don't allow on the App Store. So we're free and open source instead.

## Competitive Landscape

If you are looking for a macOS photo widget, you'll likely run into a few common alternatives. Here is exactly why Tableau was built to replace them:

### 1. Apple's Native Sonoma Widgets
Apple introduced desktop widgets in macOS Sonoma, but they are deeply flawed for photography:
- **Forced Cropping:** They only support 4 fixed sizes (small square, medium rectangle, large square, extra-large rectangle). If your photo is a 16:9 landscape or an ultra-wide panorama, Apple will aggressively chop the edges off to force it into their predetermined box.
- **Invisible Grid:** Native widgets snap to a rigid, invisible grid on your desktop. You cannot freely overlap them or place them pixel-perfectly where you want.
- **Tableau's Solution:** Tableau dynamically scales its window to mathematically match the *exact* aspect ratio of your image file. A 16:9 image stays 16:9. You can also drag them anywhere on the screen without grid restrictions.

### 2. WidgetWall & Color Widgets
These are bloated, "all-in-one" widget suites designed to give you weather, calculators, and system stats.
- **Heavy Footprint:** Because they do so much, they consume significant memory and CPU.
- **Rigid Frames:** Just like Apple's native widgets, their photo features are an afterthought that force your images into rigid, predefined aesthetic frames.
- **Tableau's Solution:** Tableau does one thing: photos. It consumes ~20MB of RAM and 0% CPU at idle, utilizing native `NSWindow` structures.

### 3. PhotoStickies
A classic app for placing photos on your desktop.
- **Outdated Tech:** It lacks modern GPU acceleration for transitions, doesn't support advanced SwiftUI aesthetic controls (like drop shadows and edge fades), and doesn't dynamically remember window sizes per-image inside a rotating folder.
- **Tableau's Solution:** Tableau leverages modern Core Animation crossfades, a deeply integrated SwiftUI settings panel, and advanced per-photo spatial memory so your images always remember exactly where you placed them.

### 4. Floating & Click-Through Exclusivity
None of the competitors offer Tableau's seamless workflow integration. With Tableau, you can pin a photo above all your windows, turn on **Click-Through** so your mouse clicks pass right through the photo to the apps underneath, and then instantly re-interact with the photo just by holding the **Option (⌥)** key.
| App | Custom Ratio | Floating | Per-Photo Controls | Free | Method |
|-----|:---:|:---:|:---:|:---:|--------|
| **Tableau** | ✅ Any ratio | ✅ | ✅ Full suite | ✅ Free & OSS | Desktop overlay |
| Apple Photos Widget | ❌ 4 fixed sizes | ❌ | ❌ None | ✅ Built-in | WidgetKit |
| Photo Widget (Sorhus)| ❌ Fixed sizes | ❌ | ❌ None | ✅ Free | WidgetKit |
| WidgetWall | ❌ Fixed sizes | ❌ | ❌ None | Freemium | WidgetKit |
| Color Widgets | ❌ Fixed sizes | ❌ | ⚠️ Limited | ~$5 | WidgetKit |
| Widgetsmith | ❌ Fixed sizes | ❌ | ⚠️ Limited | ~$20/yr | WidgetKit |
| Superlayer | ⚠️ Limited | ✅ | ⚠️ Limited | 💰 Paid sub | Desktop overlay |

## System Requirements

- macOS 14.0 Sonoma or later
- Apple Silicon or Intel Mac

## Building from Source

```bash
# Install XcodeGen
brew install xcodegen

# Clone the repo
git clone https://github.com/yashashwi-s/Tableau.git
cd Tableau

# Generate Xcode project
xcodegen generate

# Open in Xcode and hit ⌘R
open Tableau.xcodeproj
```

### Pushing a notification to all users

Tableau checks [`appcast.json`](appcast.json) on this branch at launch and every 6 hours. Editing that file on `main` is what notifies everyone — no server, no App Store review.

**To announce a new version**, bump `latestVersion` after publishing the release:

```json
{
  "latestVersion": "2.1.0",
  "downloadURL": "https://github.com/yashashwi-s/Tableau/releases/latest",
  "releaseNotes": "Adds per-photo rotation intervals.",
  "announcement": null
}
```

**To broadcast any other message**, fill in `announcement`. Change the `id` every time — each `id` notifies a given user exactly once, so reusing one means nobody sees it:

```json
"announcement": {
  "id": "2026-08-migration",
  "title": "Heads up",
  "body": "Tableau has moved to a new download page.",
  "url": "https://yashashwi.me"
}
```

Clicking the notification opens `url`. Both fields work together — a release bump and an announcement can go out in the same edit. Users who have denied notification permission still see updates via **Check for Updates…** in the menu bar.

## License

MIT — use it, fork it, do whatever you want.

## Roadmap

See [FEATURES.md](FEATURES.md) for the full feature list and future roadmap, including multi-monitor support, keyboard shortcuts, grid builder, smart wallpaper integration, and more.
