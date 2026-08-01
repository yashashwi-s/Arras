# Changelog

## 2.4.2

**Running from the disk image no longer dead-ends.** Arras replaces its own bundle
to update, which a read-only disk image cannot do, and moving a *running* app does
not change where it thinks it lives. So the old advice, move it and try again, kept
failing until you quit and reopened. Arras now offers to copy itself into
Applications and relaunch, at first launch and again if an update is attempted from
somewhere it cannot write.

**The disk image is a real drag-to-install** with an Applications shortcut, instead
of a window holding a loose app.

**Installing clears the quarantine flag** on the copy it places in Applications, so
Gatekeeper only interrupts once.

**Title bar height.** The wordmark accessory was taller than a standard title bar,
which made AppKit grow the whole bar and pushed the tab pill off centre.

## 2.4.1

**The Arras wordmark sits in the title bar**, level with the tabs, set as a
gradient masked by the glyphs so it falls off toward the baseline and reads as a
mark rather than another label.

## 2.4.0

**Photos tab header.** The Arras wordmark moves to the top right, opposite the Add
controls instead of competing with them for the left edge, where it read as a
heading for the list underneath. The rule below the header is gone; the tab bar
above it already does that job.

**Update states clear themselves after five seconds** rather than lingering.

**PureMac now says Arras** (puremac.yashashwi.me/puremac/arras, with the old URL
redirecting).

## 2.3.4

**An available update now shows in Preferences.** The card only ever appeared
above the Photos footer, so the Updates section, the place you go when you are
actually looking for an update, was the one screen that never mentioned one was
waiting.

**"Last checked in 0 seconds."** The timestamp is written a moment after the
clock is sampled, so the relative formatter read it as the future and used future
tense. Anything inside a minute now says "just now".

**Redesigned the update card.** Release notes had roughly forty characters of
width beside the button and were permanently truncated; they get the full width
underneath now. Em dashes are gone from the interface copy.

## 2.3.3

**Layering now crosses the desktop stack.** Bring to Front / Send to Back used
`orderFront`/`orderBack`, which only reorder windows *within* a level — so they
could never move a photo past a desktop icon or a macOS widget, which live at
different levels entirely. Each click now moves the photo in front of its own
siblings first, then steps it up or down through: behind desktop icons, on the
desktop, above the system's widgets, floating above app windows.

**Frame inspector layout.** The colour wells overflowed their column and painted
over the value beside them, and the Advanced section was indented by
`DisclosureGroup` so its wells ran past the edge of the sheet. Every row shares
one grid now. Clicking the word "Advanced" also expands it — the label was inert,
so only the chevron worked.

## 2.3.2

**Backup options you can actually see.** The export dialog offered a set of
checkboxes for which settings to include — and none of them rendered. As an
accessory view on an `NSSavePanel`, and then on an `NSAlert`, enabled controls
simply did not draw, while disabled ones did; the same view renders correctly in
an isolated harness and I never found the cause. The choice now lives in
Preferences as two ordinary switches — include settings when exporting, apply
them when importing — where it is visible, clickable and remembered. The import
dialog's checkbox had the same invisible-accessory problem and is gone with it.

**Backups are written as `.arras`.** `.tableau` files still open.

## 2.3.1 — Tableau is now Arras

**New name.** Same app, same bundle identifier, same photo library, same update
channel. Nothing on your Mac moves. If you installed via Homebrew the cask still
works; the app in your Applications folder keeps whatever filename it already had
when it updates in place, and fresh downloads arrive as `Arras.app`.

**Layer overlapping photos.** Right-click any widget: *Bring to Front* and *Send
to Back*. The order is saved, so it survives a relaunch — AppKit's own window
ordering does not.

## 2.3.0

**Widgets no longer steal focus.** Every photo window used to take key status
the moment it appeared, so simply having widgets on screen put Arras's menu
bar in front of whatever you were working in. They are non-activating panels
now: you can still drag, resize, scroll and right-click them, and the app never
comes forward.

**⌘Q works again.** Turning off the Dock icon used to tear down the whole main
menu, which took ⌘Q with it. The menu is installed in both modes.

**Shadows and tilt no longer crop the photo.** The window is now a padded canvas
around the photo rather than the photo itself. The old code reserved room by
shrinking the content inside a window sized to the image, insetting both axes
equally — which changed the aspect ratio and silently cropped every non-square
widget that had a shadow (7% of a 300x517 widget at defaults, 37% of a panorama
at maximum blur). Tilt rotated about the bottom-left corner while reserving
margin for a centre rotation, so corners were cut off by the window's straight
edges.

**Half the appearance panel actually applies now.** Mat, shape, stroke,
gradient, tilt and all four style presets looked up the live window by scanning
`NSApp.windows`. Widget windows are deliberately never released, so a closed one
stays in that list forever — after a single hide/show cycle, a monitor unplug or
a privacy auto-hide, those six controls were writing to a dead window.

**Snapping aligns what you can see.** It used to snap the window frame, which at
default settings sat 23pt outside the photo — nearly three times the snap
threshold, so visually correct edge alignment was literally unreachable.
Snapping now works on the photo's visible edge and also targets other
applications' windows, the system's desktop widgets and their grid. ⌘ suspends
snapping mid-drag, ⇧ constrains to one axis.

**Resize handles you can see.** The window never enabled `acceptsMouseMovedEvents`,
so the crosshair cursor never fired — installing a tracking area does not set
that for you. Four corner grips now appear on hover as well.

**Depth control.** Per photo: behind desktop icons, on the desktop, above the
system's desktop widgets, or floating above app windows. Arras previously sat
one level *below* the system's desktop widgets, so those always drew on top.
Behind-icons is inert by construction — Finder's desktop window swallows every
click — so choosing it locks the widget and says why.

**Adding photos is several times faster.** Imports are prepared concurrently off
the main actor, oversized images are downsampled with ImageIO instead of being
round-tripped through a full-resolution TIFF, already-encoded files are written
through untouched, and the batch saves once instead of once per photo.
Thumbnails are cached — adding one photo to a library of twenty used to cost
twenty full-resolution decodes on the main thread, and so did every click on the
menu bar icon.

**A settings panel you can read.** The expanded photo row is five controls
instead of fifteen; shape, corners, shadow, mat and border moved to a Frame
inspector with the fussier four behind an Advanced disclosure. Lock is a control
in the row now, not just a badge. Backup and restore is one command in
Preferences that says what it includes, and now covers every setting rather than
five of them.

**Edge Fade works.** A radial `CAGradientLayer` paints nothing beyond its
endpoint ellipse, so it drew a dark ring inside the photo and left all four
corners bright — the inverse of a vignette.

**Removed: Dock & ⌘Tab presence.** 2.2 added a setting that put Arras in the
Dock and the app switcher. It is gone — a desktop ornament asking for a Dock slot
and an app-switcher card is asking for attention it never needs, and there is
exactly one window worth returning to, a click away in the menu bar. Arras is a
menu bar app again, full stop. ⌘Q and the other standard shortcuts still work,
because the menu is installed even though the app never appears in the Dock.

**Removed: Adapt to Dark Mode.** It dimmed the photo behind your back, which
forced a compensation path in the opacity handler to stop repeated theme
switches fading a widget away.

**A real settings window.** Photos, Preferences and Privacy are separate tabs
now. The photo list had quietly become the home for every app-wide switch.

**Reachable with ⌘Tab.** Arras can take a Dock slot and appear in the app
switcher, with a proper App/Edit/Window menu bar. macOS ties the Dock icon and
⌘Tab to a single setting, so it is one toggle rather than two. *(Reverted in
2.3.0 — see above.)*

**You choose what's in the menu bar.** Optional commands can be turned on or off
in Preferences. The niche importers are off by default; Add Photo, Settings and
Quit are always there.

**Shortcuts and Siri** — seven actions: add a photo, toggle all photos, show or
hide one by name, set opacity, and step a Space forward or back.

**Frame styling** — photo mats, two-layer shadows, shape masks (circle, squircle,
arch), gradient and dashed borders, tilt, and one-click style presets.

**Privacy**
- Hide photos from screen shares and recordings while they stay visible to you
- Optionally hide them entirely while a call or recording app is running
- Hide behind fullscreen apps to free memory and stop rotation timers

**Also**
- Screen-region capture and PDF pages (both opt-in from Preferences)
- Update checks are configurable: hourly through weekly, or never
- "Up to date" no longer permanently replaces the Check for Updates button
- Settings can be exported to a file and loaded on another Mac
- Duplicating a photo now carries its frame styling

---

## 2.0.3 → 2.2.x — the big one

Seventeen new source files, ~4,700 lines added, and eleven items cleared off the
roadmap. If you have been running 2.0.3, almost everything below is new to you.

---

### Getting photos in

Adding a widget used to mean the file picker. Now:

- **Paste** — `⌘V` turns a copied image into a widget. Copy from a browser, from
  Preview, from a screenshot, or copy image *files* in Finder and paste them all
  at once
- **Drag onto the menu bar icon** — drop image files straight onto the icon
- **Capture a screen region** — drag a rectangle and pin it to the desktop.
  Probably the most useful non-photo use: a chart, a reference, a diff you keep
  glancing at
- **PDF pages** — place a page of a PDF as a widget
- **Shortcuts / Siri** — seven actions exposed to the Shortcuts app: add a photo,
  toggle visibility, show or hide a named photo, set opacity, and step a Space
  forward or back

### Living on the desktop

- **Snap to edges** — photos snap to screen edges, screen centres, and to each
  other while you drag, with alignment guides showing what they lined up with.
  The snap is magnetic rather than sticky; keep dragging and it releases
- **Global hotkey** — one shortcut hides every photo and brings them all back
  (default `⌥⌘P`, rebindable). Uses Carbon's hotkey API, so it needs **no
  Accessibility permission**
- **Per-display memory** — each photo remembers which monitor it lives on and
  exactly where. Unplug that monitor and the photo hides; plug it back in and it
  returns to the same spot
- **Pin to a Space** — keep a photo on one Space instead of all of them
- **Dock & ⌘Tab presence** — Arras can now be reached from the app switcher.
  (macOS ties this to the Dock icon; they are one setting, not two.) On by
  default, toggleable from the menu bar. *(Reverted in 2.3.0.)*

### Looking better

- **Animated GIFs and APNGs** play natively on the desktop. Driven by Core
  Animation on the render server, so idle CPU stays at zero
- **Dark Mode adaptation** — opt-in per photo. Dims the image so a bright photo
  does not glare at night, deepens the shadow, and lends a hairline edge to
  borderless photos so they do not melt into a dark wallpaper

### Moving your setup

- **Export / import layouts** — save everything as a single `.arras` file and
  restore it on another Mac. Positions are stored **relative to the screen**, so
  a layout keeps its shape on a machine with different displays
- Bundles can optionally carry your app settings (shortcut, snapping, launch at
  login) — off by default when exporting, opt-in when importing, so a layout
  someone shares can never silently rebind your global shortcut

### Updates

- **Update in place.** Arras checks a manifest on GitHub, verifies the download
  against a SHA-256, swaps itself out, and relaunches — no dragging to
  Applications. If the swap fails it rolls back, so a botched update can never
  leave you with no app
- **Check as often as you like** — hourly, every six hours, daily, weekly, or
  never. Defaults to every six hours
- After updating, Settings opens and confirms the new version

### Accessibility

- **VoiceOver support** across the settings panel: labels, hints and values for
  every icon-only button, slider and toggle

---

## Fixes worth calling out

- **Positions moved since the last save were being lost on quit.** The
  save-on-quit handler scheduled its work on a run loop turn that never came
  during shutdown, so it silently did nothing — for months
- **Menu bar thumbnails came back.** macOS 27 stopped drawing images on status
  bar menu items entirely; thumbnails are now drawn as part of the title
- **Every in-app update was failing checksum verification.** The release
  workflow rebuilds the app on its own runner and overwrites the uploaded
  artifact, so a locally computed checksum described a binary nobody would ever
  download. CI now stamps the manifest with the checksum of the file it actually
  published
- **Dark Mode adaptation did nothing visible.** It only adjusted the shadow and a
  border colour most people never set
- The footer showed the *available* version where the *current* one belongs, so
  it looked like you had already updated
- Removed a deprecated call that macOS has treated as a no-op since version 15

---

## Under the hood

- **No longer sandboxed** (direct-download build). Replacing its own bundle and
  spawning the helper that performs the swap are both forbidden under App
  Sandbox, so self-updating and sandboxing are mutually exclusive. Notarization
  does not require the sandbox. Existing data is migrated out of the old
  container automatically, and never overwrites a layout that is already there
- The App Store target was removed; without a paid developer account it could not
  be signed or submitted. `FEATURES.md` records what reinstating it would take
- Audited against **macOS 27**

---

## Known limits

- Updates are verified by checksum, not by signature. That catches a corrupted or
  tampered *download*, but **not** a compromised repository. Signature checking
  needs a paid Apple Developer certificate and is the top item on the roadmap
- `.arras` bundles store the app's re-encoded images, not your originals — a
  layout backup, not a photo archive
- Per-display and per-Space bindings deliberately do not travel between Macs;
  they describe hardware that does not exist on the other machine
