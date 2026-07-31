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
- [x] **Export/import layout** — save a `.tableau` bundle (a real zip: manifest + images) and restore it on another Mac, with a merge-or-replace choice on import. Positions are stored **relative to the screen**, so a layout keeps its shape on a Mac with different displays. Optionally carries app settings (shortcut, snapping, launch at login), off by default on export and opt-in on import so a shared layout can never silently rebind someone's system-wide shortcut. Display bindings are deliberately dropped on import — they fingerprint the exporting Mac's monitors and would otherwise arrive as an unresolvable hidden state
- [x] **Automatic theme adaptation** — opt-in per photo. In Dark Mode it dims the photo to ~80% so a bright image doesn't glare at night, deepens the shadow, and lends a hairline edge to photos that have no border of their own so they don't melt into a dark wallpaper. Adjustments are computed live and never overwrite your stored values, so switching back to Light Mode restores exactly what you configured

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

### Carried over from the original roadmap — reassessed

These were written before the app had users or a clear identity. Re-reading them
against what Tableau actually is (a desktop photo widget you set up once and then
mostly look at), several are weaker than they first appeared. Honest triage:

**Worth building**

- [ ] **Grid builder** — see Living Collage below. The one genuinely transformative item on the list
- [ ] **Apple Shortcuts support** (App Intents) — the modern, supported automation surface. Also the only one on this list Apple actively invests in, and it composes with Focus modes and Automations, which fits the privacy/presence ideas below
- [ ] **PDF pages** — small, and there's a real use case: pinning a page of reference material. PDFKit does the work

**Probably worth it, with reservations**

- [ ] **System accent colour integration** — trivially cheap (`NSColor.controlAccentColor`), but the settings panel is the only place it would show, so the payoff is small. Do it when touching that UI anyway, not as a task
- [ ] **Live web preview** (`WKWebView`) — genuinely useful for a dashboard or a clock, but it changes the app's threat model completely: arbitrary remote code, network access, and a much bigger privacy surface for something called a *photo* widget. Would want it sandboxed, opt-in, and clearly separated
- [ ] **Wallpaper-aware placement** — lovely in principle. In practice, sandbox-free wallpaper access is fine but "suggest a position" is a hard recommendation problem, and users move widgets where they want anyway. The *colour extraction* half is more valuable than the placement half — reuse it for the colour-matched glow instead

**Reconsidered — low value for the cost**

- [ ] ~~**URL scheme**~~ — `tableau://add?path=...` sounds useful but nothing would call it. Shortcuts covers scripted adding, and drag-and-drop plus ⌘V already cover manual adding. Ship only if something concrete needs it
- [ ] ~~**CLI interface**~~ — a GUI desktop-decoration app has essentially no CLI audience, and installing a binary outside the bundle is exactly the kind of thing that breaks on update and trips Gatekeeper. Hard to justify
- [ ] ~~**AppleScript dictionary**~~ — largely superseded by App Intents. Meaningful work (an `sdef`, an Apple Event surface to maintain) for a shrinking user base. Do Shortcuts instead
- [ ] ~~**Raycast extension**~~ — not this repo's job. It's a separate project in a different language, and it can be built by anyone once Shortcuts or a URL scheme exists. Better as a community contribution than a roadmap item
- [ ] ~~**iCloud sync**~~ — the *appealing* version (widgets follow you across Macs) collides with per-display and per-Space bindings, which are inherently machine-specific: syncing them faithfully would be wrong, and stripping them makes the sync half-useless. It also needs a paid account and CloudKit containers. The `.tableau` bundle already solves the real need — moving a setup once — at a fraction of the cost. Revisit only if people ask for continuous sync specifically

**Verdict:** of the eleven, three are worth building, three are conditional, and
five should probably be dropped rather than left to imply they are planned.

### Layout bundles (`.tableau`)

Relative positions, app settings, and provenance shipped; these are what's left.

- [ ] **Store originals** — images are the app's re-encoded 90% JPEGs (and re-encoded GIFs), so export → import → export compounds the loss. A `.tableau` is a layout backup, not a photo archive. Offer "archive quality" vs "layout only" so it can be either
- [ ] **Per-widget export** — share one photo or one Space, instead of all-or-nothing
- [ ] **Registered UTI + document icon** — so a `.tableau` is identifiable in Finder and double-clicking it opens Tableau
- [ ] **Thumbnail contact sheet in the manifest** — preview a bundle's contents without importing
- [ ] **Preflight item selection** — the import dialog now reports widget count, source version and export date, but is still all-or-nothing; let the user deselect individual widgets before committing

### Privacy & presence

The features most likely to be missed once you've had them.

- [ ] **Hide while screen sharing or recording** — personal photos should not join a work call. Detectable publicly on modern macOS via `CGDisplayStreamCreate` activity or `NSWorkspace` running-app checks for Zoom/Teams/QuickTime
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

### Living Collage — dynamic grids

The single biggest feature left, and the one that would most change what Tableau
*is*: instead of N independent photos, one widget that holds many images in a
composed arrangement and quietly rotates them. A photo wall that's alive rather
than a slideshow.

**The architectural break.** Every widget today is its own `NSWindow` with one
image. A collage must be **one window containing many cells**, each an
independent `CALayer`, so the whole thing drags, resizes, snaps and layers as a
single object. That is a genuine change to the `DesktopPhotoWindow` /
`DraggablePhotoView` model, not a setting — worth doing deliberately rather than
bolting cells onto the existing single-image view. `PhotoItem` would gain a
`collage` variant alongside single-image and Space.

#### Layout engines

Different source photos want different arrangements, so this needs more than a
rows × columns box:

- [ ] **Fixed grid** — literal R×C cells, everything crops to fill. Predictable, best for uniform sets
- [ ] **Hero + satellites** — one large cell with smaller ones around it. This is the "centrepiece" arrangement and should be the flagship default; it has a visual focus instead of reading as wallpaper
- [ ] **Masonry** — fixed column count, variable cell heights following each photo's true ratio. No cropping, so portraits stay portraits
- [ ] **Justified rows** — fill each row to the full width by scaling images to a common height, then break the row (the Flickr/Google Photos algorithm). Gives clean edges with zero cropping, and handles mixed orientations best of any option
- [ ] **Templates** — hand-designed arrangements (3-up strip, 2×2 with offset, polaroid scatter) for people who want a result rather than a layout engine

Shared controls: gutter width, outer padding, per-cell corner radius, and an
overall aspect lock so the collage resizes as one composition.

#### Making it live

The rotation behaviour is where this earns "dynamic", and the details are what
separate it from a screensaver:

- [ ] **Independent per-cell rotation** — each cell draws from a shared pool on its own schedule
- [ ] **Staggered timing** — the essential detail. If every cell changes together it reads as a slideshow; offsetting each cell by a random fraction of the interval makes the wall feel alive and never busy. Stagger should be the default, simultaneous the option
- [ ] **No-duplicates invariant** — with a pool barely larger than the cell count, naive random selection shows the same photo twice at once, which instantly looks broken. Selection must exclude what's already on screen, and degrade gracefully when pool size approaches cell count
- [ ] **Recency weighting** — avoid re-showing something that just left a cell
- [ ] **Hero promotion** — periodically move a photo from a satellite cell into the centre and demote the current hero, so the focal image changes without the layout changing
- [ ] **Click to promote** — click any cell to make it the hero immediately
- [ ] **Pinned cells** — lock one cell to a specific photo while the rest rotate

#### Motion

- [ ] **Per-cell crossfade** — the existing `CATransition` approach, applied per layer
- [ ] **Swap animation** — two cells exchanging photos along a curved path, rather than both crossfading in place. The signature move if it's done well
- [ ] **Hero transition** — promoting a photo should scale and translate it into the centre cell while the outgoing hero retreats, not cut
- [ ] **Ken Burns per cell** — slow pan/zoom within a cell so even a static collage breathes
- [ ] **Entrance stagger** — cells fade in sequentially when the collage first appears
- [ ] **Reduce Motion** — honour the accessibility setting by falling back to plain crossfades. Easy to forget, and this feature is exactly the kind that becomes unusable without it

#### Hard parts worth planning for

- **Performance.** A 12-cell collage with Ken Burns is 12 simultaneous animations. Everything must stay on the render server (`CAKeyframeAnimation` / `CABasicAnimation`, as the GIF work already does) — an app-side timer per cell would destroy the near-zero-CPU idle that is currently a selling point. Cells should also stop animating entirely while hidden or behind a fullscreen app
- **Memory.** Full-resolution decodes for every cell is the obvious way to blow the ~20MB footprint. Cells need downsampled decodes sized to the cell, via `CGImageSourceCreateThumbnailAtIndex`, re-decoded on resize
- **Focal point.** Crop-to-fill cuts heads off. A per-image focal point (default centre, adjustable by dragging, or auto via `VNDetectFaceRectangles`) is what makes automatic cropping acceptable
- **Resize semantics.** Does resizing the collage rescale cells or reflow the layout? Masonry and justified rows want reflow; fixed grid and templates want rescale. Should follow the engine rather than be a global setting
- **Per-cell vs whole settings.** Border, shadow and corner radius could apply per cell or to the collage as a whole. Both are legitimate; the UI needs to make clear which level is being edited, or it becomes confusing fast

### Borders, frames & depth

Today's aesthetic controls are four sliders (corner radius, shadow, border width,
edge fade). That is a solid floor, but every widget ends up looking like every
other widget. Most of the ideas below are cheap — the rendering already goes
through `CAShapeLayer` / `CAGradientLayer` sublayers in `DraggablePhotoView`,
so they are new layers rather than new architecture.

**Frames that look like real objects**
- [ ] **Photo mat (passe-partout)** — an inset border of solid colour between the frame and the image, the way a mounted print works. Probably the single biggest "this looks intentional" upgrade, and it's just an inset plus a background fill
- [ ] **Polaroid** — thick even border with a deeper bottom edge for a handwritten-style caption
- [ ] **Film strip** — sprocket-hole edges on two sides; pairs naturally with Spaces
- [ ] **Corner brackets** — viewfinder-style marks at the four corners instead of a continuous stroke. Very light visual weight, reads as deliberate
- [ ] **Torn / deckled edge** — a rough paper boundary via an alpha mask rather than a stroke

**Stroke work**
- [ ] **Gradient borders** — linear or angular colour sweep along the stroke, instead of one flat colour
- [ ] **Dashed and dotted strokes** — `CAShapeLayer.lineDashPattern` is a one-line change
- [ ] **Double border** — two concentric strokes with a gap; a classic print/gallery look
- [ ] **Inner stroke** — drawn inside the image edge rather than around it, so the widget's footprint doesn't grow
- [ ] **Per-corner radius** — asymmetric rounding (e.g. only the top two), which no competitor offers

**Depth**
- [ ] **Colour-matched glow** — sample the image's dominant colour and use it for the shadow, so the photo appears to cast light onto the desktop. This is the most modern-looking item on the list and reuses whatever colour extraction wallpaper-aware placement needs
- [ ] **Two-layer shadow** — a tight contact shadow plus a wide ambient one. Real elevation reads as two shadows, not one; a single blurred drop shadow is what makes UI look flat and dated
- [ ] **Elevation presets** — Flat / Raised / Floating, each a tuned radius+opacity+offset pair, so users get good depth without three sliders
- [ ] **Inner shadow** — makes a photo look inset into the desktop rather than sitting on it
- [ ] **Hover lift** — scale up a percent and deepen the shadow while the pointer is over a photo

**Surface & material**
- [ ] **Frosted backdrop** — an `NSVisualEffectView` behind a partly transparent photo, so it picks up wallpaper colour the way native macOS surfaces do
- [ ] **Grain / paper texture overlay** — a subtle noise layer; also masks the gradient banding that edge fade can produce on flat wallpapers
- [ ] **Gloss sweep** — a soft specular highlight across the top, for a framed-glass impression

**Shape & crop**
- [ ] **Shape masks** — circle, squircle, hexagon, arch. An arch or circle crop instantly makes a photo feel designed rather than pasted
- [ ] **Aspect crop presets** — 1:1, 4:5, 16:9 with a reposition handle, instead of being locked to the source ratio
- [ ] **Tilt** — a few degrees of rotation, so a cluster reads as a scattered pile rather than a grid

**Image treatment**
- [ ] **Filters** — black & white, sepia, duotone, faded/vintage, via Core Image
- [ ] **Brightness / contrast / saturation** — lets a busy photo sit quietly behind icons instead of competing with them
- [ ] **Edge fade strength** — currently a bare on/off; direction and intensity should be adjustable

**Applying it all**
- [ ] **Style presets** — bundle the above into named looks (Gallery, Polaroid, Minimal, Neon) so a user gets a finished result in one click. With this many knobs, presets stop being a convenience and start being the actual interface

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

## macOS 27 audit

Built and run against macOS 27.0 (SDK 27.0, deployment target 14.0).

**Found and fixed**

- **`NSMenuItem.image` is no longer drawn in a status bar menu.** The per-photo
  thumbnails silently vanished. Confirmed by instrumenting the build (image valid
  and assigned) and by setting a plain SF Symbol on items with and without
  submenus — none rendered. Thumbnails now ride in the title as an
  `NSTextAttachment`, which still renders and keeps native highlight and submenu
  behaviour. **Assume `NSMenuItem.image` is dead here** and reach for the
  attributed-title approach for any future menu iconography.
- **`disableScreenUpdatesUntilFlush()` removed.** Deprecated in macOS 15 and
  documented as doing nothing; two call sites implied a flicker guarantee that
  had not held for two releases. The synchronous layout that follows is what
  actually does the work.

**Checked and clear**

- No private APIs. `CGWindowLevelForKey(.desktopIconWindow)` and
  `collectionBehavior` still behave as expected; desktop-level widgets, Mission
  Control participation and Spaces handling are unaffected
- Carbon `RegisterEventHotKey` still works without the Accessibility permission
- `SMAppService` login items, `PhotosPicker`, `UNUserNotificationCenter`,
  `NSStatusItem` drag targets and `CAKeyframeAnimation` GIF playback all fine
- A clean build emits no deprecation warnings — though note that with a 14.0
  deployment target the compiler stays silent about anything deprecated in 15+,
  so **compiler warnings alone are not an audit**. Both findings above came from
  SourceKit against the current SDK, not from the build

---

## Distribution

Ships as a Developer ID / direct-download build only, and is **not sandboxed**.

That is forced rather than chosen: replacing `Tableau.app` and spawning a helper
that outlives the process are both forbidden under App Sandbox, so an app cannot
both update itself and be sandboxed. Notarization does not require the sandbox,
so nothing else is affected — it only rules out the App Store, which also
separately forbids a second update path (Review Guideline 2.4.5(iv)).

A sandboxed `Tableau-MAS` target existed briefly and was removed; without a paid
Apple Developer account it could not be signed or submitted, so it was dead code.
Reinstating it means restoring the `#if !MAS` guards around `Updater`,
`DownloadTask`, and `UpdateStatusView`, plus a sandboxed entitlements file.

Dropping the sandbox moves Application Support out of `~/Library/Containers`;
`StorageMigration.swift` carries existing widgets across, and refuses to
overwrite a destination that already holds a layout.

### Publishing an update

1. `./build.sh --release` — prints the SHA-256 and the exact `appcast.json` fields
2. Upload `dist/Tableau.app.zip` to a GitHub Release tagged `vX.Y.Z`
3. Paste the printed fields into `appcast.json` and push to `main`

The updater refuses any download whose checksum isn't declared, so step 3 is not
optional.

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
