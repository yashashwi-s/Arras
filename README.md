# Arras

> **Arras was called Tableau until v2.3.1.** Same app, same settings, same
> updates — only the name changed. The bundle identifier and your photo library
> are untouched, so updating in place keeps everything.

> Place any photo on your macOS desktop as a perfectly fitted, borderless widget — exactly the right aspect ratio, no cropping, no black bars.
> 
> *Note: Arras was formerly named as **Photo Widget OSX**.*

<p align="center">
  <img src="assets/demo.gif" alt="Arras Action Demo" width="100%" />
</p>

![macOS](https://img.shields.io/badge/macOS-14.0+-black?style=flat-square&logo=apple) ![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift) ![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square) ![Version](https://img.shields.io/badge/Version-2.2.1-green?style=flat-square)

## What is this?

Arras is a lightweight macOS menu bar app that places photos directly on your desktop as **borderless, always-on-desktop overlays** that perfectly match each image's native aspect ratio.

Unlike Apple's built-in WidgetKit widgets (which lock you to 4 fixed sizes and crop your images), Arras creates a custom-sized window for each photo — so a 16:9 landscape stays 16:9, a 3:4 portrait stays 3:4, and a panorama stays a panorama.

## Download

**[⬇️ Download latest release](https://github.com/yashashwi-s/Arras/releases/latest)**

## Installation

Arras is ad-hoc signed, not notarized, so the first launch is blocked by Gatekeeper with
**"Apple could not verify Arras.app is free of malware."** Nothing is wrong with the
download. Notarizing requires Apple's $99/year Developer ID certificate, and Arras is free.

Pick whichever route you prefer. Both are one-time.

### Homebrew

```bash
brew tap yashashwi-s/tap
brew install --cask arras
xattr -dr com.apple.quarantine /Applications/Arras.app
```

Homebrew 6 removed the `--no-quarantine` flag that used to skip the prompt outright, and
there is no replacement — casks are quarantined unconditionally now. The third line clears
the flag, so Arras opens without the dialog. Skip it and you get the prompt described below.

### Direct download

1. Download `Arras.dmg` from the [latest release](https://github.com/yashashwi-s/Arras/releases/latest)
2. Open it and drag **Arras** onto the **Applications** shortcut in the same window
3. Launch it from Applications. macOS blocks it and shows the "could not verify" dialog. Click **Done**
4. Open **System Settings → Privacy & Security**, scroll to Security, and click **Open Anyway**
   next to the message about Arras
5. Confirm with **Open Anyway**. It launches normally from then on

Prefer the Terminal? This does the same thing in one step, before you ever launch it:

```bash
xattr -dr com.apple.quarantine /Applications/Arras.app
```

> **Run it from Applications, not from the disk image.** Arras updates itself by replacing its
> own bundle, which a read-only disk image cannot do. If you do launch it from the image, it
> offers to move itself to Applications and relaunch.

Arras lives in your **menu bar**: look for the 📷 icon at the top right. It has no Dock icon
and does not appear in ⌘Tab.

## Quick Start

1. Launch the app — a 📷 icon appears in your **menu bar**
2. Click **Add Photo…** to pick images from Finder, **Add Space…** for a rotating set, or **Photos** to pick from your Photos library
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
- 🎚️ **Per-photo opacity** — scroll wheel on any photo to adjust (10%–100%)
- 🧲 **Snap & guides** — photos snap to screen edges and to each other, with alignment guides while dragging
- 🖥️ **Per-display memory** — a photo hides when its monitor disconnects and returns to the same spot when it reconnects

### Getting Photos In
- 📋 **Paste** — `⌘V` turns a copied image into a widget instantly
- 🫳 **Drag onto the menu bar** — drop image files right onto the icon
- ⌨️ **Global hotkey** — one shortcut hides every photo and brings them back (default `⌥⌘P`)
- 🎞️ **Animated GIFs** — GIFs and APNGs play natively, with no CPU cost when idle
- 🤖 **Shortcuts & Siri** — add photos, toggle visibility, set opacity from the Shortcuts app
- 📸 **Screen region capture** — drag a rectangle and pin it as a reference
- 📦 **Export/import layouts** — move your whole desktop setup to another Mac as a `.arras` file

### Style
- 🖼️ **Presets** — Gallery, Polaroid, Minimal, Modern in one click
- ⭕ **Shape masks** — rounded rectangle, circle, squircle or arch
- 🎞️ **Photo mat** — an inset border like a mounted print
- 🌑 **Two-layer shadow** — contact plus ambient, the way real elevation reads
- 📐 **Tilt** — a few degrees so a cluster looks scattered, not gridded

### Privacy
- 🙈 **Hide from screen sharing** — photos stay visible to you but stay out of screen shares and recordings
- 📵 **Auto-hide during calls** — best effort, for Zoom, Teams, QuickTime and OBS
- 🖥️ **Hide behind fullscreen apps** — frees memory and stops rotation timers
- ⏰ **Schedules** — show a photo only during certain hours or days

### Smart Canvas (Spaces)
- 🗂️ **Multi-image Spaces** — pick several images and they rotate inside one widget
- 🔄 **Rotation** — on click, 30s, 5m, hourly, daily, or custom interval (minimum 5s)
- 🖱️ **Double-click to advance** — double-click any Space to go to the next image
- 📐 **Per-image position & size** — each image in a Space remembers its own layout independently
- ✨ **GPU crossfade** — smooth Core Animation transition between images
- 🔲 **Sizing modes** — Dynamic (each image resizes to its true ratio) or Fixed Frame (images crop to fill a locked frame)
- ⬅️ **Previous/Next navigation** — step through a Space's images from settings or menu bar

### App Shell
- 🚀 **Launch at Login** — starts automatically with your Mac
- 🖥️ **Mission Control** — photos fly away naturally in Mission Control and App Exposé
- 📱 **Photos.app integration** — pick directly from your Photos library (up to 20 at once)
- 🔽 **Hide menu bar icon** — reopen from Spotlight to restore
- 🔄 **Live menu sync** — menu bar always reflects current state with thumbnails and status badges
- 🔍 **Reveal in Finder** — right-click any photo row to jump to the source file or folder

## Why not the App Store?

Apple's WidgetKit (what powers desktop widgets) only supports 4 fixed sizes. Arras
bypasses this entirely using borderless desktop windows.

Contrary to a common assumption, that part is perfectly App Store legal — sandboxing
places no restriction on window levels, and Arras uses no private APIs. The actual
blocker is **updates**. Arras updates itself from GitHub, and doing that requires
replacing its own bundle and spawning a helper process, both of which the App Sandbox
forbids. Guideline 2.4.5(iv) also reserves updating for the App Store itself.

So it's genuinely either/or: a sandboxed App Store build, or a self-updating free one.
We chose self-updating and free. A sandboxed App Store target existed briefly and was
removed — without a paid developer account it could not be signed or submitted, so it
was dead code. `FEATURES.md` records what reinstating it would take.

## Competitive Landscape

If you are looking for a macOS photo widget, you'll likely run into a few common alternatives. Here is exactly why Arras was built to replace them:

### 1. Apple's Native Sonoma Widgets
Apple introduced desktop widgets in macOS Sonoma, but they are deeply flawed for photography:
- **Forced Cropping:** They only support 4 fixed sizes (small square, medium rectangle, large square, extra-large rectangle). If your photo is a 16:9 landscape or an ultra-wide panorama, Apple will aggressively chop the edges off to force it into their predetermined box.
- **Invisible Grid:** Native widgets snap to a rigid, invisible grid on your desktop. You cannot freely overlap them or place them pixel-perfectly where you want.
- **Arras's Solution:** Arras dynamically scales its window to mathematically match the *exact* aspect ratio of your image file. A 16:9 image stays 16:9. You can also drag them anywhere on the screen without grid restrictions.

### 2. WidgetWall & Color Widgets
These are bloated, "all-in-one" widget suites designed to give you weather, calculators, and system stats.
- **Heavy Footprint:** Because they do so much, they consume significant memory and CPU.
- **Rigid Frames:** Just like Apple's native widgets, their photo features are an afterthought that force your images into rigid, predefined aesthetic frames.
- **Arras's Solution:** Arras does one thing: photos. It consumes ~20MB of RAM and 0% CPU at idle, utilizing native `NSWindow` structures.

### 3. PhotoStickies
A classic app for placing photos on your desktop.
- **Outdated Tech:** It lacks modern GPU acceleration for transitions, doesn't support advanced SwiftUI aesthetic controls (like drop shadows and edge fades), and doesn't dynamically remember window sizes per-image inside a rotating folder.
- **Arras's Solution:** Arras leverages modern Core Animation crossfades, a deeply integrated SwiftUI settings panel, and advanced per-photo spatial memory so your images always remember exactly where you placed them.

### 4. Workflow Integration
None of the competitors offer Arras's workflow integration. Pin a photo above all your windows as a floating reference, snap it flush against a screen edge or another photo, and clear the whole desktop with a single global shortcut when you need the space back.
| App | Custom Ratio | Floating | Per-Photo Controls | Free | Method |
|-----|:---:|:---:|:---:|:---:|--------|
| **Arras** | ✅ Any ratio | ✅ | ✅ Full suite | ✅ Free & OSS | Desktop overlay |
| Apple Photos Widget | ❌ 4 fixed sizes | ❌ | ❌ None | ✅ Built-in | WidgetKit |
| Photo Widget (Sorhus)| ❌ Fixed sizes | ❌ | ❌ None | ✅ Free | WidgetKit |
| WidgetWall | ❌ Fixed sizes | ❌ | ❌ None | Freemium | WidgetKit |
| Color Widgets | ❌ Fixed sizes | ❌ | ⚠️ Limited | ~$5 | WidgetKit |
| Widgetsmith | ❌ Fixed sizes | ❌ | ⚠️ Limited | ~$20/yr | WidgetKit |
| Superlayer | ⚠️ Limited | ✅ | ⚠️ Limited | 💰 Paid sub | Desktop overlay |

## System Requirements

- macOS 14.0 Sonoma or later
- Apple Silicon. The released build is arm64-only; building from source works on Intel

## Building from Source

```bash
# Install XcodeGen
brew install xcodegen

# Clone the repo
git clone https://github.com/yashashwi-s/Arras.git
cd Arras

# Generate Xcode project
xcodegen generate

# Open in Xcode and hit ⌘R
open Arras.xcodeproj
```

### Pushing a notification to all users

Arras checks [`appcast.json`](appcast.json) on this branch at launch and every 6 hours. Editing that file on `main` is what notifies everyone — no server, no App Store review.

**To announce a new version**, bump `latestVersion` after publishing the release:

```json
{
  "latestVersion": "2.1.0",
  "downloadURL": "https://github.com/yashashwi-s/Arras/releases/latest",
  "releaseNotes": "Adds per-photo rotation intervals.",
  "announcement": null
}
```

**To broadcast any other message**, fill in `announcement`. Change the `id` every time — each `id` notifies a given user exactly once, so reusing one means nobody sees it:

```json
"announcement": {
  "id": "2026-08-migration",
  "title": "Heads up",
  "body": "Arras has moved to a new download page.",
  "url": "https://yashashwi.me"
}
```

Clicking the notification opens `url`. Both fields work together — a release bump and an announcement can go out in the same edit. Users who have denied notification permission still see updates via **Check for Updates…** in the menu bar.

## License

MIT — use it, fork it, do whatever you want.

## Roadmap

See [FEATURES.md](FEATURES.md) for the full feature list and future roadmap, including multi-monitor support, keyboard shortcuts, grid builder, smart wallpaper integration, and more.
