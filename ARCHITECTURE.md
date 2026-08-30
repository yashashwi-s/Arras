# Arras architecture contract

Status: active for version 2.4.6. Arras is a
Swift/AppKit menu bar agent with a SwiftUI Settings surface. AppKit owns desktop
and Settings windows; SwiftUI edits observable state and never becomes a second
window authority.

## Dependency direction

`input → normalized stored media + PhotoItem → PhotoManager → AppKit windows → Core Animation`

Settings and menu commands call `PhotoManager`. They do not write `photos.json`,
manage media files, or construct desktop windows independently.

## Current owners

- `PhotoWidgetOSXApp.swift`: process entry point and empty SwiftUI scene required
  by the app protocol.
- `AppDelegate.swift`: status item, application menu, one Settings window, import
  panels, and command routing.
- `PhotoItem.swift`: persisted per-widget schema and backward-compatible decode
  defaults.
- `ImageManager.swift`: `PhotoManager`, the authoritative widget collection,
  persistence, desktop-window registry, visibility, rotation, and display state.
- `DesktopPhotoWindow.swift`: non-activating desktop window and interactive
  `DraggablePhotoView` canvas.
- `FrameStyle.swift` and `PhotoAppearanceControls.swift`: appearance types and
  manager-owned mutations.
- `PhotoIngest.swift`, `PhotoImport.swift`, `AnimatedImage.swift`, `PDFImport.swift`,
  and `ScreenshotCapture.swift`: content normalization and import boundaries.
- `SnapEngine.swift`, `SnapGuideOverlay.swift`, and `DisplayManager.swift`:
  placement geometry, visual guides, and stable display identity.
- `PresenceManager.swift`: schedule evaluation, fullscreen state, and
  conferencing-process observation.
- `LayoutArchive.swift` and `BackupFormat.swift`: portable archive schema,
  minimal ZIP implementation, import staging, and optional preferences.
- `MainWindowView.swift`, `ContentView.swift`, `PhotoRowView.swift`,
  `FrameInspector.swift`, `PersistenceStatusView.swift`, `PreferencesView.swift`,
  and `PrivacyView.swift`: view-only Settings composition and recovery status.
- `HotKeyManager.swift`, `ArrasIntents.swift`, and `MenuBarCustomization.swift`:
  external commands and user-configurable control surfaces.
- `Tests/Unit` and `Tests/UI`: pure/model coverage, isolated persistence
  integration, compatibility, and launched-app navigation.

## Persistence contract

- Production storage is `~/Library/Application Support/PhotoWidget/`.
- `photos.json` is an array of `PhotoItem` written atomically.
- A changed write first saves the valid predecessor under `photos-revisions/`;
  the bounded trail is a required part of the commit, not best-effort logging.
- Existing state that cannot be read or decoded is preserved under
  `photos-corrupt/` and blocks ordinary writes until explicit recovery.
- Media cleanup considers the live model, durable current JSON, and every valid
  retained revision. An unreadable state conservatively blocks cleanup.
- Every field added after the original model must decode with
  `decodeIfPresent(...) ?? default`; a missing new field may never invalidate an
  older library.
- Stored media filenames are generated identifiers. A Space owns an ordered list
  plus per-image frame configuration keyed by stored filename.
- Window geometry always persists the visible photo frame, not the larger
  shadow/tilt window frame.
- Display identifiers and frames describe local hardware. They persist locally
  but never travel through a portable archive.
- `StorageMigration` runs before production state is read and never overwrites a
  destination that already contains a layout.
- Tests construct `PhotoManager(storageDirectory:)` or set
  `ARRAS_UI_TEST_STORAGE_DIR`; they never touch production storage.

## Window and Space contract

- Each widget has one `DesktopPhotoWindow`, keyed by `PhotoItem.id` in
  `PhotoManager.windows`.
- Desktop windows are non-activating, are not released on close, and derive
  level from `WidgetDepth`.
- A behind-icons widget is locked because Finder's desktop window makes it
  unreachable by pointer input.
- Space binding changes collection behavior for that widget. Unbound widgets
  join all Spaces.
- The Settings window has one owner: `AppDelegate`. It uses
  `.moveToActiveSpace`, disallows tabbing, retains its AppKit wordmark, and is
  reused rather than recreated by a SwiftUI Settings scene.
- Window order inside a depth is persisted separately from window level so
  repeated bring-forward/send-back operations can cross the full desktop stack.

## Rendering and performance contract

- `PhotoContent` distinguishes still and animated media before window creation.
- GIF/APNG playback uses `CAKeyframeAnimation`; no display link or frame timer
  wakes the process continuously.
- Shape, mask, mat, border, shadow, and vignette use the same authoritative path
  and frame geometry.
- Tilt expands the host window around the visible photo frame; saved geometry
  must not include that expansion.
- Snapping operates on visible photo edges, not shadow margins.
- Alignment guides are temporary Core Animation layers and never enter model
  state.
- Hidden/fullscreen-suppressed widgets tear down windows and rotation timers;
  manual show can restore them through the common content loader.

## Import and archive contract

- Multi-image ingest prepares file bytes concurrently before committing model
  and window changes on the main actor. Archive import validates and stages every
  payload, then commits merge or replacement in one durable model write before
  rebuilding windows or cleaning old media.
- A portable archive contains a versioned manifest plus referenced stored media.
- Imported items receive new IDs and filenames to prevent collisions.
- Relative frames are preferred when restoring onto different displays;
  legacy absolute frames are clamped back onto a visible screen.
- Replace import validates actual media decodability before committing. Empty,
  damaged, or unsavable input cannot erase or partially replace working state.
- Optional imported preferences are applied only after explicit user choice and
  remain separate from widget import.

## UI boundary

- SwiftUI reads `PhotoManager` through observation and calls manager methods for
  mutations.
- Common photo controls stay in the row; detailed drawing controls live in the
  Frame inspector.
- Global behavior belongs in Preferences. Capture/fullscreen presence controls
  belong in Privacy.
- The menu is rebuilt lazily through `NSMenuDelegate` so labels, thumbnails, and
  state reflect the authoritative model at open time.
- Icon-only controls require explicit accessibility labels and hints.

## Verification layers

1. Model: legacy/current `PhotoItem` decoding and round-trip behavior.
2. Pure behavior: schedules and relative layouts.
3. Persistence integration: isolated save/reload, bounded recovery, media
   retention, and transactional archive merge/replace.
4. Window contract: Settings collection behavior without user data.
5. UI integration: launch isolated Arras, assert one Settings window, visit all
   tabs, and exercise schedule, Frame, and destructive confirmation controls.
6. Release: generate the project, run tests, build with the macOS 27 SDK, and
   inspect the produced app version/build.
7. Manual: launch the actual Release artifact and verify native appearance,
   desktop Space behavior, and representative widget interaction.

Automated success does not claim final visual approval or multi-display/Space
behavior that requires a real desktop session.

## Release and update contract

- Every public version has one deliberately human-authored metadata file at
  `release-notes/<version>.json`. It must contain the matching `version`, a
  meaningful one-line `title`, and a non-placeholder `summary`; optional
  `details` entries provide the longer release-page copy.
- Pull-request CI validates the current `MARKETING_VERSION` and every release
  metadata file. The tag workflow validates the exact `v<version>` being
  published before it runs tests or creates artifacts, so missing, mismatched,
  malformed, or placeholder copy cannot become a public release.
- The release workflow uses the validated metadata as the actual GitHub release
  body (title, summary, and optional details), builds and uploads the artifacts,
  then stamps `appcast.json` with the runner-produced checksum and the validated
  `title: summary` string. GitHub's generated release notes are disabled so the
  public release body and updater copy cannot silently diverge.
- The existing updater reads `appcast.json`'s `releaseNotes` field for its in-app
  update state and macOS notification body.
- Automatic installation is a persisted, default-on preference with a daily
  check cadence. If it is off, the separately persisted background-check
  cadence defaults to daily; finding a new version posts one notification per
  accepted version. Notification authorization is requested only when a banner
  is actually needed.
- Automatic and manual installation share the HTTPS, checksum, archive,
  bundle-identity, advertised-version, quarantine, and rollback path. Revoking
  automatic-install consent during a download prevents the staged app from
  being installed.
- `appcast.json` is a generated public feed. Do not calculate or edit its
  artifact checksum locally; the release workflow owns the URL, hash, current
  version, and updater-facing notes after the published artifact exists.

## Change rules

- Add persisted fields only with backward-compatible defaults and compatibility
  tests.
- Add a second state writer only by changing this contract first; duplicated
  persistence or window ownership is a defect.
- Keep rendering work off continuous app-side loops.
- Add abstractions only for a present second use or a real dependency violation.
- Update README, FEATURES, and this file when ownership or product truth changes.
