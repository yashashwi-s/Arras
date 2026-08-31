# Arras feature contract

Status: active for version 2.4.6. This document records reachable behavior, its
limits, and the next work in priority order. It is not a dump of every idea the
project has had.

## Locked product essentials

- Arras is a macOS menu bar agent with no Dock or Command-Tab presence.
- Every widget is an independent borderless AppKit window at the source image's
  aspect ratio; there is no fixed WidgetKit grid or forced crop.
- Widgets do not take focus from the active application.
- Position, size, visibility, depth, lock state, appearance, display placement,
  and Space behavior survive relaunch.
- Ordinary idle work stays near zero CPU. Animated content runs on Core
  Animation; Space rotation uses bounded timers rather than frame loops.
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
- Verified automatic updates default on and check daily. Turning them off
  preserves a separately configurable background-check cadence that defaults to
  daily; a newly available version then produces one macOS notification with
  its version and deliberate release summary.
- Check Now remains available regardless of background policy. Automatic
  installation uses the same HTTPS, checksum, archive, bundle-identity,
  advertised-version, and rollback gates as a manual install.

### Privacy and presence

- Window-server exclusion keeps photos out of screenshots and ordinary screen
  recordings while they remain visible locally.
- Best-effort hiding while Zoom, Teams, QuickTime, OBS, or Screenshot is
  running.
- Optional teardown behind fullscreen apps to release image memory and stop
  rotation work.

### Portability and persistence

- One `.arras` archive contains widgets, copied media, portable relative frames,
  and optional groups of application preferences.
- Import supports merge or replace. Replacement validates and stages usable
  archive content before deleting the current layout.
- Imported widgets receive fresh identifiers and filenames; machine-specific
  display bindings are intentionally discarded.
- `photos.json` is atomically written and older model versions decode through
  explicit defaults. A failed write leaves the last valid file untouched.
- Archive replacement validates and stages every media payload before changing
  the live model, so damaged input cannot erase a working layout.
- Replacing the current image in a Space updates that persisted slot, carries
  its saved frame metadata forward, and survives hidden widgets and relaunch.
- Remove All requires confirmation.

### Accessibility and quality

- VoiceOver labels, hints, and values cover Settings controls, including
  icon-only buttons and sliders.
- Unit tests cover model compatibility, layout restoration, updater precedence,
  and Settings-window configuration.
- Persistence integration tests use isolated storage and cover relaunch,
  archive round-trip, damaged replacement, and durable Space replacement.
- Launched-app UI tests visit every Settings tab, exercise the Frame inspector's
  Advanced disclosure, and cover destructive confirmations in one Settings window.
- CI runs tests and a Release build against the macOS 27 SDK.

## Known limits

- Behind-desktop-icons windows cannot receive input because Finder owns the
  covering desktop window. Arras locks them when that depth is selected.
- Screen-capture exclusion cannot cover AirPlay or HDMI mirroring.
- Call detection is process-based, cannot prove that sharing is active, and
  cannot detect browser calls.
- `.arras` bundles contain Arras's stored/re-encoded media rather than original
  source files; they are layout backups, not archival masters.
- Per-photo schedules, automatic layout history, and a Settings-facing
  persistence diagnostics surface are not part of the 2.4.6 shipped scope;
  explicit `.arras` backups are the supported recovery path.
- Public release artifacts are Apple Silicon and ad-hoc signed. Intel is
  supported only through a source build.

## 2.4.6 shipped scope

Included in version 2.4.6:

1. Daily, verified automatic updates with deliberate release notes and CI
   validation. The updater keeps its HTTPS, checksum, archive, identity,
   advertised-version, and rollback gates.
2. Atomic layout writes and damaged-data preservation. Portable `.arras` import
   stages and validates all media before merge or replacement, leaving a working
   layout intact when input is damaged.
3. Durable replacement of an individual Space image, including saved frame
   metadata migration and shared-media safety across hidden widgets and relaunch.
4. Expanded accessibility labels and keyboard-reachable controls, including the
   Frame inspector's Advanced disclosure and destructive confirmation flows.

### Deliberately excluded from 2.4.6

Per-photo visibility schedules, automatic layout revisions/recovery UI, and
Settings-facing persistence diagnostics were removed to keep the product lean.
Failures remain available through system logs, while explicit `.arras` files
are the supported backup and transfer path.

## Researched feature landscape

Research checked the current macOS wallpaper, photo-frame, and desktop-widget
market in August 2026. Arras should not compete on raw feature count. Its useful
position is a local-first, true-ratio photo desktop where each image keeps its
own frame, position, and identity.

Apple's own wallpaper supports Finder folders and Photos albums with rotation,
while dedicated photo-frame apps commonly add ordering, no-repeat playback,
captions, smart framing, and broader media. The closest direct comparison,
FrameArabica, emphasizes independent folder-backed frames and lightweight large
folder handling. Those are stronger signals than the web-widget, audio, and
community-library features found in general wallpaper engines.

Research references:

- [Apple: change Wallpaper settings](https://support.apple.com/en-ie/guide/mac-help/mchlp3013/mac)
- [Apple: desktop widgets on Mac](https://apps.apple.com/us/mac/story/id1699687142)
- [Photo Widget](https://sindresorhus.com/photo-widget)
- [Photo Album Widget](https://photoalbumwidget.app/)
- [FrameArabica](https://getapps.cafe/app/framearabica)
- [Digital Photo Frame for Mac](https://digitalphotoframeapp.com/mac/)
- [WidgetWall](https://apps.apple.com/sg/app/widgetwall/id1618466427?mt=12)
- [Aerial](https://aerialscreensaver.github.io/features/)
- [Wallper](https://www.wallper.app/)
- [Plash](https://sindresorhus.com/plash)
- [Hologram](https://gethologram.com/)

### Near-term product candidates

These are understandable user-facing additions, but each changes a persisted
choice or interaction and therefore needs a small product decision before code:

- Rotation policy per Space: ordered, random, newest-first, and no-repeat.
- Click action per widget: advance, Quick Look, reveal stored media, copy path,
  or open the source application.
- Caption overlay: custom caption and filename first; capture date and location
  only when metadata is available locally.
- A hard-cut transition alongside the current crossfade. More elaborate zoom,
  dip-to-black, and Ken Burns effects stay deferred.
- WebP and BMP import validation. Format support must be proven through the
  complete ingest, persistence, relaunch, and render path—not just by file type.
- Energy-aware animation and rotation using macOS Low Power Mode, thermal state,
  and Reduce Motion. Pausing must not corrupt the saved rotation schedule.
- Better failed-import summaries so Finder, clipboard, Photos, and Space batches
  report accepted, skipped, and failed items consistently.
- Image information in the inspector: dimensions, orientation, color profile,
  and locally available EXIF fields.
- More App Shortcuts backed by stable widget identifiers rather than names.
- Finder-open routing for `.arras` archives without converting the app into a
  document-based application.

Relevant Apple frameworks include
[Image I/O](https://developer.apple.com/documentation/imageio),
[Quick Look Thumbnailing](https://developer.apple.com/documentation/quicklookthumbnailing),
[App Intents](https://developer.apple.com/documentation/appintents),
[Uniform Type Identifiers](https://developer.apple.com/documentation/uniformtypeidentifiers),
[Low Power Mode](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled),
and [thermal state](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property).

### Medium product and architecture work

- Live Finder-folder Spaces with security-scoped bookmarks, change watching,
  reconciliation, missing-folder recovery, and explicit cache behavior.
- Live Photos, Smart Album, and Shared Album sources. This needs authorization
  changes, iCloud-only asset downloads, membership updates, and stale-result
  handling through
  [PhotoKit collections](https://developer.apple.com/documentation/photos/phassetcollection)
  and
  [photo-library change observation](https://developer.apple.com/documentation/photos/phphotolibrarychangeobserver).
- Manual focal points followed, only if useful, by local face or saliency-based
  framing. Smart framing must never change Arras's true-ratio default.
- Multi-select with align, distribute, keyboard nudge, duplication, and
  copy/paste style.
- Named scenes for switching complete layouts manually or on a schedule.
- Fullscreen or second-display digital-frame mode.
- Archive-quality export, per-widget export, and import preflight selection.
- Power-aware video behavior and per-display quality controls.

### Deferred product directions

- Living Collage: one composed, rotating multi-image canvas. This changes the
  one-widget/one-image ownership model and needs its own design pass.
- Muted video and Live Photo playback. This adds AVFoundation lifecycle,
  caching, wake/sleep, and energy-policy work; general-purpose Live Photo
  playback also has macOS platform constraints.
- Lock Screen integration and a full live-wallpaper engine.
- HTML/CSS/JavaScript widgets or arbitrary web surfaces.
- A curated/community wallpaper library or marketplace.
- Ambient audio, weather particles, cursor effects, animated text, and
  generative backgrounds.
- Calendar- or Focus-driven automation. macOS does not expose the active named
  Focus as a general-purpose app API; a Focus Filter requires a separate App
  Intents extension and shared-state design.
- Continuous iCloud layout sync. Display and Space bindings are intentionally
  machine-specific; explicit `.arras` transfer remains the safer contract.

### Long-term deferred target: an actual widget platform

This is a future product target, not current implementation. Arras today is a
local-first AppKit photo-widget app; none of the phases below is a shipped
third-party API, package format, permission model, or network feed.

- **Phase 0 — host contract and first-party baseline.** Define a small widget
  lifecycle for configuration, rendering, optional interaction, and timeline
  refresh, plus size/availability rules, state isolation, and a capability
  manifest. Ship a few first-party widgets first to prove accessibility,
  recovery, and energy behavior before opening the host to outside developers.
- **Phase 1 — first-party widget families.** Add useful platform-aware widgets
  (for example local media, calendar, or system status) through reviewed host
  APIs, with offline and permission-denied states. First-party widgets should
  exercise the same versioned contract intended for external developers.
- **Phase 2 — stable developer SDK/API.** Publish a documented Swift SDK and
  versioned widget protocol, sample widgets, a local simulator/preview, test
  fixtures, and a compatibility matrix. Keep the public surface free of
  private Mission Control or WindowServer APIs; expose declared capabilities
  rather than arbitrary access to the host.
- **Sandbox and permissions.** Run widget code/rendering behind an extension or
  helper boundary with least-privilege sandboxing. Capabilities should be
  explicit: user-selected files through security-scoped bookmarks, Photos
  access only when requested, and network access only for a provider that
  declares it. Explain, request, revoke, and surface permission failures in the
  host. The current non-sandboxed self-updating app is not this future
  extension architecture.
- **Package, distribution, and review.** Define a signed/notarized widget
  package with a manifest, stable identifier, author, API requirements,
  declared capabilities, assets, and privacy/support metadata. Decide whether
  packages arrive through a curated catalog, direct developer distribution, or
  both; apply malware, privacy, reliability, update-signing, rollback,
  uninstall, and user-visible provenance rules. No arbitrary downloaded
  executable or HTML surface is implied.
- **Compatibility and versioning.** Use stable reverse-DNS widget identifiers,
  semantic package versions, a host SDK/API version, capability negotiation,
  minimum and maximum macOS versions, migration hooks, and a safe fallback for
  an unavailable widget. Preserve persisted configuration across upgrades and
  make API-breaking changes opt-in and reviewable.
- **Opt-in network-backed image providers.** Add provider adapters only after
  the local contract is stable. A Reddit image provider is one example, not a
  bundled community feed: users would explicitly enable it, authenticate where
  needed, choose subreddit/account scope, and be able to disable it or remove
  cached data. Enforce provider terms, rate limits, attribution, content
  filtering, privacy controls, bounded caching, offline/stale behavior, and a
  clear network-disabled state. Network access is off by default for existing
  local widgets.

Relevant platform references for this deferred target are [WidgetKit](https://developer.apple.com/documentation/widgetkit),
[App extensions](https://developer.apple.com/app-extensions/), [App Sandbox](https://developer.apple.com/documentation/security/app_sandbox),
[Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution),
and the [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

These directions require separate product and architecture decisions. None is
implied by the current UI or authorized by the current implementation pass.

## Deliberately not planned

- URL scheme: Shortcuts, drag/drop, and clipboard input already cover the real
  automation paths.
- CLI: it adds installation and support complexity to a visual desktop app.
- AppleScript dictionary: App Intents cover the maintained automation surface.
- Bundled Raycast extension: that belongs in an independent integration project.
- Arbitrary Mission Control Space selection: public AppKit supports joining all
  Spaces, moving to the active Space, and fullscreen participation, but not
  enumerating or targeting private Space identifiers.

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
