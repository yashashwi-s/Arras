# Arras feature guide

## App Store target — waiting for review

The shared source also builds a sandboxed Mac App Store edition, planned at $4.99.
The free direct download remains available and primary on the website. The Store
edition uses Apple's updates, container-local storage, explicit existing-library
import and native region capture; it excludes app telemetry and the direct updater.
Its separate target, identity and output directory prevent mixing distribution
packages. Version 2.5.0 was installed through TestFlight and submitted to App Review
on 19 October 2026 with manual release selected. No App Store badge or availability
claim should appear until the listing is live. The released 2.5.0 behavior below
continues to describe the direct-download edition unless stated otherwise.

[View the Store update preferences](assets/app-store-preferences.png) — a native
render from the sandbox target, with updates managed by Apple.

## Find your next step

This guide describes **Arras 2.5.0**. Start with an example or your own photos,
then use the controls below to make the desktop yours.

| What you want to do | Where to start | What you can do |
| --- | --- | --- |
| Try a finished look | Settings → Add → Try an Example | Six editable scenes with bundled original AI-generated still artwork: a simple photo, print frame, glass collage, labeled moodboard, animation and slideshow. After adding, a guide helps you find the example and opens Photo Tools on its first photo. Photo Tools → Replace Image swaps in your own picture while keeping its styling. |
| Build a photo collage | Add → Create Collage | Group independently editable photos; drag the background to move the group, hover for corner grips to resize, or drag a photo to rearrange or detach it. The boundary grows and shrinks during individual photo resizing. Adjust background, spacing and border; add captions and freely placed labels with font controls. Hidden photos do not determine visible collage bounds. |
| Reuse your styling | Settings → Tools, or a photo’s actions menu | Copy Appearance and paste onto another photo or a selected group. Content, position and reference edits stay independent. |
| Choose a look visually | Photo row → Appearance, or Edit Collage | Photo previews show Thin Frame, Print, Plain, Soft Shadow, Dark Mat and Warm Paper, with a live preview of your photo. Collage cards show System Glass, White Polaroid, Gallery, Ink and Transparent; changes preview on the desktop before Apply. Fine controls remain available. |
| Work with a visual reference | Tools → Reference Tools | Non-destructive crop, quarter-turn rotation, flips, grayscale, notes and source links. The preview fits the edited image. Edits apply throughout a slideshow and to animated media. |
| Keep a changing collection | Add → From Photos Collection, or a linked folder | Refresh from a Photos album or a Finder folder. The Photos picker searches available albums and omits empty system albums; it does not mirror every section of the Photos app. Photos needs library access; cloud-only media needs a connection to download. Cancel, Escape or closing the progress window stops an import without replacing an existing snapshot. Retained local snapshots remain useful offline. |
| Edit a slideshow | Photo row → Edit Slideshow | Reorder, add and remove images; choose playback order, interval and sizing. A slideshow can also belong to a collage. |
| Arrange precisely | Select photos using their row circles | Align, distribute and nudge eligible photos. Undo/redo also covers photo and collage movement, resizing and group membership changes. Locked or hidden photos stay put. |
| Keep alternate desktops | Settings → Saved Setups | Save, rename, duplicate and switch named setups. Restore the previous desktop after a switch. Global preferences are not part of a setup. |
| Recover a mistake | Right-click a photo → Undo/Redo, Arras menu, or Settings → Restore | Recover the most recent removal even after relaunch. A subsequent removal replaces that recovery. Arrangement undo is session history, not a universal undo for every setting. Cmd+Z works with Settings focused or the Arras menu open; desktop photos do not steal keyboard focus from other apps. |
| Find a widget | Search and filters above the photo list | Find photos and collages by name, filter the list, and inspect why a widget is hidden. |
| Pin a screenshot, PDF or clipboard image | Preferences → Menu bar | Enable Capture Screen Region, Add PDF Page or Paste as Widget, then use Add in the Arras menu. Screen capture is a one-time screenshot and uses macOS Screen Recording permission. |
| Add motion | Add → Add Photos or Videos | Local GIF/APNG and video widgets, alongside still photos. Playback respects system and visibility policies. |

Photos collection refreshes use the edited photo or video when Photos supplies it.
If a replacement cannot download, Arras retains the previous managed snapshot for retry.
If a refresh cannot be saved, its previous snapshot and collection status stay intact.
A completed refresh waits for its collage's move, resize or appearance edit to finish.
Photos refreshes keep unchanged images in place and preserve resize Undo.
Slideshows keep their current image while you move or resize that photo or its collage.
Linked-folder refreshes preserve the latest slide choice and leave unchanged displayed
media in place, including after a collage resize.

Photos, Preferences and Privacy use rounded sections with visible surfaces in
light and dark mode, and stronger borders when Increase Contrast is enabled.
Preferences groups app-wide behavior, alignment, the desktop shortcut, updates,
setups/backup and menu customization. Saved Setups keeps arrangements on this Mac;
Export Backup creates a portable file. Backup options expand from their whole header row; menu customization is visible
in Preferences.
Switching or restoring a desktop discards unfinished imports from the previous
desktop; start those imports again in the setup where you want the media.
A pending replacement is skipped if its image or selected slideshow slot changes
while the file is being prepared; choose the replacement again for the current image.
Adding photos or merging a backup preserves existing widgets, playback,
unfinished collage edits and arrangement undo/redo. Overlapping Add operations
can finish independently without discarding each other's photos.
Restoring removed widgets also keeps unrelated widgets, playback, unfinished
appearance edits and arrangement history running. Recovered collages fit members'
later position and size edits; finish an affected move, resize or collage appearance
edit before retrying recovery.
Removing widgets preserves unrelated edits too. Finish an affected move, resize
or collage appearance edit before removing its widgets; a failed or stale removal
does not discard unfinished work.
Nudge, Align and Distribute preserve unrelated collage drafts. Finish an affected
move, resize or collage appearance edit before arranging that selection; a failed
save keeps both the selected geometry and other unfinished edits intact.
Paste Appearance also preserves unrelated moves, resizes and spacing previews.
Finish an affected photo or collage edit before pasting its appearance; hidden
and position-locked photos remain eligible when no interaction is unfinished.
Failed Saved Setup saves and switches also preserve an unfinished move or resize
so you can finish it and retry.

For a first session, add a **Glass Photo Collage** example, change one photo’s
appearance, then copy that look to another. Save a setup before experimenting
with a different arrangement. The Tools button remains available after onboarding.

Reference Tools does not provide drawing, a color picker, an infinite canvas or
collaborative boards. Arras does not yet provide a general clock/weather/system
widget catalog. This release focuses on photos, motion and desktop collages.

Version-specific changes are recorded in [CHANGELOG.md](CHANGELOG.md) and
[GitHub Releases](https://github.com/yashashwi-s/Arras/releases).

## Product behavior

Arras is a macOS menu bar agent with no Dock or Command-Tab presence. Every
widget is an independent, non-activating AppKit window, so interacting with a
photo does not take focus from the current app. Widgets keep the source image's
aspect ratio instead of using a WidgetKit grid or forced crop.

### Widgets and placement

- Create multiple widgets; move them by dragging and resize from any corner
  while preserving aspect ratio. Corner grips appear on hover or during interaction.
  Resize follows the pointer directly; nearby alignment guides do not lock its scale.
- Rename, duplicate, replace, hide/show, lock, and remove each widget. **Remove
  All** requires confirmation.
- If a name or double-click action cannot be saved, it keeps its previous value.
  A later Saved Setup also retains that saved name.
- Duplication leaves the original unchanged and adds no widget or copied media
  if saving fails. Hidden slideshows can be duplicated from their stored snapshot;
  their per-image positions keep the copy's offset from the original.
- Replacements save media and fitted geometry before changing the desktop.
  Failed saves keep the current media and collage intact. Hidden cropped/rotated
  photos retain the replacement's placement when shown or restored from a setup.
  A replacement finishing during an edit to its photo or collage is skipped with
  a retry message. Unrelated dragging and resizing continue normally.
- Reference crop/rotation also saves and refits the enclosing collage, growing
  or shrinking its backdrop while retaining sibling placement and original media.
  Finish an affected move, resize or collage preview before applying these edits;
  unrelated photos remain editable. Failed saves keep the whole scene intact.
  Notes and source-link edits keep the current media, geometry and completed
  arrangement history; applying unchanged settings leaves the widget intact.
- If a Show/Hide change cannot be saved, the widget and any collage keep their
  previous visibility and geometry.
- Settings-width changes preserve their old geometry if saving fails. Resizing a
  hidden photo also updates the frame used when it is shown or a setup is restored.
- Depth, Space pinning and Bring to Front/Send to Back also retain their previous
  settings and window placement when saving fails.
- Set opacity from 10–100% in Settings or by scrolling over the widget.
  Opacity and hover-reveal changes keep their last saved appearance if saving
  fails, including collage captions.
- Enable **Reveal on hover** per widget. The widget is transparent until the
  pointer enters, then fades to its saved opacity. At **Behind Icons** depth,
  Finder prevents pointer delivery, so the widget remains at its normal opacity.
- Choose four depths: **Behind Icons**, **On Desktop**, **Above Widgets**, and
  **Floating**. Behind Icons locks the widget because it cannot receive pointer
  input. Bring to Front and Send to Back can move through depth levels and
  preserve order among widgets at the same depth. Opening Settings preserves
  the selected widget depth, including Floating.
- Collage depth and Space pinning apply to the entire group. Member rows show
  these shared values and link to Edit Collage; each photo keeps its standalone
  depth and Space settings for detaching. Individual appearance, movement, size,
  visibility and personal locks remain available.
- Use the widget's right-click menu for locking, stack order, and removal. The
  Settings row and menu-bar widget submenu expose the broader controls.
- Snap to display edges and centers and other Arras widgets. Snapping to other
  applications' windows is optional.
  Hold Command to disable snapping temporarily; hold Shift to constrain a move
  to one axis. Solid and dotted guides distinguish direct and extended edges.
  In 2.5.0, the guessed empty desktop grid is removed; alignment uses nearby real
  targets with a lighter magnetic pull and a strict Shift axis constraint.
- A widget remembers its frame on each display. It hides when its assigned
  display disconnects and returns to its saved frame when that display returns.
- By default a widget joins all desktop Spaces. **Pin to this Space** keeps it on
  the Space where it currently sits. macOS does not expose stable public Space
  identifiers, so this is not a binding to a numbered Space.
- Widgets participate in Mission Control and App Exposé.

### Slideshows (“Spaces”)

- Create one Space widget from several images and append more images later.
- Advance on click, every 30 seconds, every five minutes, hourly, daily, or at a
  custom interval. Previous and Next are available in Settings, the menu bar,
  and Shortcuts.
- On-click advance is handled by a double-click on the widget.
- **Dynamic** sizing remembers an independent position and true-ratio size for
  each image. **Fixed** sizing keeps one frame and crops each image to fill it.
- Image changes crossfade unless Reduce Motion is enabled.
- If the next image cannot be read or its selection cannot be saved, the current
  image and selection stay intact. Failed control saves also preserve playback
  timing, order and crop mode.
- Replacing the current Space image updates that exact persisted slot, keeps its
  saved dynamic frame, and survives hidden state and relaunch.

### Appearance

- Apply Thin Frame, Print, Plain, Soft Shadow, Dark Mat, or Warm Paper presets. Hand-tuning any frame
  value marks the result as Custom.
- Choose rounded rectangle, circle, squircle, or arch masks.
- Adjust corner radius, photo mat width/color, solid/dashed/dotted border,
  optional two-color gradient stroke, two-layer shadow, edge fade, and tilt from
  −12° to +12°.
- Common controls live in the widget row. Appearance separates visual Looks from fine-grained Adjust controls, with a
  live photo preview and an accessible Advanced disclosure.

### Media and import

- Add multiple JPEG, PNG, HEIC, TIFF, GIF, BMP, and WebP files through supported
  Finder and drag/drop paths. File decoding is performed by macOS Image I/O and
  AppKit, so malformed or unsupported payloads are skipped.
- Pick up to 20 images at a time from the Photos library. Items stored only in
  iCloud may require a download before Arras can import them.
- Paste an image or copied image files from the clipboard; dropping image files
  on the menu bar icon also imports them.
- Import one PDF page or capture an interactive screen region through optional
  **Add** menu commands.
- Animated GIF and APNG content plays through Core Animation. Arras does not use
  an app-side display loop for playback.
- Imported media is copied into `~/Library/Application Support/PhotoWidget/` so
  widgets do not depend on the original files. In the file/data ingest path, supported JPEG, PNG, HEIC,
  TIFF, and GIF sources at or below a 2560-pixel longest edge are retained as
  received. Oversized file/data stills are downsampled to that limit; images with alpha are encoded as PNG
  and opaque images as JPEG. Animated sources keep their animated bytes.
  Image-object imports, including rendered PDF pages and screenshots, use
  alpha-aware PNG/JPEG encoding rather than this file passthrough rule.
- Backups contain Arras's stored media, which may be resized or re-encoded. They
  are layout backups rather than archival copies of the originals.
- Import summaries show accepted, skipped and failed counts, with up to three
  specific problem descriptions. Failures appear before skipped-file details.

### Menu bar, Settings, and automation

- The status menu groups commands under **Add**, **Widgets**, and **Options**.
  Add and Widgets come first, followed by a compact native Undo/Redo icon row
  and removal recovery. Settings and Options follow, with Quit last. Undo/Redo
  retain action-specific accessible names, hover help and Cmd+Z/Shift+Cmd+Z.
  Optional Add, privacy, and global-visibility
  commands can be shown or hidden in Preferences; Add Photo, Settings, and Quit
  remain available.
- One Settings window contains **Photos**, **Preferences**, and **Privacy** tabs
  and moves to the active desktop Space when opened.
- Launch at Login, status-item hiding, snap options, and a rebindable global
  show/hide shortcut are available. The shortcut does not require Accessibility.
- Seven App Intents add a photo, toggle global visibility, show or hide a named
  widget, change named-widget opacity, and navigate a named Space.

### Updates

- Verified automatic installation is enabled by default. The selected cadence —
  Hourly, Every 6 Hours, Daily, Weekly, or Never — applies in both automatic
  install and notification-only modes. Daily is the default; Never disables
  scheduled checks and prevents automatic installation if selected while a check
  or download is already in progress. Explicit manual updates remain available.
  Pending scheduled notifications also honor preference changes made while
  notification permission is being checked or requested.
- Arras reevaluates whether a check is due every 15 minutes, after Mac wake, and
  when the app becomes active. A failed scheduled fetch is retried no sooner
  than 15 minutes later; failures do not advance the last-successful-check time.
- **Check Now** remains available regardless of schedule. Settings shows the
  last successful check using a live relative time while the window is open.
- With automatic installation off, a scheduled check posts one notification for
  each newly seen version. Notification permission is requested only when a
  banner is needed.
- Clicking an update or install-failure banner opens the existing Settings window
  at Preferences → Updates without starting installation. Dismissing a banner
  leaves Settings closed. Check for Updates and post-update results reveal the
  same section, while ordinary Settings reopening retains the chosen tab.
- The feed and archive must use HTTPS. Installation requires a published SHA-256
  checksum, a ZIP containing an app with bundle identifier
  `com.yashashwi.tableau`, and a bundle version matching the feed. Semantic
  version comparison prevents rollback.
- Updates download to a staging directory, then a helper atomically swaps the
  writable running app and relaunches it. The helper keeps a previous copy until
  the new version writes a startup health marker; otherwise it restores the old
  copy. Turning automatic installation off during a download prevents install.
- Automatic installation waits for open editors and active media imports or
  linked-folder refreshes, as well as desktop movement, resizing and arrangement
  previews. Explicit manual installation remains available.
- Arras offers to move itself to `/Applications` when its current location
  cannot be updated in place.

### Privacy, permissions, and presence

- Arras has no account or external crash-reporting service. Limited
  statistics use a random installation UUID that links reports within an installation.
  The 2.5.0 release enables limited statistics, disclosed in Privacy
  and [SECURITY.md](SECURITY.md#limited-statistics--250).
  Update checks and downloads use GitHub; Photos can fetch a selected iCloud
  asset through Apple's Photos framework.
- Media and layout state remain in local Application Support unless the user
  exports or copies them.
- Screen-capture exclusion is an optional compatibility request. Modern recorders
  and sharing apps may still capture visible widgets. Hide widgets before sharing
  if they must stay private, and check the sharing preview. AirPlay and HDMI
  mirroring are not covered.
- Optional process-based presence hiding removes widgets while Zoom, Microsoft
  Teams, QuickTime Player, OBS, or Screenshot is running. It cannot prove that a
  share is active and cannot detect browser calls.
- Optional fullscreen hiding tears down widget windows and slideshow timers
  when the display-frame heuristic detects fullscreen, releasing image memory.
  Auto-hidden menu bars and other display configurations can cause false
  positives or missed detection.
- Photos access is requested only when using the Photos picker. Screen Recording
  is needed for interactive region capture on current macOS behavior.
  Accessibility and Full Disk Access are not required. Notifications are used
  only for update availability, automatic-update failure, or a feed
  announcement when permission has been granted.
  Stale macOS application entries whose process has exited do not keep widgets hidden; activation also refreshes the presence check.

### Persistence and portability

- Widget state is atomically written to `photos.json`. Older schemas decode
  through explicit defaults. If the store cannot be decoded, Arras preserves a
  bounded diagnostic copy and blocks overwriting the unread state.
- A `.arras` archive contains a versioned manifest, referenced stored media,
  portable relative frames, and only the preference groups selected for export.
- Import can merge with or replace a layout. All media is validated and staged
  before a replacement commits; damaged or unsavable input cannot erase the
  working layout. Imported widgets receive fresh identifiers and filenames, and
  machine-specific display bindings are discarded.

### Accessibility and verification

- Preferences and the Arras application menu include a Star on GitHub link.
  Preferences also shows the public star count, fetched on appearance and cached
  for an hour, with refresh on Settings focus. There is no separate launch request
  or polling timer. An unavailable count
  leaves the repository link usable; selecting it opens your browser.
- Settings provides VoiceOver labels, hints, and values for controls including
  icon-only buttons and sliders. Keyboard navigation reaches the Frame
  inspector and destructive confirmations.
- Reduce Motion suppresses widget resize, hover-reveal, and slideshow crossfade
  animations.
- Automated coverage includes legacy/current model decoding, persistence and
  archive transactions, media ingest and alpha preservation, display layout,
  updater precedence/scheduling, Settings window behavior, and launched-app UI
  navigation. Multi-display, desktop Space, and final visual behavior still
  require manual testing on macOS.

## Distribution and known limits

- Arras is free, MIT-licensed open-source software. Official releases are
  published through the public GitHub repository and its Releases page.
- The official macOS 14-or-later DMG and ZIP contain a universal executable with
  both Apple Silicon (`arm64`) and Intel (`x86_64`) slices. Source builds support
  the same architectures when built with an appropriate macOS toolchain.
- The 2.5.0 app and DMG are Developer ID signed and notarized by Apple, with
  verified app/DMG tickets. macOS may ask to confirm opening an internet download.
  Older 2.4.9 artifacts were ad-hoc signed and not notarized; their first-launch
  warning does not describe the current release.
- On a short display, 2.5.0’s fixed-height Appearance and Reference Tools sheets
  can place footer actions below the visible desktop. A separate
  [editor-height fix is under review](https://github.com/yashashwi-s/Arras/pull/3);
  it is not included in the published 2.5.0 packages.
- The app is intentionally not sandboxed because its in-place updater replaces
  its bundle and launches a helper that outlives the running process.
- Arras stores media locally but is not an original-photo archive. Export
  `.arras` backups explicitly for recovery or transfer.
- Per-widget time/weekday visibility schedules are unavailable. Legacy schedule
  values remain readable for compatibility and do not affect visibility.

Release history is recorded in [CHANGELOG.md](CHANGELOG.md#250).
[SECURITY.md](SECURITY.md) documents limited statistics;
the [protocol reference](SECURITY.md#telemetry-protocol-and-activation) owns its schema and operating controls.

A follow-up under review makes Appearance, Reference Tools and Photo Tools fit
short displays so their footer actions remain visible. The published 2.5.0
package retains fixed editor heights; its 1024×768 CI desktop exposed clipped
footer actions. This follow-up is not included in the published artifacts.
