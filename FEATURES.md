# Arras current shipped feature contract

This document describes user-reachable behavior in the current public release.
It is maintained on `main` so documentation errors can be corrected without a
new app release. Version-specific changes belong in
[CHANGELOG.md](CHANGELOG.md) and [GitHub Releases](https://github.com/yashashwi-s/Arras/releases).

## Product behavior

Arras is a macOS menu bar agent with no Dock or Command-Tab presence. Every
widget is an independent, non-activating AppKit window, so interacting with a
photo does not take focus from the current app. Widgets keep the source image's
aspect ratio instead of using a WidgetKit grid or forced crop.

### Widgets and placement

- Create multiple widgets; move them by dragging and resize from any corner
  while preserving aspect ratio.
- Rename, duplicate, replace, hide/show, lock, and remove each widget. **Remove
  All** requires confirmation.
- Set opacity from 10–100% in Settings or by scrolling over the widget.
- Enable **Reveal on hover** per widget. The widget is transparent until the
  pointer enters, then fades to its saved opacity. At **Behind Icons** depth,
  Finder prevents pointer delivery, so the widget remains at its normal opacity.
- Choose four depths: **Behind Icons**, **On Desktop**, **Above Widgets**, and
  **Floating**. Behind Icons locks the widget because it cannot receive pointer
  input. Bring to Front and Send to Back can move through depth levels and
  preserve order among widgets at the same depth.
- Use the widget's right-click menu for locking, stack order, and removal. The
  Settings row and menu-bar widget submenu expose the broader controls.
- Snap to display edges and centers, the macOS desktop-widget gutter/grid, and
  other Arras widgets. Snapping to other applications' windows is optional.
  Hold Command to disable snapping temporarily; hold Shift to constrain a move
  to one axis. Solid and dotted guides distinguish direct and extended edges.
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
- Replacing the current Space image updates that exact persisted slot, keeps its
  saved dynamic frame, and survives hidden state and relaunch.

### Appearance

- Apply Gallery, Polaroid, Minimal, or Modern presets. Hand-tuning any frame
  value marks the result as Custom.
- Choose rounded rectangle, circle, squircle, or arch masks.
- Adjust corner radius, photo mat width/color, solid/dashed/dotted border,
  optional two-color gradient stroke, two-layer shadow, edge fade, and tilt from
  −12° to +12°.
- Common controls live in the widget row. The Frame inspector contains the full
  set and an accessible Advanced disclosure.

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

### Menu bar, Settings, and automation

- The status menu groups commands under **Add**, **Widgets**, and **Options**.
  Settings and Quit remain top-level. Optional Add, privacy, and global-visibility
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
  scheduled checks.
- Arras reevaluates whether a check is due every minute, after Mac wake, and
  when the app becomes active. A failed scheduled fetch is retried no sooner
  than 15 minutes later; failures do not advance the last-successful-check time.
- **Check Now** remains available regardless of schedule. Settings shows the
  last successful check using a live relative time while the window is open.
- With automatic installation off, a scheduled check posts one notification for
  each newly seen version. Notification permission is requested only when a
  banner is needed.
- The feed and archive must use HTTPS. Installation requires a published SHA-256
  checksum, a ZIP containing an app with bundle identifier
  `com.yashashwi.tableau`, and a bundle version matching the feed. Semantic
  version comparison prevents rollback.
- Updates download to a staging directory, then a helper atomically swaps the
  writable running app and relaunches it. The helper keeps a previous copy until
  the new version writes a startup health marker; otherwise it restores the old
  copy. Turning automatic installation off during a download prevents install.
- Arras offers to move itself to `/Applications` when its current location
  cannot be updated in place.

### Privacy, permissions, and presence

- Arras has no account, app analytics, telemetry, or crash-reporting service.
  Update checks and downloads use GitHub; Photos can fetch a selected iCloud
  asset through Apple's Photos framework.
- Media and layout state remain in local Application Support unless the user
  exports or copies them.
- Screen-capture exclusion is optional and requests that macOS omit widget
  windows from ordinary screenshots and compatible recording/sharing paths. It
  does not cover AirPlay or HDMI display mirroring.
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
- Public builds are ad-hoc signed and are not notarized. macOS can therefore
  show its expected “Apple is not able to verify that it is free from malware”
  Gatekeeper verification warning on first launch. Installers can choose
  **Open Anyway** in **System Settings → Privacy & Security**, then confirm
  with a Mac password or Touch ID if macOS asks and choose **Open** as
  applicable; macOS records that decision.
- The app is intentionally not sandboxed because its in-place updater replaces
  its bundle and launches a helper that outlives the running process.
- Arras stores media locally but is not an original-photo archive. Export
  `.arras` backups explicitly for recovery or transfer.
