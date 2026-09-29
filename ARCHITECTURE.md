# Arras architecture contract

Arras is a Swift/AppKit menu bar agent with a SwiftUI Settings surface. This is
a durable ownership contract rather than a release inventory. User-reachable
behavior is documented in [FEATURES.md](FEATURES.md).

## Dependency and ownership

`input → normalized stored media + PhotoItem → PhotoManager → AppKit windows → Core Animation`

- `PhotoWidgetOSXApp.swift` starts the process; `AppDelegate` owns the status
  item, menus, import panels, and the single Settings window.
- `PhotoItem` is the backward-compatible persisted widget schema.
  `PhotoManager` owns the widget collection, persistence, media references,
  window registry, visibility, rotation, display state, and mutations.
- `DesktopPhotoWindow` is the non-activating desktop panel and
  `DraggablePhotoView` is its interactive canvas. SwiftUI never becomes a
  second window owner.
- `FrameStyle` defines appearance values; `PhotoAppearanceControls` applies
  manager-owned appearance changes.
- `PhotoIngest`, `PhotoImport`, `AnimatedImage`, `PDFImport`, and
  `ScreenshotCapture` normalize content at import boundaries.
- `SnapEngine`, `SnapGuideOverlay`, and `DisplayManager` own placement
  geometry, guides, and stable display identity. `PresenceManager` observes
  fullscreen and selected running processes.
- `LayoutArchive` and `BackupFormat` own the versioned portable bundle and
  its minimal ZIP implementation.
- `MainWindowView`, `ContentView`, `PhotoRowView`, `FrameInspector`,
  `PreferencesView`, and `PrivacyView` compose Settings. They read observed
  state and call manager methods; they do not write storage or create windows.
- `HotKeyManager`, `ArrasIntents`, and `MenuBarCustomization` are the
  external-command and configurable-menu boundaries.

## Persistence and storage

Production data lives in `~/Library/Application Support/PhotoWidget/`.
`StorageMigration` runs before state is read and does not overwrite an existing
destination layout. The historic path and bundle identifier are compatibility
contracts even though the product name changed.

`photos.json` is an array of `PhotoItem` written atomically. Every field added
after the original schema must decode through an explicit default. A decoding
failure preserves a bounded copy of the damaged store and blocks a subsequent
save from overwriting the unread data.

Stored media uses generated filenames. A Space owns an ordered filename list
plus per-image geometry keyed by filename. Shared-media deletion checks the
primary image and every Space slot before removing a file.

Window geometry always records the visible photo frame, excluding expanded
shadow and tilt margins. Display frames and identifiers persist locally but do
not travel in a portable archive. Tests must inject `storageDirectory:` or use
`ARRAS_UI_TEST_STORAGE_DIR`; they must never open production storage.

## Media pipeline

`PhotoIngest` prepares bytes concurrently away from the main actor, then
`PhotoManager` adopts a completed batch and persists once. Still sources at or
below the 2560-pixel longest-edge limit pass through as JPEG, PNG, HEIC, TIFF, or
GIF when supported. Larger stills are downsampled through Image I/O. Alpha
determines PNG output; opaque output becomes JPEG. Animated sources retain their
bytes after animation decoding succeeds.

`PhotoContent.load` decides still versus animated content before window
creation. GIF/APNG playback uses `CAKeyframeAnimation` on the render server,
not an app-side display link or frame timer. Photos, Finder, pasteboard,
status-item drop, PDF, and screen capture all converge on manager-owned import.

The image-object import path encodes transparent stills as PNG and opaque
stills as JPEG; it does not use file passthrough. The updater selects the first
top-level `.app` after extraction and checks its bundle identity and version;
it does not enforce an exactly-one-app archive contract.

Archive import validates and stages every referenced payload before committing
merge or replacement. Replacement persists the new model once before rebuilding
runtime windows or removing old media. Imported items receive new identifiers
and filenames. Relative frames restore onto new displays; legacy absolute frames
are clamped to a visible screen. Optional preference groups apply only after the
user chooses them.

## Windows, rendering, and interaction

Each visible widget has one `DesktopPhotoWindow`, keyed by `PhotoItem.id`.
Panels are non-activating, stay retained when hidden, derive their level from
`WidgetDepth`, and use persisted stack order within a depth. Behind-icons
windows are locked because Finder prevents pointer interaction there.

Unbound widgets use `.canJoinAllSpaces`; bound widgets use
`.moveToActiveSpace` and remain on their current Space. AppKit has no supported
stable numbered-Space API. Settings is one reusable AppKit window with
`.moveToActiveSpace` and tabbing disabled.

Mask, mat, border, gradient, shadow, edge fade, image, and vignette use common
frame geometry. Tilt expands the hosting window around the authoritative visible
frame. Snapping and saved geometry operate on visible photo edges. Alignment
guides are temporary Core Animation layers and never enter the model.

Reveal on hover derives effective window alpha from saved opacity, hover state,
and whether the depth is interactive; it does not rewrite saved opacity. Reduce
Motion bypasses relevant transitions. Hidden, display-disconnected, or
fullscreen-suppressed widgets tear down windows and Space timers; restoration
uses the same content loader as launch.

## UI and menu boundaries

The status menu is rebuilt lazily from current model state. Its stable hierarchy
is Add, Settings, optional global visibility, Widgets, Options, and Quit.
Per-widget submenus are generated from the authoritative item. Thumbnails use an
`NSTextAttachment` in `attributedTitle` because `NSMenuItem.image` does not
render reliably with the current macOS 27 SDK; the plain title remains for
accessibility and menu search.

Common widget controls stay in a Settings row, drawing controls live in the
Frame inspector, global behavior and backup live in Preferences, and
capture/presence behavior lives in Privacy. Icon-only controls require explicit
accessibility labels and hints.

## Presence and permission boundaries

Screen-capture exclusion sets the AppKit window sharing policy; its effectiveness
depends on the macOS capture path and does not cover physical display mirroring.
Conferencing detection observes launches and terminations for a fixed bundle-ID
set and cannot infer whether sharing is active. Fullscreen observation follows
workspace/Space changes. These are separate from user visibility.

The global shortcut uses a Carbon hotkey and does not require Accessibility.
Photos access is mediated by `PhotosPicker`. Region capture invokes the system
`screencapture` tool. The app is deliberately not sandboxed because replacing
the running app and starting the swap helper are required for self-update.

## Updater lifecycle

`Updater` fetches one public JSON feed from
`raw.githubusercontent.com/yashashwi-s/Arras/main/appcast.json`. The selected
frequency is the single cadence for automatic installation and
notification-only checks. Automatic installation defaults on, Daily is the
default cadence, and Never disables scheduled checks.

A one-minute timer compares elapsed wall-clock time with the last successful
check. Wake and app-activation observers call the same due check, covering
missed timer fires. Failed scheduled attempts leave the successful timestamp
unchanged and are throttled for 15 minutes. A persisted successful timestamp is
rendered through a periodic Settings timeline so its relative label stays live.
Manual checks bypass the schedule but share the same in-flight phase guard.

The feed request bypasses caches and uses a five-second timeout. A candidate
must have a valid SemVer version, meet its minimum OS, be newer than the current
version, and provide an HTTPS ZIP and SHA-256. Downloads append a fresh
`request` UUID query value for request-level measurement; it is not a stored
device identifier.

The archive hash, presence of a top-level app, bundle identifier, advertised version, and
rollback direction are verified before installation. A helper swaps the app,
relaunches it, and retains the previous bundle until the new process writes a
unique health marker. Timeout restores the previous copy. Revoking automatic
update consent during download stops installation after transfer. Notifications
are deduplicated by update version, failure version, or announcement ID and
authorization is requested only when delivery is needed.

## Release and product truth

`project.yml` owns build settings and `Arras.xcodeproj` is generated.
`release-notes/<version>.json` owns the human-authored title, summary, and
details for a version. Release validation requires matching, non-placeholder
metadata before tests and packaging.

The tag workflow builds release artifacts, publishes the same reviewed notes,
then writes the runner-produced ZIP URL and SHA-256 into `appcast.json`.
Locally computed hashes must never be put in the feed because published
artifacts are rebuilt by the release runner.

`product-metadata.json` owns stable machine-readable public facts.
Release-specific version, date, artifacts, and digests come from GitHub Releases
and the appcast. `FEATURES.md` owns the reviewed current shipped behavior,
while CHANGELOG and release notes remain historical records. Website consumers
should link to or validate against these owners instead of maintaining prose
copies.

## Verification and change rules

Verification layers are: model compatibility; pure layout/update behavior;
isolated persistence and archive transactions; media ingest; window contracts;
launched-app Settings UI; Release build and artifact inspection; and manual
visual, multi-display, Space, capture, and update testing.

- Add persisted fields only with backward-compatible defaults and compatibility
  tests.
- Add a second state writer or window owner only by changing this contract first.
- Keep idle rendering work event-, timer-, or render-server-driven.
- Generate the Xcode project; never hand-edit it.
- When user-visible behavior changes, the same pull request must update the
  relevant product documentation or explicitly demonstrate why no documentation
  change is required.
