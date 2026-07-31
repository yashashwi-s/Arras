# Changelog

## Unreleased — 2.3.0

**A real settings window.** Photos, Preferences and Privacy are separate tabs
now. The photo list had quietly become the home for every app-wide switch.

**Reachable with ⌘Tab.** Tableau can take a Dock slot and appear in the app
switcher, with a proper App/Edit/Window menu bar. macOS ties the Dock icon and
⌘Tab to a single setting, so it is one toggle rather than two.

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
- **Dock & ⌘Tab presence** — Tableau can now be reached from the app switcher.
  (macOS ties this to the Dock icon; they are one setting, not two.) On by
  default, toggleable from the menu bar

### Looking better

- **Animated GIFs and APNGs** play natively on the desktop. Driven by Core
  Animation on the render server, so idle CPU stays at zero
- **Dark Mode adaptation** — opt-in per photo. Dims the image so a bright photo
  does not glare at night, deepens the shadow, and lends a hairline edge to
  borderless photos so they do not melt into a dark wallpaper

### Moving your setup

- **Export / import layouts** — save everything as a single `.tableau` file and
  restore it on another Mac. Positions are stored **relative to the screen**, so
  a layout keeps its shape on a machine with different displays
- Bundles can optionally carry your app settings (shortcut, snapping, launch at
  login) — off by default when exporting, opt-in when importing, so a layout
  someone shares can never silently rebind your global shortcut

### Updates

- **Update in place.** Tableau checks a manifest on GitHub, verifies the download
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
- `.tableau` bundles store the app's re-encoded images, not your originals — a
  layout backup, not a photo archive
- Per-display and per-Space bindings deliberately do not travel between Macs;
  they describe hardware that does not exist on the other machine
