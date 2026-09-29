# Repository guidance for coding agents

Use this file with [ARCHITECTURE.md](ARCHITECTURE.md), which owns subsystem
boundaries, and [FEATURES.md](FEATURES.md), which owns current shipped behavior.
Inspect source and tests before changing either contract.

## Working principles

- State uncertain assumptions and verify AppKit behavior on a real build when it
  matters. A plausible framework explanation is not a diagnosis.
- Make the smallest focused change that fixes the requested behavior. Preserve
  unrelated user work and match the surrounding style.
- Report what was actually tested, including failures and manual checks that
  remain.
- Arras uses Swift/AppKit with SwiftUI for Settings and has no third-party
  runtime dependencies. Keep idle work event-, timer-, or render-server-driven.
- Use four-space indentation, `// MARK: -` section headings, and comments that
  explain non-obvious reasons. SwiftUI motion uses `easeInOut`, with Reduce
  Motion respected.
- Anything touching windows or `PhotoManager` belongs on the main actor.

## Build and project

`project.yml` owns build configuration and the generated
`Arras.xcodeproj`. New source files are discovered by XcodeGen. Never hand-edit
the project file; regenerate it after configuration or file changes.

```sh
xcodegen generate
./build.sh

/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project Arras.xcodeproj \
  -scheme Arras \
  -destination 'platform=macOS' \
  test
```

The deployment target is macOS 14. The intended current Settings presentation
depends on the macOS 27 SDK. Compiler warnings alone are not an API audit across
the supported OS range.

`./build.sh --run` installs and launches a local build.
`./build.sh --release` creates local ZIP and DMG files; it does not publish.

## Load-bearing compatibility rules

### Persisted models

`PhotoItem.init(from:)` is hand-written. Every new field needs
`decodeIfPresent(...) ?? default` or another explicit backward-compatible
migration. A decoding failure can strand the entire widget library. Test a real
older `photos.json`, current round-trip behavior, and `.arras` import when the
schema changes.

Production storage is `~/Library/Application Support/PhotoWidget/`. Tests must
inject `PhotoManager(storageDirectory:)` or set
`ARRAS_UI_TEST_STORAGE_DIR`, and clean up only that scratch location.

Do not change the historic bundle identifier or storage path for naming
cleanliness. Do not enable App Sandbox: the updater replaces the bundle and
starts a helper that outlives the process, and sandboxing would also move
Application Support.

### Windows, menus, and animation

`PhotoManager` owns state and desktop windows; SwiftUI views call it rather than
writing storage or creating another window authority. Persist the visible photo
frame, not shadow/tilt-expanded window geometry.

`NSMenuItem.image` does not render reliably in status menus with the current
SDK. Widget thumbnails use `NSTextAttachment` in `attributedTitle` while the
plain title remains for VoiceOver and menu search.

GIF/APNG playback uses `CAKeyframeAnimation`. Do not add per-frame Timer or
display-link work to the app process. Reveal-on-hover effective alpha is derived
from saved opacity and pointer/depth state; do not overwrite the saved opacity.

Termination handlers must save synchronously on the main actor. A `Task { }`
scheduled during shutdown may never run.

## Updates and releases

The selected updater frequency applies to both automatic installation and
notification-only mode. Wake and app-activation observers re-check elapsed
wall-clock due time, and failed scheduled fetches use a 15-minute retry
throttle. Keep automatic and manual installation on the same verification and
rollback path.

To prepare a release:

1. change `MARKETING_VERSION` in `project.yml`;
2. add `release-notes/X.Y.Z.json` with a matching version and meaningful title,
   summary, and optional details; and
3. after tests and explicit publishing authorization, create and push the
   matching `vX.Y.Z` tag.

The release workflow owns the GitHub release body, artifacts, and generated
`appcast.json` URL/checksum. Never insert a locally calculated artifact hash:
the runner rebuilds the downloadable archive.

Do not create tags, releases, or publish artifacts unless the user explicitly
authorizes publication.

## Documentation ownership

- `README.md`: concise GitHub front door, at most 200 lines.
- `FEATURES.md`: reviewed current shipped and reachable behavior, without a
  patch-version heading or roadmap.
- `ARCHITECTURE.md`: durable ownership and engineering contracts.
- `SECURITY.md`: distribution trust, data/network behavior, and reporting.
- `CHANGELOG.md` and `release-notes/`: truthful historical records.
- `product-metadata.json`: stable machine-readable public facts. GitHub
  Releases/appcast own release-specific version, date, URLs, and digests.

Whenever user-visible behavior changes, the same pull request must update the
relevant product documentation or explicitly demonstrate why no documentation
change is needed. Do not infer shipped behavior from an unreleased code path,
old prose, or a release tag whose documentation was already stale.
