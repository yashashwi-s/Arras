# Arras feature contract

Status: active. Version 2.4.5 is the current public build. This document records
what users can reach today, the limits attached to those features, and the next
work in priority order. It is not a dump of every idea the project has had.

## Locked product essentials

- Arras is a macOS menu bar agent with no Dock or Command-Tab presence.
- Every widget is an independent borderless AppKit window at the source image's
  aspect ratio; there is no fixed WidgetKit grid or forced crop.
- Widgets do not take focus from the active application.
- Position, size, visibility, depth, lock state, appearance, display placement,
  and Space behavior survive relaunch.
- Ordinary idle work stays near zero CPU. Animated content runs on Core
  Animation; schedules and rotation use bounded timers rather than frame loops.
- Local media is copied into Application Support so widgets do not depend on the
  original file remaining in place.
- The app remains usable without Accessibility, Screen Recording, or network
  permissions.

## Shipped behavior

### Desktop widgets

- Multiple independent widgets with drag movement and four-corner,
  aspect-locked resizing.
- Four depth levels: behind desktop icons, on the desktop, above system desktop
  widgets, and floating above application windows.
- Per-widget visibility, locking, opacity from 10–100%, naming, duplication,
  replacement, removal, and saved stack order.
- Right-click actions on the desktop widget and live status/thumbnail controls
  in the menu bar.
- Native Mission Control and App Exposé participation.

### Placement

- Magnetic snapping to screen edges and centers, the macOS desktop-widget
  gutter/grid, other Arras widgets, and other applications' window bounds.
- Command temporarily disables snapping; Shift constrains movement to one axis.
- Solid and dotted alignment guides distinguish real and extrapolated edges.
- Per-display home frames hide a widget when its display disconnects and restore
  it when that display returns.
- A widget may join all Spaces or bind to its current Space.

### Spaces

- Several images rotate inside one widget and remain available after the source
  files move.
- On Click, 30-second, five-minute, hourly, daily, and custom intervals.
- Previous/next navigation and appending more images to an existing Space.
- Dynamic sizing preserves each image's ratio, position, and size; fixed sizing
  crops images into one stable frame.
- Crossfade, frame, and appearance animations move together.

### Appearance

- Gallery, Polaroid, Minimal, Modern, and Custom styles.
- Rounded rectangle, circle, squircle, and arch masks driven by one shared path.
- Photo mat, corner radius, solid/dashed/dotted borders, optional gradient
  stroke, two-layer shadow, edge fade, and ±12° tilt.
- Frame editing lives in one inspector with a consistent label/control/value
  grid and an Advanced disclosure.

### Input and content

- Multi-select image picker for JPEG, PNG, HEIC, and TIFF.
- Photos library selection for up to 20 items.
- Clipboard paste and file drop onto the menu bar icon.
- Animated GIF and APNG playback on the render server.
- Screen-region capture and PDF-page import, both opt-in menu commands.

### Settings and control

- One native glass Settings window with Photos, Preferences, and Privacy tabs.
- Settings opens on the active desktop Space rather than switching Spaces.
- Expandable photo rows keep common controls inline and open frame detail only
  when requested.
- Customizable menu bar with fixed escape hatches for Add Photo, Settings, and
  Quit.
- Launch at Login, optional hidden status item, and a rebindable global
  show/hide shortcut that requires no Accessibility permission.
- Seven App Intents cover add, global visibility, named visibility, opacity,
  and Space navigation.

### Privacy and presence

- Window-server exclusion keeps photos out of screenshots and ordinary screen
  recordings while they remain visible locally.
- Best-effort hiding while Zoom, Teams, QuickTime, OBS, or Screenshot is
  running.
- Optional teardown behind fullscreen apps to release image memory and stop
  rotation work.
- Scheduling engine handles weekdays, daytime windows, overnight windows, and
  next-boundary calculation.

### Portability and persistence

- One `.arras` archive contains widgets, copied media, portable relative frames,
  and optional groups of application preferences.
- Import supports merge or replace. Replacement validates and stages usable
  archive content before deleting the current layout.
- Imported widgets receive fresh identifiers and filenames; machine-specific
  display bindings are intentionally discarded.
- `photos.json` is atomically written and older model versions decode through
  explicit defaults.
- Remove All requires confirmation.

### Accessibility and quality

- VoiceOver labels, hints, and values cover Settings controls, including
  icon-only buttons and sliders.
- Unit tests cover schedule boundaries, model compatibility, layout restoration,
  and Settings-window configuration.
- Persistence integration tests use isolated storage and cover relaunch,
  archive round-trip, and damaged replacement behavior.
- A launched-app UI test visits every Settings tab and asserts one window.
- CI runs tests and a Release build against the macOS 27 SDK.

## Known limits

- Behind-desktop-icons windows cannot receive input because Finder owns the
  covering desktop window. Arras locks them when that depth is selected.
- Screen-capture exclusion cannot cover AirPlay or HDMI mirroring.
- Call detection is process-based, cannot prove that sharing is active, and
  cannot detect browser calls.
- Per-photo schedules have a tested engine but no user-facing editor yet; they
  are not a shipped user feature until that UI exists.
- Replacing the currently displayed image of a Space changes the live view but
  does not yet write that replacement into the Space slot on disk.
- `.arras` bundles contain Arras's stored/re-encoded media rather than original
  source files; they are layout backups, not archival masters.
- Public release artifacts are Apple Silicon and ad-hoc signed. Intel is
  supported only through a source build.

## Next work

Ordered by correctness and recoverability before new product surface:

1. Add the per-photo schedule editor and verify overnight/weekday behavior in
   the real Settings UI.
2. Keep recoverable revisions of `photos.json` so accidental or corrupt state
   changes have a local rollback path.
3. Persist replacement of an individual Space image instead of swapping only
   the current in-memory content.
4. Surface persistence failures rather than silently ignoring failed writes or
   undecodable state.
5. Expand VoiceOver and keyboard traversal checks across the Frame inspector
   and destructive confirmation flows.

## Deferred product work

- Living Collage: one window containing a composed, rotating multi-image grid.
- Multi-select with align, distribute, keyboard nudge, and copy/paste style.
- Named scenes for switching complete desktop layouts.
- Archive-quality export, per-widget export, registered `.arras` document type,
  and import preflight selection.
- Photos album sync, muted video/Live Photo loops, captions, filters, and
  optional low-power behavior.

These require separate product and architecture decisions; none is implied by
the current UI.

## Deliberately not planned

- URL scheme: Shortcuts, drag/drop, and clipboard input already cover the real
  automation paths.
- CLI: it adds installation and support complexity to a visual desktop app.
- AppleScript dictionary: App Intents cover the maintained automation surface.
- Bundled Raycast extension: that belongs in an independent integration project.
- Continuous iCloud layout sync: display and Space bindings are intentionally
  machine-specific; `.arras` handles explicit transfer without pretending those
  bindings are portable.

## macOS 27 compatibility findings

- `NSMenuItem.image` does not render reliably in the status menu; thumbnails use
  an `NSTextAttachment` inside the attributed title while retaining plain text
  for accessibility and search.
- `disableScreenUpdatesUntilFlush()` was removed because it is deprecated and
  ineffective on supported systems.
- Desktop window levels, Space collection behavior, Carbon global hotkeys,
  `SMAppService`, `PhotosPicker`, App Intents, `NSStatusItem` drop targets, and
  render-server animation remain in active use.

Update this document whenever a feature becomes reachable, a limit changes, or
an item moves in priority. Do not list the same behavior as both shipped and
future work.
