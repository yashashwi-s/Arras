# Tableau — Features & Roadmap

## Current Version

### Core
- [x] Desktop photo overlay — borderless `NSWindow` at `desktopIcon` level, always behind normal windows
- [x] True aspect ratio — window dimensions match the image exactly. No cropping, no letterboxing
- [x] Multiple independent photos — each gets its own window, position, size, lock state
- [x] Rounded corners (continuous curve) + drop shadow for native macOS widget look
- [x] Drag to reposition anywhere on screen
- [x] Corner resize — drag any of the 4 corners, aspect ratio always locked
- [x] Lock position toggle (right-click or menu bar)
- [x] Cursor feedback — crosshair near corners, open hand in center
- [x] Right-click context menu directly on the photo overlay (Reveal in Finder)

### Floating Mode
- [x] **Window level toggle** — switch between desktop level (behind everything) and floating level (above everything). Stored per photo, persisted across relaunches
- [x] **Opacity slider** — per-photo 10%–100%. Scroll-wheel on the photo adjusts it quickly

> Click-through and the Option-key override were removed in 2.0.2. They relied on
> `ignoresMouseEvents`, which made a photo impossible to grab again once the app
> lost focus.

### Naming & Organization
- [x] **Custom photo names** — rename from settings panel or menu bar
- [x] **Replace photo** — swaps the image file but keeps position, size, lock, name, and all settings
- [x] **Duplicate photo** — creates a copy at a slightly offset position
- [x] **Reorder photos** — drag to reorder items in the settings list
- [x] **Reveal in Finder** — right-click any row in settings to jump to the source file or folder

### Aesthetic Controls (Per Photo)
- [x] **Corner radius slider** — 0px (sharp square) to 50px
- [x] **Shadow** — toggle on/off, adjust blur radius and opacity independently
- [x] **Border** — adjustable width (0–5px) with a full color picker
- [x] **Edge fade (vignette)** — subtle gradient fade-to-transparent at photo edges

### Smart Canvas (Folder Mode)
- [x] **Folder import** — point a widget at any folder; only images are used (JPEG, PNG, HEIC, TIFF, GIF, WebP, BMP). Non-image files are silently ignored
- [x] **Live folder watcher** — `DispatchSource` monitors the folder for changes in real-time; new images appear automatically
- [x] **Rotation intervals** — On Click, 30 seconds, 5 minutes, Hourly, Daily, Custom
- [x] **Custom rotation interval** — text field for any interval in seconds (minimum 5s)
- [x] **Double-click to advance** — double-click the desktop photo to cycle to the next image (works even when position is locked)
- [x] **Per-image position & size** — each image in a folder remembers its own position and size independently. Drag image A somewhere, switch to B, switch back — A is exactly where you left it
- [x] **GPU-accelerated crossfade** — `CATransition.fade` on the image layer for smooth image transitions
- [x] **Simultaneous frame animation** — window frame and aesthetic layers (border, vignette, corner radius) animate in sync with the crossfade
- [x] **Top-left pin** — window pins its top-left corner during height changes so it doesn't jump
- [x] **Sizing modes** — toggle a folder between "Dynamic Fit" (images resize to their true aspect ratio, each remembers its own size) and "Fixed Frame" (widget stays fixed, images scale and crop to fill)
- [x] **Previous/Next navigation** — step backwards or forwards through folder images from settings or menu bar

### Mission Control Integration
- [x] Windows participate natively in Mission Control (3-fingers up) and App Exposé (3-fingers down) — photos fly away and arrange themselves with other app windows instead of pinning to the desktop background

### App Shell & Settings Panel
- [x] Menu bar agent (`LSUIElement`) — no dock icon, no window clutter
- [x] Full `NSStatusItem` menu: add, show/hide, lock/unlock, remove per photo — with per-photo thumbnails and status badges (hidden, locked, floating, folder)
- [x] **NSMenuDelegate** — menu rebuilds every time it opens, always in sync with state
- [x] Settings window with expandable photo rows, visibility toggle, trash button, and per-photo controls
- [x] **Hover backgrounds** — rows highlight on hover; full-row click target to expand/collapse
- [x] **Grouped settings** — MODE, APPEARANCE, SMART CANVAS sections with uppercase headers
- [x] **Photos.app integration** — pick directly from Photos library via `PhotosPicker` (up to 20 at once)
- [x] Multi-select file picker — JPEG, PNG, HEIC, TIFF supported
- [x] Launch at Login via `SMAppService`
- [x] Hide menu bar icon (reopen from Spotlight/Applications to restore)
- [x] Remove All Photos action in menu bar

### Performance & Persistence
- [x] ~20MB RAM, near-zero CPU at idle — no polling, no background threads except the folder watcher
- [x] Joins all Spaces (`canJoinAllSpaces`, `stationary`)
- [x] All state saved to `~/Library/Application Support/PhotoWidget/photos.json`
- [x] Photos stored as JPEG copies (90% quality) in the same directory
- [x] Position, size, lock state, visibility, all aesthetic settings — all restored on relaunch
- [x] Atomic save on quit (`NSApplication.willTerminate`) and on every drag/resize

### CI/CD
- [x] Local `build.sh` — `--run` installs and launches without opening Xcode, `--release` packages `.zip` and `.dmg`
- [x] GitHub Actions CI — builds on every push and PR to `main`, validates app bundle size
- [x] GitHub Actions Release — automatically builds, packages, and publishes to GitHub Releases on any `v*` tag push

### Input & Automation
- [x] **Paste from clipboard** — `⌘V` creates a widget from a clipboard image, or from copied image files
- [x] **Drag & drop onto menu bar icon** — drop image files straight onto the status item
- [x] **Global hotkey** — a system-wide shortcut hides every photo, then brings them all back. Opt-in, rebindable, defaults to `⌥⌘P`. Uses Carbon `RegisterEventHotKey`, so it needs no Accessibility permission

### Placement
- [x] **Snap to edges** — magnetic snapping to screen edges/centers and to other photos while dragging
- [x] **Alignment guides** — temporary 1px guides appear whenever a drag lines up with something
- [x] **Per-display profiles** — each photo remembers its display and exact frame there; it hides when that monitor disconnects and returns to the same spot when it comes back
- [x] **Space binding** — pin a photo to the Space it currently sits on instead of joining all Spaces

### Content & Portability
- [x] **Animated GIF playback** — GIFs and APNGs animate natively, driven by a `CAKeyframeAnimation` on the render server so idle CPU stays at zero
- [x] **Export/import layout** — save a `.tableau` bundle (a real zip: manifest + images) and restore it on another Mac, with a merge-or-replace choice on import
- [x] **Automatic theme adaptation** — opt-in per photo; strengthens shadow and lightens the border when macOS switches to Dark Mode, without overwriting your configured values

### Updates & Accessibility
- [x] **In-app updater** — checks a GitHub appcast, verifies SHA-256, and installs + relaunches in one click. Also checks weekly in the background
- [x] **VoiceOver support** — labels, hints and values across the settings panel, including every icon-only button and slider

---

## Roadmap Status

The original "Later" list had 22 items. **11 are done**, 11 remain — plus an
in-app updater and an App Store target that weren't on the list at all.

| Done | Remaining |
|---|---|
| Per-display profiles · Space binding · Snap to edges · Alignment guides · Global hotkey · Animated GIF playback · Paste from clipboard · Drag & drop onto menu bar · Theme adaptation · Export/import layout · VoiceOver | Apple Shortcuts · URL scheme · CLI · Live web preview · PDF pages · Grid builder · Wallpaper-aware placement · iCloud sync · AppleScript · Raycast extension · Accent color |

---

## Later

### Carried over from the original roadmap

- [ ] **Apple Shortcuts support** — expose actions (add photo, toggle visibility, set opacity) to the Shortcuts app via App Intents
- [ ] **URL scheme** — `tableau://add?path=...` for integration with other apps
- [ ] **CLI interface** — `tableau add ~/path/to/image.jpg --floating --opacity 0.5`
- [ ] **Live web preview** — embed a `WKWebView` to display a live webpage as a desktop widget
- [ ] **PDF pages** — display a specific page from a PDF
- [ ] **Grid builder** — define rows/columns, drag photos into cells; the whole grid moves as one object
- [ ] **Wallpaper-aware placement** — detect wallpaper's dominant colours and suggest positions that don't clash
- [ ] **iCloud sync** — sync widgets across your Macs (opt-in per photo)
- [ ] **AppleScript dictionary** — full scriptability: add/remove photos, set properties, query state
- [ ] **Raycast extension** — search, toggle, and manage photos directly from Raycast
- [ ] **System accent color integration** — apply the user's macOS accent colour to UI elements

### Privacy & presence

The features most likely to be missed once you've had them.

- [ ] **Hide while screen sharing or recording** — personal photos should not join a work call. Detectable publicly on modern macOS via `CGDisplayStreamCreate` activity or `NSWorkspace` running-app checks for Zoom/Teams/QuickTime
- [ ] **Hide when a fullscreen app is frontmost** — desktop widgets are invisible behind fullscreen apps anyway; tearing them down reclaims the memory and stops rotation timers
- [ ] **Focus filter integration** — tie visibility to macOS Focus modes, so Work hides the holiday photos and Personal brings them back
- [ ] **Schedule** — show a widget only between certain hours, or only on certain weekdays
- [ ] **Peek on hover** — keep a photo at low opacity and fade it to full when the pointer rests on it, so it can live somewhere busy without being noise

### Layout & editing

- [ ] **Scenes** — named layouts (Work, Weekend, Presentation) switchable from the menu bar or a hotkey. A natural extension of the `.tableau` export that already exists
- [ ] **Multi-select + align/distribute** — select several photos and align edges or distribute spacing evenly, the way a design tool does
- [ ] **Snap to grid** — an optional fixed grid in addition to the existing edge snapping, for deliberately tidy arrangements
- [ ] **Keyboard nudge** — arrow keys move the selected photo 1pt, ⇧arrow 10pt. Far more precise than dragging
- [ ] **Appearance presets** — save a look (corner radius, shadow, border, fade) and apply it to other photos in one click, instead of re-dialling every slider
- [ ] **Copy/paste style** — ⌥⌘C / ⌥⌘V between photos
- [ ] **Rotation / tilt** — a few degrees of tilt makes a scattered photo-pile look natural rather than gridded
- [ ] **Search & filter in settings** — matters once a user has 20+ widgets

### Content sources

- [ ] **Screenshot region to widget** — drag a region of the screen and pin it as a persistent reference. Probably the single most useful non-photo use case
- [ ] **Muted video / Live Photo loops** — the animation pipeline built for GIFs generalises to short silent video
- [ ] **Photos album sync** — point a Space at a Photos smart album so it follows the album as you add to it, rather than being a one-time copy
- [ ] **Window mirror** — show a live miniature of another app's window (a chart, a log, a build) pinned to the desktop
- [ ] **Caption overlay** — optional text on a photo: a label, a date, a countdown

### Smart Canvas

- [ ] **Shuffle** — random order rather than sequential, with no immediate repeats
- [ ] **Ken Burns effect** — slow pan and zoom across each image instead of a static hold
- [ ] **Transition styles** — slide, push, or zoom alongside the existing crossfade
- [ ] **Synchronised rotation** — several Spaces advancing together on one clock, so a wall of photos changes as a set
- [ ] **Favourites weighting** — show starred images more often

### System behaviour

- [ ] **Pause on battery** — stop rotation timers and GIF playback on battery or in Low Power Mode. Currently a many-widget setup costs the same either way
- [ ] **Menu bar quick peek** — a popover with thumbnails and per-photo toggles, so common actions don't require opening Settings
- [ ] **Automatic layout backup** — keep the last few `photos.json` revisions so a mistaken "Remove All" is recoverable
- [ ] **Mirror to all displays** — duplicate one widget across every connected monitor in a single action
- [ ] **Sleep/wake hygiene** — tear down animations on sleep and restore on wake, rather than leaving the render server looping

### Distribution & trust

- [ ] **Signed updates** — verify the downloaded bundle's Team ID against the running app. The current SHA-256 check catches a corrupted or tampered download but **cannot** detect a compromised repo. This is the most important item on this list and needs a paid Apple Developer account
- [ ] **Delta updates** — ship only what changed instead of a full 3MB bundle
- [ ] **Release notes in-app** — show what changed before the user commits to updating

---

## Distribution

Two targets build from identical sources:

| | `Tableau` (Developer ID) | `Tableau-MAS` (App Store) |
|---|---|---|
| Sandbox | off | on |
| Self-updater | yes | compiled out (`#if !MAS`) |
| Build | `./build.sh` | `./build.sh --mas` |

**These are mutually exclusive by design.** Replacing `Tableau.app` and spawning a
helper that outlives the process are both forbidden under App Sandbox, so an app
cannot both update itself and be sandboxed. Notarization does not require the
sandbox, so the Developer ID build is unaffected; the MAS target exists for
whenever a paid Apple Developer account is available, and App Store Review
Guideline 2.4.5(iv) is why it drops the updater.

Dropping the sandbox moves Application Support out of `~/Library/Containers`;
`StorageMigration.swift` carries existing widgets across, and refuses to
overwrite a destination that already holds a layout.

---

## Architecture

```
Sources/App/
├── PhotoWidgetOSXApp.swift   # @main — delegates everything to AppDelegate
├── AppDelegate.swift         # NSStatusItem menu (NSMenuDelegate) + settings window lifecycle
├── ContentView.swift         # SwiftUI settings UI (photo list, toggles, PhotosPicker, grouped controls)
├── DesktopPhotoWindow.swift  # Borderless NSWindow + DraggablePhotoView (drag/resize/snap/crossfade)
├── PhotoItem.swift           # Codable model: all per-photo settings + FolderImageConfig
├── ImageManager.swift        # PhotoManager — add/remove/persist + window creation + rotation
├── PhotoImport.swift         # Shared pasteboard / drag import path
├── StatusItemDropView.swift  # Drop target overlaid on the menu bar button
├── HotKeyManager.swift       # Carbon global hotkey + Shortcut model
├── ShortcutRecorder.swift    # SwiftUI click-to-record shortcut control
├── SnapEngine.swift          # Edge/center snapping geometry
├── SnapGuideOverlay.swift    # Transparent window that draws alignment guides
├── AnimatedImage.swift       # PhotoContent + GIF/APNG decode and re-encode
├── DisplayManager.swift      # Stable display identity across reconnects
├── LayoutArchive.swift       # .tableau export/import (zip writer/reader)
├── Updater.swift             # Appcast check, download, verify, swap, relaunch
├── DownloadTask.swift        # Progress-reporting download
├── UpdateStatusView.swift    # Version + Check for Updates control
├── StorageMigration.swift    # Carries data out of the old sandbox container
└── Assets.xcassets/
    └── AppIcon.appiconset/   # 16px–1024px icon variants
```

**Storage:**
```
~/Library/Application Support/PhotoWidget/
├── photos.json               # Array of PhotoItem (atomic write, pretty-printed)
│                              # Includes per-image FolderImageConfig for folder photos
└── *.jpg                     # JPEG copies at 90% quality (single-image photos only)
```

**Key Design Decisions:**
- `NSMenuDelegate.menuNeedsUpdate` rebuilds the menu lazily each time it opens — always in sync
- `FolderImageConfig` stores per-image position/size keyed by filename within each `PhotoItem`
- `CATransition.fade` for GPU-accelerated crossfade, simultaneous with `NSAnimationContext` frame animation
- All SwiftUI animations use `easeInOut` only — no springs, no bounces, matching native macOS feel
- Settings panel uses hover state + background transitions for interactive feedback
- `isReleasedWhenClosed = false` on all `DesktopPhotoWindow` instances to prevent use-after-free on re-show
