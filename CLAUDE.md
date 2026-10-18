# Repository guidance for coding agents

Use this file with [ARCHITECTURE.md](ARCHITECTURE.md), which owns subsystem
boundaries, and [FEATURES.md](FEATURES.md), which describes the version prepared by this checkout and labels any unfinished work.
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

Use the commands in [CONTRIBUTING.md](CONTRIBUTING.md#build-and-test) to build
and test. Regenerate the project after source file or configuration changes.

The deployment target is macOS 14. The intended current Settings presentation
depends on the macOS 27 SDK. Compiler warnings alone are not an API audit across
the supported OS range.

`./build.sh --run` launches the validated local build without replacing an installed app.
`./build.sh --release` creates local ZIP and DMG files; it does not publish.
`./build.sh --pilot BUILD` creates a private telemetry pilot with a new number
(greater than the last shared internal build identifier). Build only from
the repository root. Keep obsolete builds and source snapshots out of the checkout.
Never stamp a digest onto an old app or copy a pilot flag onto an existing bundle.
The Xcode phases and packaging checks bind the app to current source inputs.

## Load-bearing compatibility rules

### Persisted models

`PhotoItem.init(from:)` is hand-written. Every new field needs
`decodeIfPresent(...) ?? default` or another explicit backward-compatible
migration. A decoding failure can strand the entire widget library. Test a minimal historical fixture, current round-trip behavior, and `.arras` import when the
schema changes.

Production storage is `~/Library/Application Support/PhotoWidget/`. Tests must
inject `PhotoManager(storageDirectory:)` or set
`ARRAS_UI_TEST_STORAGE_DIR`, and clean up only that scratch location.

The `Arras` target is the free direct-download edition. Keep its historic
identifier and storage path and leave it unsandboxed: its updater replaces the
bundle and starts a helper that outlives the process.

`ArrasAppStore` is a separate sandboxed target sharing `Sources/App`. Its small
`Sources/AppStore` directory owns Store updates, selected-library import, native
region capture, entitlements and its privacy manifest. `ARRAS_APP_STORE` selects
only distribution-specific behavior. Never include the direct updater,
self-installer, telemetry or automatic legacy storage migration in that target.
Its production ID is `com.yashashwi.arras.appstore`; Debug adds `.development`
and displays as Arras App Store Dev. Storage stays in that app's container.
Copy an existing library only after an explicit folder selection, into an empty
Store library; use .arras backups to merge into existing content.

`./build.sh --app-store` validates a local ad-hoc universal sandbox build under
`build/app-store`. `--app-store-archive` creates a signed archive there for App
Store Connect. Neither mode creates GitHub release artifacts. Keep credentials,
archives and packages out of Git. TestFlight and App Review use the Store target;
App Review must use manual release. The free direct download remains the
website's main button. Add the Store badge only after the listing is live.

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

The release workflow normally builds, notarizes and uploads the official artifacts,
then generates the release body and `appcast.json` from those exact uploads.
For an explicitly authorized publication of already verified local notarized
packages, compare GitHub's uploaded asset digests with the notarization receipt
before updating the feed. Its URL/checksum must identify the published ZIP;
never use an ad-hoc build's checksum or let a duplicate workflow replace the
verified uploads. Once published, keep release assets immutable and use a new
version for fixes. See [CONTRIBUTING.md](CONTRIBUTING.md#build-and-test).

Do not create tags, releases, or publish artifacts unless the user explicitly
authorizes publication.

## Documentation ownership

- `README.md`: concise GitHub front door, at most 200 lines.
- `FEATURES.md`: reviewed behavior for the checkout's version and clearly labeled unfinished work;
  unfinished features must never be attributed to the public download.
- `ARCHITECTURE.md`: durable ownership and engineering contracts.
- `SECURITY.md`: distribution trust, data/network behavior, and reporting.
- `CHANGELOG.md` and `release-notes/`: truthful historical records.
- `product-metadata.json`: stable machine-readable public facts. GitHub
  Releases/appcast own release-specific version, date, URLs, and digests.
- [SECURITY.md](SECURITY.md#telemetry-protocol-and-activation): exact telemetry protocol and production activation steps.

Keep documentation consolidated. Record development changes under Unreleased
in CHANGELOG, dated verification and remaining release checks in CONTRIBUTING,
and engineering contracts in ARCHITECTURE. Do not add duplicate milestone
inventories, branch handoffs, audit reports or payload-copy files unless the user
requests them. Use temporary directories for scratch logs; keep recovery copies outside the checkout.

Whenever user-visible behavior changes, the same pull request must update the
relevant product documentation or explicitly demonstrate why no documentation
change is needed. Do not infer shipped behavior from an unreleased code path,
old prose, or a release tag whose documentation was already stale.
