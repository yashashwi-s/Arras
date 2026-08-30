# Arras

Put any photo on your macOS desktop as a borderless widget sized to that photo.
No cropping, no black bars, no fixed grid.

<p align="center">
  <img src="assets/demo.gif" alt="Arras widgets on a macOS desktop" width="100%" />
</p>

![macOS](https://img.shields.io/badge/macOS-14.0+-black?style=flat-square&logo=apple) ![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift) ![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square) ![Version](https://img.shields.io/badge/Version-2.4.5-green?style=flat-square)

> Arras was **Photo Widget OSX**, then **Tableau** until v2.3.1. Only the name
> changed. The bundle identifier and your photo library are untouched, so
> updating in place keeps everything.

## Why

Apple's desktop widgets come in four fixed sizes and crop your image to fit
whichever one you pick. A 16:9 landscape loses its edges, a portrait loses its
top and bottom, and a panorama is not really a thing WidgetKit believes in.

Arras gives every photo its own window at its own proportions, then stays out of
the way: about 20 MB of memory, effectively no CPU while nothing moves, no Dock
icon, and clicking a widget never takes focus from what you were doing.

## Install

Arras is ad-hoc signed rather than notarized, so macOS blocks the first launch
with **"Apple could not verify Arras.app is free of malware."** Nothing is wrong
with the download — notarizing needs Apple's $99/year certificate and Arras is
free. Either route below clears that once.

### Homebrew

```bash
brew tap yashashwi-s/tap
brew install --cask arras
xattr -dr com.apple.quarantine /Applications/Arras.app
```

Homebrew 6 removed the `--no-quarantine` flag that used to skip the prompt, with
no replacement — casks are quarantined unconditionally now. The third line clears
the flag. Skip it and you get the dialog described below.

### Direct download

1. Download `Arras.dmg` from the [latest release](https://github.com/yashashwi-s/Arras/releases/latest)
2. Open it and drag **Arras** onto the **Applications** shortcut
3. Launch it. macOS shows the "could not verify" dialog — click **Done**
4. Open **System Settings → Privacy & Security**, scroll to Security, click
   **Open Anyway** next to the message about Arras, and confirm

Or clear the flag up front and skip steps 3 and 4:

```bash
xattr -dr com.apple.quarantine /Applications/Arras.app
```

> **Run it from Applications, not from the disk image.** Arras updates itself by
> replacing its own bundle, which a read-only disk image cannot do. Launch it
> from the image and it offers to move itself and relaunch.

## First run

Arras lives in the menu bar and has no Dock icon, so it will not appear in ⌘Tab.
Look for the photo icon at the top right.

Add a photo from the menu, or press ⌘V with an image on the clipboard. Then, on
the desktop widget itself:

- **Drag** to move. It snaps to screen edges, to your other photos, and to other
  apps' windows, with guides while you drag
- **Drag a corner** to resize. The aspect ratio stays locked
- **Scroll** to fade it between 10% and 100%
- **Right-click** for lock, remove, and layering
- **Double-click** a Space to advance to its next image

## Features

**Placement.** Each widget is its own window at its own dimensions. Layer any
photo behind your desktop icons, above them, over macOS's own widgets, or
floating above every app. Snapping works against other applications' windows too,
with no accessibility permissions. A photo whose display disconnects hides, then
returns to the same spot when that display comes back.

**Getting photos in.** ⌘V pastes a copied image straight onto the desktop. Drag
files onto the menu bar icon. Pick up to 20 from your Photos library. Drag a
rectangle to capture part of the screen and pin it. Import PDF pages. GIFs and
APNGs animate, and cost no CPU while they do — the animation runs on the render
server rather than a timer in the app.

**Spaces.** Pick several images and they become one widget that crossfades
between them: on click, every 30 seconds, hourly, daily, or an interval you set
down to 5 seconds. Each image keeps its own size and position. Sizing is either
Dynamic, where each image takes its true ratio, or Fixed, where images fill a
locked frame.

**Style.** Gallery, Polaroid, Minimal and Modern presets in one click, or set your
own: shape mask (rounded rectangle, circle, squircle, arch), photo mat, two-layer
shadow, border, vignette, and a few degrees of tilt so a cluster looks scattered
rather than gridded.

**Privacy.** Photos can stay visible to you while staying out of screen shares
and recordings. Optional auto-hide during calls, best effort, for Zoom, Teams,
QuickTime and OBS. Optional hide behind fullscreen apps, which also stops
rotation timers.

**Automation.** A global hotkey hides every photo and brings them back, `⌥⌘P` by
default. Seven App Intents drive Arras from Shortcuts and Siri. Export your whole
desktop setup as a `.arras` file and import it on another Mac.

`FEATURES.md` has the exhaustive list, including what is built but not yet
reachable.

## Why not the App Store

Apple's WidgetKit only supports four fixed sizes. Arras bypasses it with
borderless desktop windows.

That part is perfectly App Store legal, contrary to a common assumption —
sandboxing places no restriction on window levels, and Arras uses no private
APIs. The actual blocker is **updates**. Arras updates itself from GitHub, which
means replacing its own bundle and spawning a helper process that outlives it.
App Sandbox forbids both, and guideline 2.4.5(iv) reserves updating for the App
Store itself.

So it is genuinely either/or: a sandboxed App Store build, or a self-updating
free one. This is the second. A sandboxed App Store target existed briefly and
was removed — without a paid developer account it could not be signed or
submitted, so it was dead code. `FEATURES.md` records what reinstating it would
take.

## Alternatives

Everything WidgetKit-based inherits the same four fixed sizes and the same
desktop grid, which is the constraint Arras exists to avoid. The table is about
that structural difference, not about quality.

| App | Aspect ratio | Float above windows | Per-photo controls | Price | Built on |
|---|---|---|---|---|---|
| **Arras** | any | yes | full | free, MIT | desktop overlay |
| Apple Photos Widget | 4 fixed sizes | no | none | built in | WidgetKit |
| Photo Widget (Sorhus) | fixed sizes | no | none | free | WidgetKit |
| WidgetWall | fixed sizes | no | none | freemium | WidgetKit |
| Color Widgets | fixed sizes | no | limited | ~$5 | WidgetKit |
| Widgetsmith | fixed sizes | no | limited | ~$20/yr | WidgetKit |
| Superlayer | limited | yes | limited | subscription | desktop overlay |

## Requirements

- macOS 14.0 Sonoma or later
- Apple Silicon. The released build is arm64-only; building from source works on Intel

## Building from source

```bash
brew install xcodegen
git clone https://github.com/yashashwi-s/Arras.git
cd Arras
xcodegen generate
open Arras.xcodeproj      # then hit ⌘R
```

`Arras.xcodeproj` is generated. Never hand-edit it; re-run `xcodegen generate`
instead. `./build.sh` does the same thing from the command line, with `--run` to
install into Applications and launch.

## Notifying users

Arras reads [`appcast.json`](appcast.json) from `main` at launch and every six
hours. Editing that file is what reaches everyone — no server, no review.

Bump `latestVersion` after publishing a release:

```json
{
  "latestVersion": "2.1.0",
  "downloadURL": "https://github.com/yashashwi-s/Arras/releases/latest",
  "releaseNotes": "Adds per-photo rotation intervals.",
  "announcement": null
}
```

Fill in `announcement` to broadcast anything else. Change the `id` every time —
each `id` reaches a given user exactly once, so reusing one means nobody sees it:

```json
"announcement": {
  "id": "2026-08-migration",
  "title": "Heads up",
  "body": "Arras has moved to a new download page.",
  "url": "https://yashashwi.me"
}
```

Both work together; a release bump and an announcement can go out in one edit.
Anyone who denied notification permission still sees updates through **Check for
Updates…** in the menu.

Do not put a locally computed checksum in `appcast.json`. Pushing the tag makes
CI rebuild and overwrite the release assets, so a local hash describes a binary
nobody downloads and every update then fails verification.

## License

MIT. Use it, fork it, ship your own build.
