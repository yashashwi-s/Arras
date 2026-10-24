# Changelog

## Unreleased

- Keep visible slideshows, GIFs and videos playing when macOS reports a
  display-sized Dock helper above them. Preserve pausing for actual app-window
  coverage and the visible Dock strip. Fixes the playback blocker reported in #6.
- Explain unreadable libraries in Settings and allow an explicitly confirmed
  backup restore, preserving the latest damaged bytes before replacement.

- Fit Appearance, Reference Tools and Photo Tools to the parent display, keeping
  footer actions visible and the existing controls scrollable on short displays.
- Add a separate sandboxed `ArrasAppStore` target alongside the free direct
  `Arras` target, sharing the widget/collage implementation and keeping build
  identities, entitlements, test hosts and output directories separate.
- Prepare backups in the background, stream exported media, and bound imported
  payloads and ZIP32 sizes. Reject unsupported sizes without trapping, and retain
  the previous destination when a file changes or export fails.
- Merge explicit existing-library import with validation and rollback,
  security-scoped media reads and native screen-region capture from the
  verified sandbox work. Store updates open the Mac App Store; telemetry,
  self-installation and direct update/migration code are excluded from that target.
- Bind build provenance to the distribution and reject cross-distribution
  packaging, Store telemetry pilots and release Debug exceptions.

- Report failed imports, saves and slideshow advances to Shortcuts rather than
  returning success. Use the shared byte importer for Add Photo.

## 2.5.0

Released 18 October 2026. Developer ID signed and notarized for Apple Silicon and Intel.

[Watch the launch film](https://tryarras.tech/puremac/arras/launch-2.5.0.mp4) · [Website](https://tryarras.tech/)

- Ignore stale macOS recorder entries after their process exits, preventing
  hide-during-recording from leaving widgets hidden. Resample on app activation.

- Start weekly configuration-report periods on Wednesday UTC; keep the initial
  first-launch report prompt and preserve persistent retry limits.

- Match the status menu's Privacy labels and help to Privacy Settings: capture
  exclusion is a compatibility request, call-app hiding also covers recording
  apps, and fullscreen detection is best effort. Keep the same controls and values.

- Group Add and Widgets first in the status menu, followed by native Undo/Redo
  icons and recovery, then Settings and Options. Keep history shortcuts and
  accessible action names, and show a member's effective collage depth in badges.

- Show the public GitHub star count beside the Preferences star link. Fetch it
  on Preferences appearance or Settings focus, share in-flight requests and
  cache results or failures for an hour without a separate launch task or polling.

- Add a Star on GitHub action beside About and in Preferences. Prepare the 2.5.0
  website with an attributed download redirect and a cached GitHub star badge;
  keep website request logs separate from app installation statistics.

- Keep Paste Appearance from cancelling another photo or collage's drag, resize
  or spacing preview, including when saving fails. Disable paste for photos in
  an unfinished affected edit and preserve unrelated native windows and motion.

- Keep nudge, align and distribute commands from discarding another collage's
  unsaved appearance edits. Wait for an affected drag, resize or preview instead
  of cancelling it, and preserve unrelated drafts when a move cannot be saved.

- Add a local Developer ID distribution step with durable Apple request IDs,
  accepted-log/hash checks, app and DMG ticket verification, and preserved original
  builds. Gate the publishing workflow on its finalized artifacts and use that
  same ZIP for the appcast checksum.

- Prepare the 2.5.0 website with editable collages, linked collections, reference
  tools, appearance copying, saved setups and recovery. Keep installation, FAQ
  and privacy wording consistent with the package's verified signing status.
  Preserve existing links and disclose limited weekly statistics in Privacy.

- Keep native media and completed resize history when saving reference notes or
  source links, or pressing Apply without changes. Text-only edits no longer
  recreate the photo window or refit its collage.

- Save reference crop/rotation geometry with its enclosing collage bounds, so
  backdrops grow and shrink with the edited photo, including hidden groups.
  Keep active moves, resizes and collage previews intact when applying reference
  edits; unrelated photos remain editable. Failed saves retain the entire scene.

- Clarify that capture exclusion is a compatibility request and that modern
  recorders may still include visible widgets. Keep the existing setting and
  visibility controls, explain manual hiding in Privacy, and remove obsolete
  claims of guaranteed recording exclusion from source documentation.

- Keep slideshow images from changing during an individual photo drag or resize,
  including standalone widgets. Next/Previous and automatic rotation respect the
  affected edit and return motion; unrelated slideshows continue normally.

- Keep linked-folder refreshes from interrupting collage edits or reverting a
  slide chosen while files are being prepared. Prepare changed files in the
  background and retain unchanged displayed media and resize history. Roll back
  folder-status changes when their save fails, preserving the managed snapshot.

- Defer a completed Photos-album refresh while its collage is being moved,
  resized or previewed. Preserve the edit and latest appearance, keep unrelated
  scenes usable, and discard pending results when cancelled or invalidated.
  Retain the displayed media and completed resize history when only album
  metadata or sibling entries change.

- Keep active photo/collage gestures and placement history intact when saving or
  switching a Saved Setup fails. Settle the old interaction only after its setup
  save or desktop replacement commits.

- Cancel deferred desktop double-click actions after a collage is hidden,
  preventing stale editor requests and window-ordering callbacks. Detach the
  closed surface's input ownership and release its material tree even when a
  caller keeps the closed panel alive.

- Restore removed widgets without rebuilding unrelated windows, playback or
  arrangement history, preserving unrelated unfinished appearance edits. Refit
  recovered collages around members edited since removal, and retain an affected
  drag, resize or appearance preview until recovery can be retried.
  Install the permission-aware Photos change observer when a saved setup or
  recovery introduces a linked Photos widget after startup.

- Preserve unrelated collage previews and gestures when removing widgets.
  Missing-widget requests and failed saves keep unfinished edits intact; removals
  affecting an active move, resize or appearance edit wait until it finishes.

- Add photos and merge backups without rebuilding the existing desktop. Preserve
  current windows, playback, source watchers, unfinished collage edits and
  arrangement undo/redo; overlapping successful imports each retain their media.
  Keep existing captions above photos when another collage is created.

- Save replacement media and fitted photo/collage geometry before updating live
  windows. Failed replacements keep the original media and playback untouched;
  hidden cropped/rotated photos retain their new placement through showing and
  Saved Setup restoration.
- Preserve unrelated dragging and resizing when a replacement finishes. Skip
  a replacement that conflicts with its photo or collage's active edit, retaining
  the gesture and undo history so it can finish normally before retrying.

- Restore the saved name and double-click action when their changes cannot be
  saved, preventing refused renames from leaking into Saved Setups and preserving
  the widget's existing double-click behavior.

- Open the existing Settings window at Updates when an update or install-failure
  notification is clicked. Check for Updates and post-update results reveal the
  same section; ordinary Settings reopening preserves the selected tab.

- Save duplicates before creating their windows or playback resources, removing
  staged media when saving fails. Hidden slideshows duplicate from their stored
  snapshots, and every per-image frame receives the duplicate's position offset.

- Save Settings-width changes and enclosing collage bounds before resizing live
  windows. Hidden photos and active slideshow frames keep their new size through
  showing and saved-setup restoration; failed saves preserve previous geometry.

- Preserve slideshow selection, history and the current image when an image
  cannot decode or saving fails. Save playback order, interval and sizing before
  changing timers or cropping.

- Keep saved and live opacity, hover reveal and collage captions unchanged when
  saving fails. Commit global Show/Hide together and return the actual visibility
  state to Shortcuts after a failed save.

- Prevent a very large custom slideshow interval from crashing native timer
  scheduling, preserving the saved value and the existing five-second minimum.
- Normalize an invalid saved slideshow position to the first image, keeping
  Settings and playback consistent without losing media or appearance settings.

- Save Depth, Space pinning and stack-order changes before applying them to
  native windows. Failed saves preserve collage/member placement and locks.

- Save Show/Hide changes before rebuilding or closing photo/collage windows.
  If saving fails, keep the previous visibility, collage bounds and captions.

- Reject damaged telemetry scheduling dates and retry counters before use,
  preventing weekly-calendar arithmetic from crashing while preserving the
  saved telemetry file and photo library.

- Capture the chosen Photos album when Sync is pressed, preserving the accepted
  value if the table selection changes before the native modal loop returns.

- Roll back empty/unavailable Photos-collection status changes when their save
  fails, reporting an empty-collection save failure instead of a successful refresh.

- Defer automatic update installation during photo/member/collage movement,
  resizing and unfinished arrangement previews; retry after they finish or cancel.

- Prefer edited Photos-library photo/video resources when available. Revalidate
  older cached representations once, retaining their safe snapshots if a new
  download fails, and reject adjustment data as a media resource.

- Suppress inferred per-window show/hide transforms on desktop photos, collage
  backdrops and labels, preserving Arras's explicit media and layout transitions.

- Recheck scheduled-notification preferences after permission handling so selecting
  Never or changing automatic-install mode suppresses an obsolete pending alert
  and prevents a new permission prompt after a delayed status lookup.
- Clear telemetry outage backoff after a successful upload, preserving the
  once-per-UTC-week limit and allowing the next week's report on schedule.

- Release a closed collage editor's hosted view and observed model, including
  when AppKit retains the closed window or controller.

- Resolve the actual Arras app delegate through its registered SwiftUI adaptor,
  restoring live-manager access for Shortcuts, Settings menu targeting and
  automatic-update deferral under SwiftUI's application-delegate wrapper.
- Route the SwiftUI Settings command and Cmd+, to Arras's existing window,
  preventing the placeholder Settings scene from opening instead.

- Observe Photos-picker selection once across the toolbar and empty state,
  avoiding duplicate import callbacks. Keep its loading indicator active until
  all selected batches finish.

- Defer automatic update installation while media imports or folder refreshes are
  preparing, including overlapping operations and Photos-picker downloads.

- Preserve a newer image replacement or slideshow selection when an older file
  replacement finishes preparing. Unrelated name and appearance edits remain intact.

- Discard unfinished imports and linked-folder refreshes when a saved setup or
  restored desktop replaces their target, even when widget IDs match. Remove
  their staged media without altering the newly restored arrangement.

- Show actual failure and skip reasons in import summaries, prioritizing failures
  and limiting details so a large batch does not create an oversized dialog.

- Cancel Photos collection imports when their progress window is closed or Cancel
  is selected, retaining the previous snapshot and discarding staged downloads.
- Respect Reduce Motion in update-status transitions and avoid claiming
  verification before the archive has been checked.

- Restore visible rounded Settings sections across Photos, Preferences and Privacy,
  with consistent surfaces and borders in light and dark mode and stronger borders
  when Increase Contrast is enabled.

- Restore 2.4.9's direct width-driven corner resizing for photos, with consistent
  proportional collage resizing, hover-only unlocked corner grips and directional
  resize cursors. Alignment guides show nearby targets without locking the resize
  scale. Drag the collage background to move the group, or drag a photo to
  rearrange or detach it. Keep collage handles above opaque backgrounds and
  photo handles inside shadow-free windows so hovered markers remain visible.
- Grow and shrink collage boundaries immediately during member resizing, and place undo/redo immediately
  left of Tools at the top of Photos.
- Remove hand cursors and avoid rebuilding photo layout and saved state on every
  group-drag event. Move caption panels by origin alone, reserving text layout
  for size or appearance changes and Space checks for panel placement. Commit
  movement at release, preserving undo and failed-save rollback.
- Move settled collage panels together through AppKit during background dragging,
  then detach them at release or cancellation so each photo remains independently
  editable. Avoid repeated native placement for an unchanged origin.
- Keep floating photos at their selected depth when Settings opens, and preserve
  editor ordering when Arras becomes active.
- Keep actual floating-window frames aligned with photo geometry at screen edges;
  independent AppKit constraints no longer separate a collage's backdrop, photos
  and caption. Group movement and live resize updates share one immediate AppKit
  transaction.
- Disable competing native window dragging on photo/collage panels and restore
  absolute scene placement so native-origin offsets cannot accumulate during dragging.
- Present collage menus at the screen pointer without a backdrop-window owner,
  preventing menu presentation from raising the backdrop over photos. Remove the
  delayed menu-tracking repair. Restore contextual placement so clicking the opening
  point dismisses the menu, and cancel unfinished dragging before menu tracking.
- Keep media playing beneath Arras's transparent caption and alignment overlays;
  their full-window rectangles no longer count as covering app content.
- Show inherited depth and Space values in collage-member rows with an Edit
  Collage action. Shared placement is edited at the collage; standalone photo
  settings survive grouping, reload and detach. Individual appearance remains editable.
  Stacking menu actions identify when they apply to the whole collage.

The following work is implemented on the development branch and has not shipped.
The next version is 2.5.0, currently in local testing. No public release date has
been assigned.

### Maintenance

- Disable test coverage instrumentation in packaged releases; coverage remains
  available explicitly for Debug test runs.

- Preserve animated WebP frame delays and repeat counts instead of defaulting
  to 100 ms frames and infinite playback.

- Avoid decoding full animations for list/menu thumbnails; bound the thumbnail cache.
- Bound clipboard animation frame recovery as well as file playback, preserving
  frame timing and restoring the caller’s bitmap cursor.
- Downsample large animations for a bounded retained playback buffer while keeping
  source files intact. Imports inspect a preview rather than decoding every frame twice.
- Stop coverage polling for static-only desktops and coalesce slideshow timer wakeups.

- Run the full updater-swap regression on macOS rather than the Linux documentation
  job, preserving portable rollback checks on both platforms.

- Moved personal telemetry-monitor tooling outside the app repository and removed
  a duplicate ownership document. Release checks and regression coverage remain.

- Removed an unused video-policy abstraction and its two self-contained tests.
  Slideshow tests now exercise the production selection function directly;
  the test-only wrapper was removed. Playback behavior is unchanged.

### Photo workflow improvements

- Refined the Photos library with consistent section spacing, compact collage
  thumbnails, shorter member labels, and a dedicated collage actions menu.

- Reference rotation and cropping now resize the canvas to the edited image,
  keeping shadows and handles on the photo instead of its old proportions.
- Removed numeric crop-focus controls; existing saved focal points remain readable.
- Smoothed the starter GIF to 25 fps, exposed menu customization in Preferences,
  and explained one-time screen capture. Collage detach actions now live in each
  photo’s actions menu instead of repeating beneath every row.

- Added named arrangement Undo/Redo to desktop-photo context menus and the Arras
  menu. Resize gestures now set the cursor immediately and retain it while dragging.

- Snapping uses a smaller capture/release distance and ignores distant targets.
  Shift-drag preserves its constrained axis, including while snapping. Removed
  the guessed desktop grid; actual screen, widget and window alignment remains.

- Privacy uses the same readable grouping as Preferences, separates permission
  shortcuts by purpose, and distinguishes capture exclusion from hiding widgets
  entirely. Capture and fullscreen limits remain visible alongside the controls.

- Preferences groups everyday behavior, alignment, desktop shortcut, updates,
  setups/backup and menu customization into readable sections. Saved Setups is
  available beside backup actions; advanced backup options and menu choices use
  full-row disclosures. Drag modifiers and update behavior are explained inline.

- The Photos album picker uses a compact dedicated window with adjacent Cancel
  and Sync Album buttons instead of an oversized alert. It searches album names, keeps a visible scrollbar,
  separates names from item counts, and omits empty system albums. Album discovery
  includes all PhotoKit album subtypes. An empty search disables syncing rather
  than retaining an invisible selection.

- Reference Tools uses a fitted image preview without a separate zoom slider.
  Crop Original, example guidance and Next steps expand from the whole header row,
  including their labels.

- Signed apps now declare the Photos Library resource entitlement required by
  Hardened Runtime. Packaging rejects bundles missing it, preventing a permissions
  failure that cannot be fixed simply by enabling the Photos toggle in Settings.

- Photos collection chooser teardown now finishes before asynchronous sync starts;
  the progress window retains ownership through close and ignores late updates.
  This targets a reported AppKit focus-chain crash; real-library retesting remains pending.

- Empty search results keep the toolbar at the top and offer Show All Widgets.
  Saved Setups uses a compact empty state and a consistent bottom Done action.
- Appearance keeps a live photo preview above separate Looks and Adjust controls.
  Six visual presets include Dark Mat and Warm Paper. Individual styling edits
  save collage bounds together and restore their previous state on save failure; preset saves retain the
  previous appearance on failure. Collage presets reset leftover border/tint
  settings while preserving text and scale. Invalid hex colors are rejected.
- Selecting Never during an in-flight scheduled check now discards its result.
  Deferred automatic installs and downloads also recheck Never before proceeding;
  Check Now and explicit manual updates remain available.
- Automatic updates defer while editors or Photos sync are active, retry deferred
  installs on the scheduled timer, tolerate backward clock changes, and ignore
  stale download-progress callbacks. Extracted updates must contain one app with
  a runnable executable, compatible minimum macOS and valid signature integrity;
  private pilots cannot replace public apps. Full public update-delivery acceptance remains pending.

- Adding a starter example now leaves a next-step guide in Settings, with a
  shortcut to find the new example and open Photo Tools. Existing search and
  visibility filters reset so a newly added example is not silently filtered out.

- Undo and redo for Align, Distribute, keyboard nudges, photo and collage
  moves/resizes, and attaching, transferring or detaching collage photos. Available
  in the photo list and through Command-Z / Shift-Command-Z outside text fields.
  History preserves unrelated later edits, checks group membership and stacking,
  and clears when switching desktops. Hidden collages stay hidden when undoing a
  detach, and detached photos resume their independent depth and Space settings.

- An always-available Tools panel opens appearance and reference editors, copies
  and pastes a photo’s look, and explains arrangement and saved setups. Selection
  actions have their own row instead of crowding the Add and Photos buttons.

- PhotoKit resource callbacks no longer inherit main-actor isolation. Cancelled
  downloads release their data and cancel the underlying Photos request;
  duplicate completion and late progress cannot revive a finished operation.

- Reference Tools in each photo’s menu: non-destructive crop, rotate, flip and
  grayscale, temporary preview zoom, notes and source links. Edits carry through
  slideshows, GIF frames, movie playback, duplicate, saved setups and `.arras`
  archives. Original managed media and widget placement stay intact.

- Recover the last removal from Settings or the menu bar, including after
  relaunch. Recovery preserves later edits and added widgets. The next removal
  replaces it; Saved Setups also offers an explicit discard command.
- Consistent native dialogs for imports, exports, removal, collage edits and
  installation; destructive actions are explicit and cancel remains available.
  Photos and screen-capture permission recovery target their respective panes
  in System Settings, with written directions and fallback navigation.
- Named Saved Setups with thumbnails, rename, duplicate and switch commands,
  plus Restore Previous Desktop. Shared photos and fonts stay protected while
  saved setups reference them; global preferences are unaffected.

- Search photos and collages by name; filter visible, hidden, slideshow, collage
  and linked-source widgets. Matching children remain reachable inside groups.
- Photo rows explain manual, parent, display and privacy hiding.
- Slideshow editing is reachable for photos inside collages.
- Archived obsolete local builds, source snapshots and handoff notes outside the
  checkout; retained the latest verified pilot and active build/monitor tools.

- Copy Appearance and Paste Appearance are available in each photo’s action
  menu, including hidden and locked photos. Batch paste preserves each photo’s
  content, position, visibility and focal point, and refits affected collages.

### Collage visibility fixes (8 October 2026)

- Manually hidden collage photos no longer influence drop zones, snapping,
  background bounds or spacing previews. Showing them restores their saved
  position and expands the collage to fit.
- Rename the privacy option to “Hide them completely during calls”.

### Audit fixes (8 October 2026)

- Prevent background Photos refreshes from prompting for permission; coalesce
  library-change notifications during downloads into one subsequent refresh.
  Photos collection actions are restored; native permission and iCloud integration
  verification remains a release gate.
- Album downloads preserve edits made while syncing, resolve widgets by ID after
  list changes, and discard results from a previous desktop setup. Refreshing an
  album cannot reveal a widget hidden by privacy or display rules.
- Preserve the known-good updater backup when rollback cannot restore it.
- Isolate development and dry-run telemetry from production identity and state;
  freeze attempted event contents across edits, retries and relaunches.
- Show current desktop-notification permission in the telemetry dashboard and
  retain undelivered incidents while permission is denied.
- Reconcile display visibility at launch, recover geometry after resolution or
  arrangement changes, and use collage depth for child double-click actions.
- Add explicit unused-font cleanup that protects saved layouts, open drafts and
  the current font selection. Font imports remain reusable library assets even
  when an editor is canceled.
- Separate compatible Photos models from acquisition, remove unused
  action aliases and stale comments, share collage transition code, and verify
  the complete generated application source membership before building.

### Added

- Slideshow editing: add, reorder and remove local images; ordered, random,
  newest-first and no-repeat playback with saved state.
- Desktop collages that group existing widgets without cropping their photos,
  with drag-in/out membership, proportional group resize, spacing and depth.
  Includes System Glass, White Polaroid, Gallery, Ink and Transparent looks; captions, labels,
  installed/imported fonts, desktop preview and Apply/Discard/Keep Editing.
- Optional outside borders scale with the whole collage; Transparent groups have
  no backdrop or shadow. Outer margin and advanced collage settings sit together
  above the Labels section.
- Guided starter examples show previews, feature summaries and instructions,
  with real glass and transparent photo/label groups and an optional feature guide.
  Contact & Support uses yashashwi.singhania.bce23@itbhu.ac.in. Legacy
  Bubble/Polaroid containers, editor and gestures are removed. Older layouts
  keep their child photos as standalone widgets.
- Linked Finder-folder slideshows with watching, refresh/relink and bounded
  managed snapshots; muted video import/playback with managed posters.
- Multi-selection, align/distribute, keyboard nudge, focal points, style copy/paste
  and configurable double-click actions (advance, Quick Look, reveal or copy path).
- Finder-open archives, selective import, per-widget export, media integrity and
  fidelity reporting, and atomic selected-widget removal with shared confirmations.
- Shared occlusion, battery, thermal, Reduce Motion and sleep/wake playback policy.
- A first-party telemetry client and deployed, validated website API with a random
  install ID, six typed events, one weekly bucketed snapshot in public 2.5.0, bounded offline queue,
  deduplication, rate limits and kill switches. Production sending is enabled for the 2.5.0 release candidate and private pilots;
  the currently published 2.4.9 download is unchanged.
- A combined GitHub/app overview, daily and weekly view in `bss.sh`, with
  aggregate-only Keychain access, persistent health checks, native failure/recovery
  notification scheduling and an independent collector heartbeat guard. Public 2.5.0 uses weekly reporting; older private pilot builds may remain daily.

### Changed and fixed

- Removed Combine Photos completely: menus, editor, creation, combined-image
  renderer and layout engine. Existing saved records/imports preserve their images
  as ordinary slideshows through a decode-only migration. Create Collage remains
  the sole collage creation workflow.

- Settings uses one ordinary managed primary window while Arras stays menu-bar
  only. Floating widgets yield while it is active and restore their depth when
  Settings closes, minimizes or the app resigns activation.
- Collage resize uniformly scales photos, frames, labels and spacing.
  Grouping, display restoration, membership edits and failed-save rollback
  preserve geometry together; duplicate widget IDs fail safely.
- Desktop panels release decoded media when retained panels close.
- Frame presets now read Plain, Soft Shadow, Print and Thin Frame while preserving
  their saved identifiers. Settings keeps selection controls stable and separates
  frame detail from common actions.
- Widget export includes only the selected widgets’ font files; failed imports
  roll back new font registration. Selected collage movement respects group locks
  and carries children and all per-image slideshow positions together.
- Builds embed verified source provenance; copied/stale sources and pilot/public
  packaging mixups are rejected. Installers are checked against the exact app.
  Private pilots show their build number and block public update checks/installs.
- Update-check failure throttling persists across relaunches; timer scheduling
  uses tolerance while retaining the selected check frequency.

- Test suites now follow subsystem ownership. Duplicate compatibility/cadence
  checks, external developer-fixture and bitmap-only smoke checks are removed;
  archive, migration, rollback and telemetry regressions stay covered. Unused
  import/callback helpers and source aliases are removed. Build/test instructions
  and current verification are consolidated.

### Release gates

Public-release telemetry remains disabled; infrastructure and disclosures are
live for the separately shared private test build.
Photos collection sync and Live Photo acquisition are restored on this branch.
Permission grants, denial recovery and real iCloud downloads still require native
release verification; deterministic policy tests do not establish those outcomes.
Per-photo visibility schedules remain removed. Native appearance, Stage Manager,
displays and sustained resource use still need the release checks in
[CONTRIBUTING.md](CONTRIBUTING.md#release-verification).

## 2.4.9 — Reliable update checks and a clearer menu

**Update checks follow the selected schedule.** Hourly and other chosen check
intervals now apply when verified automatic installation is enabled too. Arras
checks again after the Mac wakes, retries a failed check without excessive
requests, and refreshes the last checked time while Settings stays open.

**The menu bar is easier to scan.** Add commands now live under Add, individual
widgets and removal live under Widgets, and app controls live under Options.
This release contains the menu organization for the existing features.

## 2.4.8 — Transparent PNGs and hover reveal

**Transparent images stay transparent.** Large PNGs keep their alpha when Arras
downsamples them, and replacing an image no longer flattens transparent stills
to JPEG.

**Widgets can reveal on hover.** Each widget can stay visually hidden until the
pointer moves over it, then fade to its configured opacity without changing the
saved opacity. Behind Icons keeps the widget visible because macOS does not
deliver pointer events at that depth.

## 2.4.7 — New Arras icon

**Arras has a new app icon.** The cream, charcoal, and terracotta design brings
the Arras mark to Finder, the Dock, and system surfaces without changing app
behavior.

## 2.4.6 — Updates and durable backups

**Verified automatic updates now default to daily.** Arras checks once a day,
installs only after the existing HTTPS, checksum, archive, bundle-identity and
version checks pass, and keeps the previous app until the replacement confirms
that it launched. Turning automatic installation off keeps a configurable
background check and sends one useful release notification for each new version.

**Portable backups are safe to replace with.** Portable Backup exports widgets
and their stored images to one `.arras` file for restoration or transfer to
another Mac. Writes remain atomic, and archive replacement validates every
staged image before changing the live model, so damaged input cannot erase a
working layout.

**Space replacement and accessibility are durable.** Replacing the current image
in a Space updates the persisted slot, carries its frame metadata forward, and
survives hiding and relaunching the widget. Settings controls expose labels,
hints, and values for assistive technologies, including the keyboard-reachable
Advanced Frame disclosure.

**Release copy is now a required artifact.** CI rejects missing or placeholder
human-authored notes. The validated title and summary become both the GitHub
release body and updater message, while the release runner stamps the checksum
from the exact uploaded archive.

## 2.4.5 — UI changes

**The intended glass Settings UI now ships consistently.** Local builds, CI and
release builds all link against the macOS 27 SDK, which is what gives the native
SwiftUI tab strip its rounded translucent presentation. The Arras gradient
wordmark remains in the title bar.

**Settings follows you to the current desktop Space.** The duplicate SwiftUI
Settings scene is gone; the menu and app commands now target one AppKit-managed
window that moves to the active Space instead of switching you back to wherever
it was last opened.

**Regression coverage.** Unit tests cover layout restoration, version comparison
and model compatibility. Integration tests cover persistence and
backup round-trips, and a UI test opens the real app, visits every Settings tab
exercises the Frame inspector and confirms there is only one window.

**Safer destructive operations.** Remove All asks for confirmation. A damaged
replacement backup is fully checked before the current layout is removed, so a
missing image or failed write cannot wipe a working setup.

## 2.4.4

**The tab bar has its glass back, and the wordmark stayed.** Putting the Arras
wordmark in the title bar as an `NSTitlebarAccessoryViewController` made AppKit
render the whole title bar differently: the tab control lost its translucency and
rounded pill and came out flat and squared off. The wordmark is now a plain
subview of the title bar instead of an accessory, which leaves that layout alone.
Same gradient mark in the same position, level with the tabs, and the pill is
native again.

## 2.4.3

**Widgets are named after the file they came from.** A photo added as
`Beach House 2019.png` shows up as "Beach House 2019" instead of "Photo 4".
Stored files are still named by UUID; the original is captured at import.
Photos-library picks have no filename to take, so those still fall back.

**Renaming happens in the row.** Click Rename and the name becomes an editable
field where it already sits. Return commits, Escape cancels, clicking away
commits. The modal alert is gone, and so is the second one behind the menu bar's
Rename, which now just opens Settings.

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
