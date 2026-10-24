# Arras architecture contract

Arras is a Swift/AppKit menu bar app with SwiftUI Settings. AppKit owns windows;
SwiftUI reads observable state and calls manager methods. Published behavior is
in [FEATURES.md](FEATURES.md); development changes are in
[CHANGELOG.md → Unreleased](CHANGELOG.md#unreleased).

`input/live source → managed media + PhotoItem → PhotoManager → AppKit windows → Core Animation/AVFoundation`

## Subsystem ownership

Source files below live in `Sources/App/`.

| Area | Owners and responsibility |
| --- | --- |
| Application | `PhotoWidgetOSXApp.swift` is the entry point. `AppDelegate.swift` owns the status menu, application commands, import panels and one Settings window. |
| Model and storage | `PhotoItem.swift` owns compatible decoding. `ImageManager.swift` owns `PhotoManager`, persistence, windows, visibility, rotation and display state. |
| Desktop rendering | `DesktopPhotoWindow.swift` owns photo panels, dragging, media layers and collage rendering. `FrameStyle.swift` and `PhotoAppearanceControls.swift` own frame types and manager mutations. |
| Starter examples | `StarterExamples.swift` uses bundled example photos and a generated animation through the ordinary local model and window paths after a durable save. |
| Import | `PhotoIngest.swift`, `PhotoImport.swift`, `PhotoImportPolicy.swift`, `ImportBatchResult.swift`, `AnimatedImage.swift`, `PDFImport.swift` and `ScreenshotCapture.swift` validate and normalize input. `MediaModel.swift` and `VideoMedia.swift` own rich-media representation. |
| Slideshows | `SpacePlayback.swift`, `SlideshowEditing.swift` and `SlideshowEditor.swift` own playback state and durable local membership editing. |
| Desktop collages | `DesktopCollage.swift`, `CollageManagement.swift`, `CollageDesktopWindow.swift` and `CollageResize.swift` own grouped photo windows, membership, geometry and scale. `CollageSettingsView.swift` and `CollageAppearancePreview.swift` own drafts and Apply/Discard. `CollageLabels.swift`, `CollageLabelWindow.swift`, `CollageLabelControls.swift`, `CollageLabelWizard.swift` and `CollageFontLibrary.swift` own text, placement and local fonts. |
| Linked sources | `LiveFolderSpace.swift` and `PhotosLibraryCollection.swift` reconcile bounded managed snapshots. `PhotosLibraryModels.swift` retains compatible metadata and snapshot policy independently of PhotoKit acquisition and observers. |
| Placement and runtime | `WidgetSelection.swift`, `WidgetInteraction.swift`, `SnapEngine.swift`, `SnapGuideOverlay.swift` and `DisplayManager.swift` own selection, layout and display placement. `RuntimeActivity.swift`, `WindowCoverage.swift` and `PresenceManager.swift` own energy, occlusion and presence policy. |
| Archives and removal | `LayoutArchive.swift`, `LayoutArchiveImportFlow.swift`, `ArchiveMedia.swift`, `ArchiveZip.swift` and `BackupFormat.swift` own manifests, integrity, staging and portable import/export. `RemovalConfirmation.swift` owns removal confirmation. |
| Settings and commands | `MainWindowView.swift`, `ContentView.swift`, `PhotoRowView.swift`, `PhotoToolsView.swift`, `FrameInspector.swift`, `PreferencesView.swift` and `PrivacyView.swift` compose views. `HotKeyManager.swift`, `ArrasIntents.swift` and `MenuBarCustomization.swift` expose external commands. |
| Updates | `Updater.swift` owns checks, notifications, download validation, installation and rollback. `UpdateStatusView.swift` presents live status. |
| Telemetry | `TelemetryRuntime.swift` copies only broad type counts after durable saves. `Telemetry.swift` owns actor-isolated identity, queue and transport. The API/storage live in the website repository; [the telemetry reference](SECURITY.md#telemetry-protocol-and-activation) owns their protocol. |

## Onboarding ownership

`OnboardingProgress` owns an installation-local completion choice in UserDefaults.
`AppDelegate` decides initial presentation after normal startup and owns one
`OnboardingController`. A populated or damaged library bypasses the automatic tour;
update-result and archive-import flows keep priority. Closing, skipping or finishing
marks the tour complete, then reuses the existing Settings window. Explicit replay
never resets that choice. UI tests inject their own suite through isolated storage.

`OnboardingView` previews bundled sample assets without touching PhotoManager,
requesting permissions or starting network work. Only its explicit sample action
uses the existing transactional starter path, and failure keeps the tour open.
`SupportArrasView` and its destination compile only in the direct target. No
purchase state, tracking, nag scheduling or feature restrictions are introduced.

## Persistence and compatibility

- Production storage remains `~/Library/Application Support/PhotoWidget/` with
  bundle identifier `com.yashashwi.tableau`; renaming the app must not move either.
- `photos.json` is an atomic array of `PhotoItem`. New fields require explicit
  backwards-compatible defaults. Duplicate IDs and corrupt existing data are
  rejected before building dictionaries; failed saves preserve the last valid store.
  An unreadable store publishes a recovery state to Settings. Only explicitly
  confirmed backup recovery may replace it, after preserving its current bytes;
  failed preservation or saving retains the blocked state. A store repaired by
  another writer during recovery is not overwritten.
  Names and double-click actions roll back their model change on failure so later
  setup snapshots and live action dispatch retain the saved behavior.
- Opacity and hover-reveal changes save before altering native appearance or
  caption alpha. Scroll requests use the same manager path as Settings.
  Global Show/Hide commits all affected visibility and fitted
  bounds together, restoring the model on failure and returning actual visibility.
  Parent/member restoration reuses panels already created by collage sync.
- Persist the visible photo frame, excluding shadow/tilt-expanded window geometry.
  Local display bindings stay local; portable archives use relative geometry.
  Settings-width changes calculate the destination first and commit photo,
  active slideshow-frame and collage bounds together. Hidden photos resize their
  stored aspect ratio while preserving their display binding and other display
  profiles. Native window updates follow the successful save.
- Stored filenames are generated identifiers. Slideshows persist ordered files
  and per-image frames; movies own managed video/poster files. Paired Live Photo
  rendering uses PhotoKit collection acquisition with a managed local snapshot.
  Duplication decodes and saves the candidate before creating windows, playback
  caches, timers or source watchers. Failed saves roll back the model and remove
  only newly copied files. Slideshow duplicates share their managed snapshot,
  derive URLs from saved filenames and offset every saved per-image frame.
  Media replacement stages identity, active slideshow-frame metadata, display
  geometry and enclosing bounds in one save before native media/cache changes.
  Failed writes restore the complete model without replacing the decoder/player.
  The manager and window share swap-frame calculation; reference crop/rotation
  contributes to the saved aspect ratio. The committing manager fits the parent
  explicitly, suppressing the swap callback's redundant post-render save.
  Replacement never globally cancels arrangement state. Its conflict check covers
  the affected scene's drags/drop targets, group snapshots, return motion and
  appearance drafts. Conflicting prepared media is discarded with a retry reason;
  unrelated scenes keep their gesture and undo lifecycle.
  Reference image edits use the same affected-scene conflict guard. Their crop/rotation,
  active display/slide placement and enclosing bounds commit together before
  recreating an existing native window; a failed save restores all model changes.
  Hidden photos retain their display binding and other display profiles. Native
  collage synchronization is scoped to the affected parent.
  Notes/source-only changes persist without decoding media or replacing native
  content; unchanged Apply returns without saving. They do not refit geometry or
  invalidate placement history.
  Selection nudge/alignment/distribution uses the same affected-scene guard before
  changing geometry. It never globally cancels drafts or gestures, and synchronizes
  only the selected collages after success or rollback.
  Appearance paste uses that guard for its target photos and parents. Row menus,
  selection actions and Photo Tools share the same eligibility check. A refused
  or failed paste leaves interactions intact; successful paste updates only its
  affected collages, including hidden or position-locked targets.
- Linked sources render managed copies rather than depending on original paths.
  Portable archives strip bookmarks, source paths and Photos identifiers, leaving
  snapshots that require relinking. Generic editing must not change source-owned
  membership, including after asynchronous preparation.
- Additive imports save the combined model once, then activate only the new IDs
  through the same display, presence, collage and media rules as a full load.
  Existing windows, captions, playback caches/timers, source observers/watchers,
  appearance drafts and arrangement history retain their ownership. New photo
  panels enter the saved stack on the active Space without raising old panels
  onto it. Only a full desktop load/replacement resets the desktop generation,
  cancels prior imports and tears down runtime state.
  Creating another backdrop restores foreground caption ordering at its depth
  without refreshing other collages' appearance drafts.
- Desktop collages use media-free parents (`desktopCollage`) and ordinary photo
  children (`collageParentID`). They cannot nest. Manually hidden children retain
  membership and saved geometry but do not contribute to fitting, snapping or
  spacing. Temporary presence/display hiding preserves layout. Membership, proportional resize,
  bulk movement and display restoration preserve one scene; failed saves restore
  models and windows. Archives remap parent IDs; a child imported alone detaches.
  Only referenced fonts from exported widgets enter an archive. Import stages
  fonts before commit and unregisters newly registered fonts on rollback.
  Font-picker imports are permanent reusable library assets. Explicit unused-font
  removal protects saved collages, all open appearance drafts and the current selection.
- Background group dragging translates existing windows without rebuilding their
  local layout or publishing photo-model mutations per event. Release commits the
  accumulated translation once, including slideshow destinations and saved frames;
  failed saves and cancellation restore the original scene. Pointer positions are
  read in screen coordinates, independently of moving window-local event coordinates.
  A settled background drag temporarily attaches visible photos and captions to
  its native panel so AppKit translates them together. Scene coordinates still
  update per proposal. Release, cancellation, menu interruption and placement
  changes detach them before commit or rollback. Independent photo/group resizing
  and an active boundary animation retain explicit panel placement.
  Photo resizing retains the 2.4.9 width-driven geometry. Resize guides do not alter
  scale, and member resizing directly refits the visible boundary in both directions.
  Settings focus never changes a widget's selected depth.
  Borderless photo/background panels override AppKit's titled-window frame
  constraint so floating scenes can cross screen edges without per-panel shifts.
  Geometry updates for a group or resized member share a zero-duration AppKit
  animation context; no implicit animation is added to pointer movement.
  Native server-side dragging is disabled on interactive panels and their views;
  Arras's handlers own move/resize proposals. Placement derives absolute native
  origins from scene geometry instead of compounding an existing native offset.
  Caption panels use position-only updates during translation; text layout changes
  only with appearance or the requested scene size, not rounded native-window sizes.
  An existing visible caption at matching depth/Space behavior follows geometry
  without an active-Space query. Showing or changing its placement retains that
  check so an off-Space collage is never pulled onto the active Space by its label.
- Collage placement overrides member depth and Space behavior at runtime. Member
  rows expose inherited placement as read-only values and route editing to the
  collage, while the saved member values remain intact for detach. Individual
  appearance is editable. Shared stacking actions resolve the effective parent
  depth, including the menu's floating toggle.
- Display visibility is reconciled against connected screens on load. Screen
  geometry changes trigger restoration even when the connected identifiers do
  not change. Grouped children use their parent’s effective depth for actions.
- Collage borders draw entirely outside the group body and scale with the scene;
  the window reserves enough canvas to avoid clipping the stroke. Transparent
  groups retain ordinary membership/move/resize behavior while hiding material,
  paper and group shadows. Older settings default to no outside border.
- Starter examples stage local artwork and the entire parent/child scene before
  one durable save, then use normal manager window creation. Failed saves roll
  back only the new model entries and files. The picker separates previewing a
  demo from adding it and explains the real controls it demonstrates.
- The retired Combine Photos model, editor, layout engine and renderer are removed.
  Decode-only migration preserves old media as an ordinary slideshow; retired
  fields are never encoded. Archive import uses that same migration.
- The retired Bubble/Polaroid container renderer, editor and gestures are removed.
  A decode-only marker drops their empty parent records on load/import; child
  photos retain media, geometry and personal appearance as standalone widgets.
  Retired parent/pin fields are never written into new stores or archives.
- Legacy per-photo schedule values remain decodable and do not affect visibility.
  Termination saves synchronously on the main actor; shutdown must not depend on
  a later `Task`. Storage migration never overwrites a destination with a layout.
- Telemetry state is separate from the photo store and excluded from backups.
  Telemetry failure must never modify or block widget data.
- Tests inject `PhotoManager(storageDirectory:)` or `ARRAS_UI_TEST_STORAGE_DIR`.
  `ARRAS_UNIT_TESTING=1` also isolates hosted startup and disables updater,
  hotkey and normal window startup. Test cleanup is limited to scratch storage.
  A `--ui-testing` launch without a nonempty test path gets per-process temporary
  storage rather than opening/migrating the personal library. Explicit directories
  retain priority, and ordinary launch storage remains unchanged.

## Saved desktop setups

`SavedSetups.swift` stores named local model snapshots and the desktop from before
the last setup switch in an atomic `setups.json`. Setups share existing managed
media and font files; garbage collection must check both active and saved references.
Unreadable setup metadata blocks deletion. Switching validates file availability,
writes the recovery snapshot first, commits the active model, then rebuilds windows.
Saving settles provisional gestures only after the setup write succeeds; switching
leaves cancellation to the desktop installer after the active-model commit. Failed
recovery/setup or active-store writes retain gesture ownership and native geometry.
Global preferences remain separate. Portable `.arras` export is still explicit.

`RemovedWidgets.swift` keeps the last removal in the same snapshot store before
committing the active desktop. Its media and fonts remain protected across
relaunch. Recovery merges missing IDs into the current desktop, preserves later
edits and additions, and rejoins detached children only if they have not moved to
another collage. Its durable addition shares import runtime restoration, preserving
unrelated windows, playback, appearance drafts, import generation and arrangement history. Recovery
fits affected parent bounds from current committed member geometry before saving;
conflicting gestures, return motion or affected appearance previews are left intact
for retry. The same scene-specific interaction guard protects each case; unrelated
drafts remain live and are not written into the recovered model. Failed saves
restore the whole active model without altering native windows or recovery data.
A subsequent successful removal or explicit discard releases
the previous recovery after checking all remaining references. Failed removal
rolls back the active model and attempts to restore the previous recovery record.
Removal does not globally cancel interactions: missing IDs are a no-op, affected
unfinished scenes wait for retry, and unrelated previews/gestures keep ownership.
After durable removal, only surviving affected parents are synchronized and refit.
Runtime restoration checks the existing Photos permission and installs its one-time
change observer when a loaded setup or recovered widget introduces a live source.

## Dialogs and permission recovery

`AppDialog.swift` owns native alert construction. Actions use descriptive verbs,
explicit cancel/destructive roles and predictable keyboard behavior. Return must
never accept an irreversible action by default. SwiftUI confirmations use native
alerts with the same title and action conventions; keep explanations in message
text rather than long question titles. Collage draft prompts remain window sheets.

Denied Photos access offers **Open Photos Settings**, targeting the Photos privacy
pane, then the general privacy pane and the Settings app as fallbacks. Restricted
access explains the administrator/Screen Time requirement. Background refreshes
never request permission. Library notifications arriving during a download are
coalesced into a follow-up pass instead of overlapping reconciliations.
Downloads resolve the current widget by ID after suspension and retain its latest
appearance and playback choice. Rebuilding the desktop invalidates in-flight
Photos results even when a saved setup restores the same widget IDs. Refresh
must respect manual, parent, display and presence visibility before creating windows.
Completed album downloads wait for an affected collage drag, resize, return
motion or appearance preview before committing. The wait is cancellable and
invalidated by a changed source or desktop; it runs only for pending work.
Unrelated scenes remain editable. Read the latest placement and appearance after
the wait, and recheck the same scene guard at the synchronous commit boundary.
Linked-folder reconciliation uses the same cancellable scene wait, preserves a
slide selected during preparation, and prepares changed files off the main actor.
If the displayed managed filename stays the same, retain its native media and
geometry. Folder-source status changes roll back when persistence fails, including
unavailable, empty and watcher-registration paths.
Photos commits likewise retain the existing native media when its displayed
filename and media representation are unchanged. Metadata and sibling changes
still save normally; a missing visible window can be restored through the usual
visibility guards. An unchanged notification must not refit a completed resize
or invalidate its arrangement history.
Next/Previous slideshow advances use the same affected-scene guard, including
individual drags/resizes, drop targets and return motion. A blocked timer tick
does not change playback or saved geometry; the normal timer continues after
the edit settles. Unrelated slideshows keep advancing.
Resource selection prefers Photos' edited full-size photo/video representation;
unaltered photo/video and alternate-photo resources retain compatibility. Adjustment
data is never treated as media. Cache entries record selected resource-type codes
and source modification dates; older entries revalidate once without discarding
their safe snapshot on failure. Portable archive snapshots omit the cache marker.
Empty/unavailable source-status changes use the same durable-save rule: failure
restores the previous source metadata and retains the existing media snapshot.
The album controller captures a value-only selection in its Sync action before
ending modal tracking; the caller never rereads mutable table selection afterward.

## Windows and collage groups

Capture exclusion retains the legacy `NSWindow.sharingType = .none` request for
compatible capture paths. Apple's current documentation does not support treating
it as guaranteed exclusion from modern recording or sharing. Privacy copy must
state that visible widgets can still be captured and describe manual hiding;
conferencing/fullscreen detection remains a separate heuristic.

- `PhotoManager.windows` is the only desktop-window registry. Panels are
  non-activating and can outlive close while another caller retains them;
  teardown detaches decoded media and players. A collage's `contentView` is its
  only strong surface owner, so a retained closed panel releases its material tree.
  Do not find live widgets by scanning stale retained entries in `NSApp.windows`.
  Hiding a collage cancels its transition and detaches input ownership. Deferred
  desktop double-clicks require the original visible panel/view pair before
  presenting an editor or requesting ordering.
  Native lifetime regressions must drain creation-time autoreleased references as
  well as teardown, or observe after returning to the event loop; a teardown-only
  pool and nested run-loop wait can retain temporary views without a product leak.
- Depth chooses window level; saved stack order chooses order within a depth.
  Behind Icons is locked and cannot receive pointer interactions. At interactive
  depths, position lock prevents movement but retains configured double-click actions.
- Desktop photo/backdrop and collage-label panels suppress AppKit's inferred
  ordering animations. Their layers share explicit scene placement and transitions
  rather than independent window transforms when shown or hidden.
- Hover reveal derives effective alpha from saved opacity, pointer state and
  depth. It must not overwrite configured opacity; reused panels reset pointer state.
- Settings stays normal-level, managed and primary, moves to the active Space,
  disallows tabbing and fullscreen, and is reused by `AppDelegate`. Widgets retain
  their selected depth while Settings is active; activation and Space changes
  restore group order. Closing Settings keeps Arras alive.
- Unbound widgets join all Spaces. Space pinning changes collection behavior;
  public APIs do not provide durable numbered-Space identifiers.
- Desktop collage drafts preview on the actual desktop without altering JSON.
  Close, Cancel and Escape prompt when edits remain. Apply saves typography,
  appearance, depth and Space binding together; failures preserve the saved scene.
  The collage editor is single-use: close clears focus and its hosted view before
  notifying the owner, releasing the observed model even if AppKit retains the
  closed window. The reusable main Settings window keeps its own content.
  Empty-area events under a photo shadow forward to one captured collage target.
  Collage callbacks are wired on every eligible photo window. Bulk movement
  respects inherited locks/depth and translates all slideshow per-image frames.
  Collage menus use a screen-coordinate popup without an owning view, so AppKit
  menu presentation cannot raise the backdrop over photos. Match AppKit's contextual
  placement just beyond the pointer, leaving the opening point outside the menu
  so another click dismisses it. Opening a menu cancels an unfinished background
  drag before tracking. Ordering is repaired
  at menu open/close, without queued tracking-loop work.

## Rendering and resource use

- GIF/APNG uses render-server `CAKeyframeAnimation`; muted video uses
  `AVPlayerLayer`. Do not introduce a perpetual app-side frame timer or display link.
- Occlusion, sleep, thermal pressure, Low Power Mode and unplugged battery at
  20% or below feed one playback policy. Partial coverage uses one shared metadata
  sample every half second, only while eligible visible dynamic widgets exist.
  Known caption and alignment panels are excluded from covering-window
  candidates, including brief ordered-out metadata lag, because their transparent
  canvases span the media they annotate.
  Display-sized Dock-level surfaces are also excluded only after their owner PID
  matches the running `com.apple.dock` application and their bounds span a Quartz
  display rectangle. Ordinary app panels, unknown owners and the actual Dock strip
  remain covering candidates; AppKit's full-occlusion signal remains independent.
  Other overlapping windows continue to pause decorative playback.
- Hidden/presence-suppressed widgets release windows and rotation timers. Fullscreen
  exit restoration waits for a stable observation; its transition guard is separate
  from the optional fullscreen-hiding preference, which defaults off.
- Desktop photos keep their own windows and shape masks. Frame,
  border, mat, shadow and tilt geometry use the same authoritative visible footprint.
  Snap/align/distribute use that footprint, not shadow margins; bulk layout stays
  on one display and rejects newly introduced overlap.
- Slideshow membership changes save before repaint or unreferenced-file deletion
  and keep at least one image. Saved rotation intervals remain compatible.
  Playback order, interval and sizing commit before changing timers or cropping.
  Next/Previous decode the destination and save selection/history before swapping
  media; decode/write failure preserves the current image and selection.
  Native timers use integral seconds so very large custom values cannot overflow
  a floating-point nanosecond conversion; the five-second minimum is unchanged.
  An out-of-range saved slideshow selection resolves to its first image before
  Settings or playback uses it; valid selections and all media remain unchanged.
- No memory-pressure-specific collage eviction or near-zero idle guarantee is
  established. Native materials, large libraries and sustained media playback
  require hardware measurement and visual review.

## Import, archive and UI boundaries

- UI backup export captures model, preferences and display geometry on the main
  actor, then hashes and streams managed files on a cancellable worker. ZIP32
  arithmetic is checked before writes; same-volume replacement preserves an
  existing backup on failure. Trailing data descriptors retain compatibility with
  2.5's central-directory reader. Import reads a bounded directory and one payload
  at a time through a retained file handle, so truncation fails without mapping a
  mutable source. Media files are capped at 512 MiB, total ZIP/staging bytes at
  UInt32.max, manifests/directories at 16 MiB and fonts at 20 MB. Preflight I/O and
  decoding run in a worker; display adaptation and the durable model commit stay
  on the manager's actor. Finder-opened archives retain sequential confirmations.

- Prepare media off the main actor, then validate/stage all resources before one
  durable merge/replace. Reject malformed, empty or unsavable replacement input
  without erasing a working layout; rebuild windows and clean old media only afterward.
- Each resource records its own fidelity: unchanged video bytes and a generated
  poster have different provenance. Archival export preserves managed bytes,
  not originals lost before ingest. Standalone videos are capped at 512 MiB;
  linked folders at 200 images / 256 MiB, with a current-image retention exception.
- Import gives fresh IDs/filenames, validates managed paths and archive versions,
  and restores geometry onto visible displays. Optional preferences require an
  explicit choice separate from widget import.
- A row click expands details; its checkbox changes selection. Global controls
  belong in Preferences, presence controls in Privacy, and detailed appearance
  in Frame. Icon-only controls need accessible labels, hints and values.
- Selected removal is transactional. Settings may remember confirmation opt-out
  and Preferences can restore it; menu removal always confirms. Menus rebuild
  lazily from the authoritative model when opened.

## Updates and release ownership

`AppDelegate.current` is a weak reference registered by the actual SwiftUI adaptor
at startup. SwiftUI owns `NSApp.delegate`; updater activity, Settings actions and
App Intents use the registered Arras owner rather than casting that wrapper or
creating a second manager. Automatic installation waits if the owner is not ready.
The SwiftUI scene replaces its Settings command with the adaptor's existing
window action; it must not open the placeholder Settings scene or compete with
AppDelegate's single-window ownership.

The adaptor owns its in-memory tab/navigation state. Update actions select
Preferences and request one scroll to Updates; ordinary reopening preserves the
selected tab. Notification default actions route update/failure banners there
without another check or installation. Dismissal is inert; announcement links
retain their explicit-click route.

`project.yml` owns configuration; XcodeGen regenerates `Arras.xcodeproj`.
The deployment target is macOS 14 and current Settings appearance needs the macOS
27 SDK. `Arras` remains unsandboxed for its in-place updater and surviving helper.
`ArrasAppStore` shares the UI, models and rendering, but excludes `Updater`,
`DownloadTask`, `InstallLocation`, `StorageMigration`, `Telemetry` and
`TelemetryRuntime` from its source membership. Its `ARRAS_APP_STORE` condition
selects the Store lifecycle, Preferences and privacy disclosure. Store-only code
and resources live in `Sources/AppStore`; Store-specific tests in `Tests/AppStore`.
The Release ID is `com.yashashwi.arras.appstore`; Debug adds `.development` and
uses a separate visible app name. Both schemes retain the `Arras` Swift module.

The Store library is container-local. `SandboxLibraryImport` stages only referenced
media and fonts from a user-selected library, validates decoded models and files,
strips old folder grants, then commits into an empty destination with rollback.
It never automatically reads the direct edition's library or copies its telemetry.
Photo/PDF reads balance security-scoped access; persistent folder grants are read-only.
Store region capture uses ScreenCaptureKit after transient selection overlays close.
`AppStoreUpdates` opens Apple's Updates page; no executable download helper is linked.

Build provenance binds the selected target and distribution as well as source inputs.
The bundle validator defaults to direct distribution, so the existing GitHub
packager/notarizer rejects Store bundles. Store validation additionally checks both
sandbox slices, API-reason privacy declarations, disabled telemetry and absence of
Debug exceptions. Store builds/archives stay in `build/app-store`; only the direct
scheme produces public GitHub ZIP/DMG artifacts. TestFlight must be tested before
App Review, submission uses manual release, and the website badge waits for a live listing.

Every app build snapshots application/build inputs before compilation and verifies
that snapshot before stamping the signed bundle. `build.sh` anchors itself to its
own checkout, regenerates the project, builds both CPU architectures and rejects
source mismatches. ZIP and mounted-DMG verification compare all app bytes and
symlinks to the validated build. `--pilot BUILD` explicitly enables telemetry in
that private artifact and disables public updates. The 2.5.0 Release configuration
enables limited statistics too, while retaining the normal updater. User-facing
release names use the marketing version.

Developer ID distribution is a post-build operation. `notarize_distribution.py`
validates the original build, signs a separate copy without restamping source
metadata, and records its startup script digest in the distribution receipt.
Changing that script during a run stops further work and promotion; saved request
IDs can be resumed with the revised script. Its
durable state binds the original bundle inventory, certificate/team configuration,
frozen upload hashes and Apple request IDs. Pending requests resume rather than
uploading again; an OS process lock serializes a work directory and unknown upload
outcomes require inspection. Successful app and DMG results must match their
uploaded bytes. Tickets, both signatures and platform
policies are checked before atomic promotion of a new output directory. A
completed directory move interrupted before state save is revalidated; unrelated
existing output remains intact. This receipt supplements the compilation digest.

Both update installation modes honor the selected cadence (Daily by default,
including Never). Wake/activation and a tolerant timer check elapsed due time.
Failures have a persisted 15-minute retry floor; successful checks alone update
last-checked status. Manual checks remain available and notification permission
is requested only when needed. Notification eligibility is checked before and
after status lookup and permission requests; cadence or automatic-mode changes
suppress stale scheduled alerts without acknowledging them. Only accepted submissions persist their
deduplication marker. Manual and automatic installs share HTTPS,
checksum, ZIP, identity/version, quarantine handling and rollback validation;
turning automatic installation off mid-download prevents installation.
Automatic replacement also waits for all active media-import scopes, including
Photos downloads, ordinary files, replacements and linked-folder reconciliation.
The main-actor count is balanced with `defer`, so overlapping imports cannot clear
one another's protection; UI status text is not the import-lifetime authority.
It also checks the manager's live arrangement state: photo/member drags, group
move/resize snapshots, return motion and appearance drafts. The same guard runs
before download and after asynchronous download/verification; explicit manual
installation retains its existing behavior.
`ContentView` observes the toolbar/empty-state Photos selection at one common
ancestor. Its download scope starts with the selection and captures the desktop
generation before the async transfer; results cannot enter a newly restored setup.

Every release has reviewed `release-notes/<version>.json`. CI rejects missing,
mismatched or placeholder copy. The release runner normally builds, notarizes and
uploads artifacts, then writes the published ZIP's URL/checksum and reviewed
notes into `appcast.json`. An explicitly authorized publication of preverified
local notarized output must first match GitHub's uploaded asset digests against
the distribution receipt. The feed always describes those exact published bytes.
Published assets are immutable; fixes receive a new version rather than replacing
files already downloaded or referenced by a checksum.

| Document | Maintained responsibility |
| --- | --- |
| README.md | Concise overview, official download and starting points |
| FEATURES.md | Task-based guide for the checkout's version, with unfinished work clearly labeled |
| ARCHITECTURE.md | Ownership and engineering contracts |
| SECURITY.md | Distribution trust, local data, networking and disclosure policy |
| CONTRIBUTING.md / CLAUDE.md | Contributor/agent guidance and verification |
| CHANGELOG.md / release-notes/ | Unreleased changes and truthful published history |
| product-metadata.json | Stable machine-readable product facts |

GitHub Releases/appcast own release-specific artifacts and digests. The website
consumes the main product contract with a generated fallback cache; it must not
advertise this branch's unfinished work as published. Keep signing/first-launch
facts aligned across app and website. Verification, manual release checks and
latest dated results belong in [CONTRIBUTING.md](CONTRIBUTING.md#release-verification).

## Reference edits

`PhotoReference.swift` owns optional, backward-compatible `PhotoItem.reference`
settings and a shared Core Image renderer. Crop coordinates refer to the original
image before quarter-turn rotation and flips. Sources are never rewritten;
archives carry original managed bytes plus edits, notes and a source link.
`ReferenceInspector.swift` previews a bounded-resolution still and applies a
normalized draft only after a durable model write. A stale reference draft or
failed save leaves the prior edits intact. Preview zoom is not persisted.
Desktop stills, GIF frames, video compositions and thumbnails use the same
transform order. Movies retain source render resolution rather than using their
smaller poster dimensions. Copy Appearance excludes content-specific edits;
duplicate and archive import retain them. Notes and links never enter telemetry.

## Photos download lifecycle

`PhotosResourceTransfer.swift` bridges PhotoKit’s arbitrary callback queue into
async code. A lock serializes chunks, byte limits, cancellation and exactly one
continuation result; cancellation handlers execute outside that lock. Cancellation
before request registration is remembered and forwarded once the request exists.
Collection sync discards staged files on cancellation and retains its previous
snapshot. Download progress is scoped to the active request and desktop generation.
Restoring a desktop advances that generation even when saved widget IDs match.
File, clipboard, slideshow, replacement and linked-folder work checks its captured
generation after preparation; stale results are discarded before any model commit.
Replacements also compare the requested media and slideshow slot after suspension;
they cannot overwrite a later replacement or a newly selected slide. Name and
appearance changes are read from the current model and remain compatible.
The progress panel's Cancel button, Escape key and window close action cancel the
sync task; normal completion clears that handler without cancelling the operation.
Cancelled imports do not present a completion summary.

## Feature discovery

`PhotoToolsView.swift` provides an always-available entry from the Photos header.
It opens the existing appearance and reference editors, exposes copy/paste for a
chosen photo (including collage members), and links to saved setups. Arrangement
instructions describe the actual selection requirements. It does not create
sample widgets or change a desktop merely by opening the guide. Selection actions
occupy a separate row to keep header controls usable at the minimum window width.

## Arrangement history

`ArrangementHistory.swift` keeps up to 50 entries for alignment, distribution,
keyboard nudges, photo moves/resizes, whole-collage moves/resizes, and membership
changes from dragging or Remove from Collage. It includes affected collage parents, children,
per-image frames and display profiles. Undo/redo checks current geometry and group
membership against its expected state, then persists before repainting. It never
restores old media, visibility or names, and failed saves leave both
history and windows unchanged. Desktop replacement clears history. Collage resize
entries also store the dimensions they scale (composition scale, corner radius,
mat and border widths, shadow blur), checking these before restoration. Other
appearance values remain untouched. Active gestures and photo spacing animations
disable undo; controls refresh when photo motion ends. Canceled gestures and failed
commits add no entry. Membership restoration includes affected group bounds and
stacking order, resets independent window behavior on detach, and reapplies parent
visibility and depth on attach. This is not general document undo.
