# Contributing to Arras

Thanks for helping improve Arras. Open or join an issue before substantial
changes. Keep pull requests focused, prefer Apple frameworks and direct fixes,
and preserve low idle resource use and local-first behavior.

## Build and test

Arras requires macOS 14 or later, XcodeGen, and Xcode with the macOS 27 SDK for
the intended current Settings appearance.

```sh
xcodegen generate
./build.sh

/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project Arras.xcodeproj \
  -scheme Arras \
  -destination 'platform=macOS' \
  test
```

The Test action supplies process-local Privacy defaults for native window
fixtures. They do not inherit live conferencing/fullscreen hiding preferences;
saved preferences stay intact. Run and Profile retain normal user preferences.
Native menu tests queue their opening clicks and verify
[AppKit's current event](https://developer.apple.com/documentation/appkit/nsapplication/currentevent)
before observing WindowServer order. These fixtures do not replace physical input
or Space-switch acceptance.

`./build.sh --run` opens the validated local app; it does not replace Applications.
`./build.sh --release` packages locally. `./build.sh --pilot BUILD` builds a
private telemetry pilot; replace BUILD with a new integer (greater than the last shared internal build identifier). Build only from the current source checkout.

### App Store target

Choose **Arras** for free direct-download development and **ArrasAppStore** for
sandbox work. Both use shared `Sources/App`; Store-only code/resources and
regressions live in `Sources/AppStore` and `Tests/AppStore`. Do not copy the app
code into a second tree. `project.yml` generates both targets and schemes.

| Distribution | Release ID | Local output | Updates / statistics |
| --- | --- | --- | --- |
| Direct (free) | `com.yashashwi.tableau` | `build/current`, `dist` | Verified GitHub updater; limited statistics |
| App Store (planned $4.99) | `com.yashashwi.arras.appstore` | `build/app-store` | Apple updates; app telemetry excluded |

Store Debug uses `com.yashashwi.arras.appstore.development` and the name
**Arras App Store Dev**. UI tests own UUID directories under
`/private/tmp/ArrasAppStoreUITests/`; only Debug app/runner entitlements allow this
fixture root. Unit tests inject scratch storage. Never test by replacing a user's
library or launching the production Store identity against personal content.

```sh
./build.sh --app-store
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Arras.xcodeproj -scheme ArrasAppStore \
  -destination 'platform=macOS' test
./build.sh --app-store-archive
```

The local build is ad-hoc signed and cannot be uploaded. Archiving requires the
configured Apple team and signing access; export via **App Store Connect** with
its distribution provisioning profile and Mac installer signing identity. Upload
only to Apple, never GitHub Releases or generic public CI artifacts. Use the same
processed build for TestFlight and review; do not use an internal-only export
that cannot be submitted to review. Verify actual TestFlight installation,
container permissions and library import before submitting with **manual release**.
The website Store badge is gated on an approved, publicly live listing; free
direct download stays the main button.

The separate sandbox folder's 18 October verification recorded 399 native tests
with one skip and 77 script checks passing. Its UI runs passed 14 distinct cases;
three synthetic typing/drag cases remained red despite basic manual typing and
dragging acceptance. Those results are historical evidence, not results for this
merged target. Preserve the source folder until the merged build and needed
recovery data are verified. The merged target's TestFlight and review status is
recorded in [dual-target merge verification](#dual-target-merge-verification--18-october-2026).

For Developer ID distribution, build first and run the separate postprocessor:

```sh
python3 scripts/notarize_distribution.py \
  --identity YOUR_DEVELOPER_ID_CERTIFICATE_SHA1 \
  --team-id YOUR_APPLE_DEVELOPER_TEAM_ID \
  --keychain-profile arras-notary \
  --work-dir build/notarization \
  --output-dir dist/notarized \
  --wait-seconds 900
```

Use a Developer ID **Application** certificate and a previously validated
`notarytool` Keychain profile. Passwords/private keys are not script arguments or
artifacts. The runner needs its own installed identity/profile; repository variables
`ARRAS_SIGNING_IDENTITY`, `ARRAS_DEVELOPER_TEAM_ID` and `ARRAS_NOTARY_PROFILE` identify
them.

The postprocessor signs a copy and preserves the original build. Exit 75 means
Apple is still processing: retain the work directory and original build, then run
the same command again. Concurrent invocations for that work directory are
rejected. Saved request IDs prevent another upload. An ambiguous
interrupted upload stops for inspection. An unavailable local Keychain profile
stops before upload and can resume after
the profile is restored, without rebuilding or re-signing the frozen app.
Accepted logs must match uploaded hashes; both architectures, signed
entitlements, tickets, Gatekeeper, the exact ZIP/mounted
DMG contents and the Applications shortcut are checked before a new output
directory is promoted. Existing output is never overwritten. Preserve the work
directory until completion; it also supports rechecking completed output.

The tag workflow requires `--require-release-metadata` and uploads only these
verified artifacts. Its appcast checksum comes from the same finalized ZIP.
Reviewed signing/version metadata must match before publication packaging; a
pending result or any failed check stops the workflow before the release steps.
Local `build.sh --release` output remains an ad-hoc development package, separate
from this Developer ID distribution output.

`project.yml` owns project configuration. Generate `Arras.xcodeproj`; do not
hand-edit it. Tests must use injected temporary storage and must never read or
write the user's `~/Library/Application Support/PhotoWidget/` data.
`--ui-testing` also selects per-process temporary storage when its test path is
missing or empty; supply a stable private path for fixtures retained across launches.

Describe what changed, why, and how it was verified. Add focused tests for
behavior, persistence compatibility, update validation, or regressions where
they add meaningful confidence. Final visual, multi-display, desktop Space,
capture, and update behavior may also require manual verification.

## Keep the product contract current

Every change to user-visible behavior must do one of the following in the same
pull request:

1. update the relevant current contract in [FEATURES.md](FEATURES.md), the
   ownership contract in [ARCHITECTURE.md](ARCHITECTURE.md), or trust guidance in
   [SECURITY.md](SECURITY.md); or
2. state in the pull request why those documents remain accurate.

[README.md](README.md) is the concise front door, not the exhaustive contract.
[CHANGELOG.md](CHANGELOG.md) and `release-notes/` are historical release
records; put development changes under **Unreleased** and preserve published
entries. FEATURES documents the version prepared by this checkout.
`product-metadata.json` describes the prepared checkout's product facts; its
publicRelease.version field pins the intended website release version. Published
artifacts, dates, versions and digests come from GitHub Releases and the appcast.

Validate the documentation and public contract offline with:

```sh
python3 scripts/validate_product_metadata.py
python3 -m unittest discover -s scripts -p 'test_*.py'
```

The separate `Public Release Audit` workflow downloads the latest public
artifacts and reports discrepancies; it never edits content or publishes releases.

Code coverage is off in the shared scheme so ordinary Release builds do not
carry test instrumentation. To measure coverage, add `-enableCodeCoverage YES`
to an isolated Debug `xcodebuild test` run; do not use that flag when packaging.
Bundle validation rejects LLVM coverage/profile sections in either architecture
before a release or pilot is packaged.

## Release verification

Before publishing, run the unit and native UI suites with isolated storage and
build the actual Release artifact. Check:

- Settings reuse, closing/minimizing, Stage Manager, Mission Control, desktop
  Spaces, fullscreen transitions and floating-widget order.
- Desktop collage grouping, dragging, proportional
  resizing, extraction, removal and restoration with mixed-ratio images.
- Display disconnect/reconnect, resolution/rearrangement changes, sleep/wake,
  Reduce Motion, Low Power Mode and representative sustained CPU/GPU/memory use.
- Upgrade a copy of an older library, import/export archives, and exercise
  installation, verified updates, failure and rollback in a separate location.
- Verify Photos permission grants, denied/restricted access, opening the correct
  Settings pane, album changes, iCloud downloads and retained offline snapshots.
  Verify Screen Recording permission recovery as well. Enable public telemetry
  only after the route, retention, disclosures and emergency controls pass
  [the activation checks](SECURITY.md#private-pilot-operation).

## Verification evidence

The owner approved the **2.5.0** app, website and `tryarras.tech` domain cutover
on 18 October 2026. This release uses the exact verified local Developer ID
packages under `dist/notarized-20261018/`, with uploaded GitHub digests checked
before updating the feed. The sections below preserve dated development evidence;
their earlier publication holds describe those historical testing rounds.

User acceptance on the notarized sample confirmed Settings reuse, Photos import,
Space-switch menu behavior, Floating visibility, aligned smooth collage movement,
member resizing and dynamic bounds, and menu Undo/Redo. The inactive-app diagonal
resize cursor remains unreliable although resizing works; no invasive focus change
was introduced. No known iCloud-only sample was available for that separate check.

The latest complete 16 October 2026 native unit run completed **425 checks: 424 passed,
one skipped, no failures**, without test-host restarts. macOS did not activate the
synthetic menu-dismissal host. Physical input/Space acceptance remains separate.
The native stacking-menu test now retrieves its own posted click from the event
queue, verifies its target/coordinates and AppKit's current-event metadata, and
retains every tracking/order/geometry/store assertion. An initial diagnostic
incorrectly required object identity for queued events; its eight fixture assertions
failed while the original tracking checks passed. Field comparisons corrected it.
The earlier 0.106-second zero-sample menu interval remains unattributed; its raw
result is retained rather than explained by a passing repeat.

An intervening unisolated run had 22 failed checks and eight test-host restarts
while QuickTime matched enabled live Privacy hiding rules. Private-manifest and
normal-scheme comparisons each passed six relevant checks. The matching-app signal
cleared between environment snapshots, so those comparisons alone do not establish
every failure's cause. The Test action now supplies process-local defaults; the
reconnect regression explicitly verifies its effective hiding flags are disabled.
Saved Privacy preferences remained unchanged. Application source files are
unchanged by this follow-up; only the test configuration changes build provenance.

All 63 focused selection/arrangement/resize/reference checks passed. Two new
regressions first reproduced appearance paste cancelling unrelated drags, resizes
and spacing previews, and overwriting affected interactions (63 failed assertions).
They now preserve native geometry, windows, animation ownership, model/store bytes
and hidden/locked compatibility. Additional retry assertions passed in the complete
run: paste becomes available and saves normally after the affected edit finishes.
Row menus, selection actions and Photo Tools share that eligibility check.

The preceding 50 focused selection/arrangement/resize checks passed. A regression first
reproduced unrelated collage-draft loss for Nudge, Align and Distribute, with both
successful and failed saves (18 failed assertions across six cases). The fix uses
the affected-scene guard instead of globally cancelling edits and scopes native
synchronization. Further cases preserve affected photo/group drags, resize and
appearance drafts for both member and parent selections. The earlier 49 focused
reference/collage/replacement/undo checks also passed; their unchanged regressions
remain in the complete run. They cover reference rotation growing and shrinking
visible/hidden collage bounds, preserved sibling placement and hidden display
profiles, affected move/resize rejection and unrelated edits. The stronger save
failure check retains the whole model, native windows and protected corrupt store
for image and text-only edits. A further native regression covers static, animated,
slideshow and grouped photos: unchanged Apply and note/source-link saves retain
the original window/view/media, placement and completed resize undo/redo.
The preceding slideshow/runtime and return-motion checks also remain in the
complete run, including an actual elapsed timer held through an individual resize
and normal advancement after release.
Earlier picker, native-menu and test-cover failures remain unattributed and their
raw results are retained; passing subsets do not explain them. At that earlier stage, the candidate was not release-accepted. These checks cover native handlers, WindowServer order,
persistence, media, imports/recovery, telemetry and updater behavior; they do not
establish physical mouse, Space/display, VoiceOver, battery or full public updater
acceptance. The preceding capture-privacy wording and caution-icon update passed
one focused native SwiftUI Settings owner/reuse check and produced four own-view
renders at two widths in light/dark appearance; the narrow light and wide dark
renders were visually reviewed. The current complete run includes that Settings
regression; the reference fix did not change the Privacy view.

| Current evidence | Authoritative record |
| --- | --- |
| Latest 2.5.0 status-menu ordering, native Undo/Redo icon row, consistent Privacy help and package evidence | `/tmp/arras-status-menu-polish-20261016/privacy-copy/result.json` |
| Preceding on-demand app star count and privacy disclosure | `/tmp/arras-app-stars-20261016/result.json` |
| Website download attribution and preceding GitHub actions | `/tmp/arras-download-polish-20261016/result.json` |
| Preceding menu-event test setup and process-local Privacy test configuration | `/tmp/arras-menu-tracking-investigation-20261016/regressions.json` |
| Latest complete native result and adjacent log/raw bundle | `/tmp/arras-menu-tracking-investigation-20261016/complete-isolated-summary.json` |
| Preceding appearance-paste fix, reproduction and native results | `/tmp/arras-appearance-gesture-polish-20261016/regressions.json`; retains the unresolved earlier full-run menu failure and separate diagnostic result |
| Preceding selection-draft fix and verified package | `/tmp/arras-selection-draft-polish-20261016/regressions.json` |
| Preceding reference-fix artifact identities, subsystem evidence and cleanup chain | `/tmp/arras-reference-metadata-polish-20261016/verified-package.json` |
| Privacy Settings check, own-view renders and local website scope | `/tmp/arras-capture-privacy-polish-20261016/regressions.json` |
| Latest compiled universal Release and ad-hoc ZIP/mounted-DMG contents, Photos entitlement and no-LLVM-coverage checks | `/tmp/arras-status-menu-polish-20261016/privacy-copy/release.log` |
| Latest Developer ID 2.5.0 app/DMG acceptance, tickets, platform policies and final packaged copies | `dist/notarized/Arras.notarization.json` and `/tmp/arras-status-menu-polish-20261016/privacy-copy/notarization.log`; retains previous fixes and adds native status-menu history icons/consistent Privacy help; no fresh-Mac launch or app publication |
| Separately authorized 2.4.9 website copy at tryarras.tech, with both addresses active | `/tmp/arras-domain-migration-20261016/final-hosting-state.json`, `normal-public-verification.json` and `live-source-record.json`; old Arras/portfolio/CV deployment unchanged; no 2.5.0 publication |

`dist/Arras.app` points to `build/current/Release/Arras.app`. The current build
protects individual photo gestures from automatic or manual slideshow advancement,
using the existing affected-scene guard and removing its narrower predecessor.
Reference edits use that guard and save member geometry with the enclosing
collage before native replacement; failed saves restore the complete model.
Notes/source-only edits save without media decoding, window replacement or collage
refitting; unchanged Apply returns without a write. The regression reproduced the
earlier native replacement and grouped placement/history damage before this fix.
It retains the Photos-media, linked-folder, Photos-album wait, UI-test storage
and Saved Setup fixes. Manager-lifetime and menu
follow-ups changed only tests/documentation. Receipt chains retain exact
source scope, failed attempts, fixture corrections and superseded-result cleanup.

Privacy now describes screen-capture exclusion as a compatibility request, with a
caution to hide widgets before sharing if they must stay private. Apple documents
[`NSWindow.SharingType.none`](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none)
as a legacy value, not a supported capture-protection guarantee. Existing controls,
stored preferences and section surfaces are retained. Native flag assertions and
own-view renders do not establish compatibility with real capture applications.

On 16 October, the user authorized refreshing the isolated Photos sample. The
exact notarized ZIP with source digest `016f24b32f6d` was validated and launched
through macOS with explicit scratch storage, preserving the original app and a
post-quit library backup. The user confirmed that Cmd+, reopens and reuses one
Settings window and that the real sample-only Photos picker/import works. Evidence
is retained in `/tmp/arras-notarized-sample-20261016-yvpz5b0n/menu-refresh-20261016/previous-refresh.json`. This does not
cover later source changes, collage acceptance or iCloud-only media. The installed
Applications copy has not been replaced. Numerical benchmarking stopped at the
user's request on 15 October.

The GitHub-action follow-up changes only `AppActivation`, `AppDelegate`,
`Constants` and `PreferencesView`. Its signed designated requirement, entitlements,
bundle identifier and Photos usage description match the human-checked sample;
the picker, Photos-resource and import/model sources are unchanged. Source/identity
comparison is recorded at
`/tmp/arras-launch-copy-20261016/acceptance-source-scope.json`, alongside the
current focused native Settings regression. This retains the earlier human
checks with their original scope; it is not another physical run or evidence for
iCloud-only/revoked-access recovery.

### Native interaction and Settings

Native checks cover independent photo movement/resizing, hover-only grips, live
collage-boundary growth/shrinkage, alignment guides, group transforms, inherited
depth/Space behavior, retained standalone preferences and editable member
appearance. Undo/redo sit immediately left of Tools. A 100-step background drag
preserves models/data without repeated member layout or restacking. Absolute panel
placement and native followers address screen constraints/origin drift; followers
detach on release, cancellation, menu interruption and rollback. These are scoped
native checks, not proof of physical smoothness or Space switching.

| Checked scope | Evidence |
| --- | --- |
| Deferred double-clicks require the original visible panel/view; hidden callbacks cancel | `/tmp/arras-collage-teardown-polish-20261016/` |
| Retained closed panel releases its material tree after removing duplicate strong surface ownership; independent AppKit/SwiftUI controls | `/tmp/arras-material-ownership-scope-20261016/controlled-comparison.json` |
| Manager-removal probe discrepancy explained by creation-time autorelease scope, across four skins; corrected regression retains independent photos | `/tmp/arras-manager-teardown-followup-20261016/regressions.json` |
| Context-menu ordering through own-process AppKit dispatch, desktop/floating and locked/unlocked; all eight comparison cases valid while host inactive | `/tmp/arras-menu-observation-followup-20261016/regressions.json` |
| Rounded sections on all three Settings tabs, light/dark, at minimum width | `/tmp/arras-settings-sections-review-20261014/` |
| Real SwiftUI adaptor registers the live owner; Settings action opens/reuses its window; intent persists in scratch storage | `/tmp/arras-runtime-owner-fixed-20261015.log` |
| Update/failure notification clicks reuse Settings and reveal Updates in its actual scroll viewport; dismissals remain inert | `/tmp/arras-update-notification-polish-20261015/` |

The earlier full-suite menu failure remains unattributed: tracking began, but the
Desktop/unlocked case collected no ordering samples. Unchanged repeats passed.
The newer dispatch comparison separately corrected clicks sent to the pre-drag
point outside the moved window; those misses never began tracking. It does not
explain the historical failure. The strict ordering assertions remain, with
failure-only event, timer, activation and run-loop context. Original evidence:
`/tmp/arras-slideshow-transaction-polish-20261015/initial-full-summary.json` and
its `final.xcresult`/log.

The user accepted smooth movement, ordinary desktop-Space menu opening/dismissal
and Floating visibility with Settings in the deliberately edited two-member sample
on 14 October, then returned it to Desktop depth. That is acceptance of that
sample/candidate, not the later package, hidden/larger collages or other displays.
On 16 October, the user separately accepted the preserved five-widget sample on
the current notarized `25750ee2e1d6` build: ordinary desktop-Space switching/menu
behavior, Floating visibility with Settings, aligned photos/backdrop/caption,
smooth background dragging/member resizing and boundary growth/shrinkage. They
explicitly confirmed testing the collage's own Floating setting and member resize,
then returning to Desktop. Both libraries were backed up before the authorized
switch; subsequent sample edits remain intact. The position-only capture contains
595 own-window snapshots, covering photo movement/detachment and boundary refitting,
with the caption host contained within its backdrop host throughout. It did not
capture the Floating collage or a member size change; those checks are human
evidence. A final on-screen metadata query confirmed caption above the remaining
member above the backdrop at Desktop depth. The all-window query gave a different
order and is not used as stacking evidence. No pixels or unrelated window details
were recorded, and sampled geometry is not a smoothness or battery measurement.
Evidence: `/tmp/arras-collage-acceptance-20261016-4f953rt8/acceptance.json` and its
`switch-20261016/capture-summary.json`/raw capture.
Native UI automation covered tab navigation and creation/appearance/preset
controls; caption/setup typing and desktop drag/drop lost input or timed out.
An AppleSpell deadlock was observed without establishing causation. Physical
Cmd+, Shortcuts, VoiceOver and inactive-app cursor appearance remain unverified.
Own-view Settings captures do not prove a private notification emitter's state
appeared in the shared updater view. Pointer tracing is retained for failed UI
mouse delivery, not as a production logger.

The closed-editor model lifetime fix is separate from the later movie-test stall.
Tracing suppressed 819 inferred widget-ordering transforms while retaining 231
explicit collage transitions; ordinary and traced repeats passed afterward.
Security responsiveness warnings were isolated to the synthetic `AVAssetWriter`
fixture, and the priority warning to a deliberately held import-test semaphore.
No diagnostic appeared during that short clip's production prepare/load stages;
this does not establish responsiveness for every media file. Tracing was removed.
Evidence: `/tmp/arras-animation-origin-20261015/` and
`/tmp/arras-video-warning-origin-20261015/result.json`. Neither is Release energy
or battery proof.

### Imports, Photos and recovery

The current suite checks durable-save-before-runtime behavior, preserving models,
media, windows, playback and history after failed saves. Implementation contracts
belong in [ARCHITECTURE.md](ARCHITECTURE.md); initial failures, source comparisons
and fixture corrections remain in the following scoped records.

| Regression scope | Evidence |
| --- | --- |
| Native individual standalone/member gestures keep slideshow media/data/Undo intact while unrelated playback continues; actual elapsed rotation preserves a held resize and resumes after release; return-motion fixture retains its original advancement check after settling | `/tmp/arras-slideshow-gesture-20261016/regressions.json` |
| Unchanged Photos refreshes preserve native media, placement and completed move/resize history; metadata still saves and absent windows respect all visibility guards | `/tmp/arras-photos-unchanged-media-20261016/regressions.json` |
| Actual temporary-folder reconciliation preserves affected edits, latest slide/name, unchanged native media and resize undo; cancellation cleans staged files; changed bytes prepare off-main; failed statuses roll back and retry | `/tmp/arras-live-folder-polish-20261016/regressions.json` |
| Completed Photos snapshot commits preserve affected move/resize/appearance edits and unrelated scenes; cancellable waits keep latest edits and reject changed sources; failed saves retain native media | `/tmp/arras-photos-refresh-gesture-20261016/regressions.json` |
| Missing/empty UI-test paths select private storage; explicit/configured paths and normal launch policy retain precedence; three actual manager processes run with personal storage denied | `/tmp/arras-test-storage-isolation-20261016/regressions.json` |
| Add/backup merge and overlapping successful imports retain existing playback, drafts, native ordering and gesture/undo ownership | `/tmp/arras-additive-import-polish-20261016/regressions.json` |
| Replacement commits media identity/fitted geometry before runtime changes; hidden/member/setup restoration; affected edits retry while unrelated gestures survive | `/tmp/arras-replacement-transaction-polish-20261016/` and `/tmp/arras-import-drag-polish-20261016/` |
| Removal recovery merges current members/bounds without rebuilding unrelated scenes; runtime restoration installs the permission-aware Photos observer | `/tmp/arras-removal-recovery-polish-20261016/` |
| Stale/failed removals preserve drafts; affected edits wait; unrelated recovery previews and history survive | `/tmp/arras-recovery-preview-polish-20261016/regressions.json` |
| Failed Saved Setup/recovery/active-store writes preserve gestures; temporary failures retain completion/undo, damaged stores retain corruption protection | `/tmp/arras-setup-transaction-polish-20261016/regressions.json` |
| Name/action rollback, independent duplicates and hidden slideshow snapshots/offsets | `/tmp/arras-photo-controls-polish-20261016/` and `/tmp/arras-duplicate-polish-20261015/` |
| Settings-width geometry through hidden/setup/display-profile restoration; source bytes and appearance preserved | `/tmp/arras-settings-width-polish-20261015/` |
| Extreme slideshow intervals/indices, failed playback/control saves and unreadable Next/Previous media | `/tmp/arras-timer-edge-review-20261015/` and `/tmp/arras-slideshow-transaction-polish-20261015/` |
| Visibility, opacity/reveal/native scroll, depth, Space pinning and WindowServer stacking save rollback | `/tmp/arras-visibility-save-polish-20261015/`, `/tmp/arras-fade-visibility-polish-20261015/` and `/tmp/arras-placement-save-polish-20261015/` |
| Stale imports after desktop replacement, media-identity races and one common SwiftUI Photos-picker observer | `/tmp/arras-import-lifecycle-before-20261015.log`, `/tmp/arras-replacement-race-before-20261015.log` and `/tmp/arras-picker-observation-20261015/result.json` |

Recovery retains fonts even when the active store was missing, avoids stealing
children moved to another collage, and preserves imports/generation/history.
Real Photos refresh after introducing a source through setup/recovery remains
manual acceptance. Fixture corrections include deterministic JSON ordering,
native view-height rounding, real bundled media and temporary scratch-file write
restrictions. A corrupted active store intentionally remains protected; replacing
its bytes alone was not treated as a transient-write retry.

Photos fixtures cover edited photo/video resource preference, compatible cache
metadata, retained snapshots after failed downloads, empty/relink-state rollback,
cancellation/progress teardown and `.arras` bytes without source identifiers/cache
markers. A native-button regression captures an accepted album in Sync before
selection can change. The older intermittent nil-selection trigger remains
unattributed; passing repeats do not explain it. A 16 October recurrence showed
the native row disappearing and Sync becoming disabled while the picker and host
were active; a bounded six-attempt follow-up passed. That full run also failed
to observe its own test cover in one WindowServer snapshot. Both raw failures
remain in `/tmp/arras-live-folder-polish-20261016/`; failure-only diagnostics were
added without weakening the original assertions. A bounded three-pass follow-up
ran 48 unique Photos/folder/import tests for 144 successful executions without
reproducing the picker failure:
`/tmp/arras-picker-callback-followup-20261016/bounded-result.json`.
A later private AppKit comparison found that the test cover's nonactivating panel
style already had `hidesOnDeactivate == false`; both compared panels appeared in
on-screen metadata. Its requested deactivation did not produce a resign event,
so this does not explain the historical absence or prove deactivation behavior.
No app or fixture flags/assertions changed. Evidence:
`/tmp/arras-cover-activation-20261016/result.json`.
Evidence for the older chooser:
`/tmp/arras-photos-chooser-selection-20261015/` and
`/tmp/arras-photos-status-clean-20261015.log`. These fixtures do not prove edited
real albums or iCloud-only downloads. Resource semantics follow Apple's
[edited photo](https://developer.apple.com/documentation/photos/phassetresourcetype/fullsizephoto)
and [edited video](https://developer.apple.com/documentation/photos/phassetresourcetype/fullsizevideo)
documentation.

The user confirmed a real **From Photos Collection** sample-album widget on
15 October; the earlier Examples/slideshow result was excluded. A renamed QA copy
first lost its entitlement/Hardened Runtime, then direct executable launch assigned
Photos responsibility to Codex. Restoring signing settings and opening the same
copy through LaunchServices resolved denial with scratch storage preserved. The
original Release kept its entitlement guard. Evidence:
`/tmp/arras-photos-acceptance-20261014/`. Use normal launches; leave unrelated
permissions and personal media alone.

### Updates and compatibility

The full suite covers selected cadence/mode rechecks at async boundaries,
notification acknowledgement only after accepted delivery, Never cancellation and
manual-check availability. Automatic installation waits for Settings/editors,
imports, gestures, return motion and drafts, then rechecks after verification.
Private substitutes do not establish native banner/permission UI.

| Integration scope | Evidence and limits |
| --- | --- |
| Official 2.4.9 ZIP checksum/signature; tagged helper replaces a temporary real 2.4.9 executable with 2.5.0, and current helper restores/relaunches 2.4.9 after failed health | `/tmp/arras-public-migration-check/healthy.log` and `/tmp/arras-public-migration-check/rollback.log`; helper paths, not complete public delivery |
| Current/tagged updater, unchanged helper, LaunchServices health and 114 legacy fields/bundled bytes through private restart | `/tmp/arras-updater-integration-20261014/current-result.json` and `/tmp/arras-updater-integration-20261014/legacy-result.json`; tagged driver recompiles updater source, three widgets hidden, transient presence/display flags excluded |
| SwiftUI owner, startup, synthetic wake/activation, Settings/import deferral and resumed private installation | `/tmp/arras-swiftui-updater-integration-20261015/result.json`; fixture state, not hardware wake, real import or elapsed cadence |
| Native Check Now/Try Again/Update actions, private failure/retry, available/downloading/installing views and restart preservation | `/tmp/arras-updater-controls-integration-20261015/result.json`; private URL protocol/component views, not physical input, atomic progress-label timing or full installed Settings |
| Actual 900-second retry timer with 60-second tolerance: 503 then success after about 960 seconds | `/tmp/arras-scheduled-timer-20261015/result.json`; current updater body plus Combine import/support stubs, no manual fire/wake/activation, one interval rather than all cadences |
| Real public HTTPS feed and official 2.4.9 ZIP through current native controls and original verification | `/tmp/arras-public-network-updater-20261015/steady/result.json`; simulated 2.4.8 fixture refuses at helper entry before swap/script/downloaded-code execution; work/breadcrumb cleanup verified |
| Earlier notarized 2.5.0 ZIP archive preparation, off the main thread | `/tmp/arras-notarized-updater-preparation-20261016/result.json`; exact candidate bytes/ticket/Gatekeeper preserved; bad checksum, wrong version, damaged signed resource with matching archive checksum and malformed ZIP rejected; no feed, replacement, app launch or Photos permission check; later arrangement and appearance fixes leave the updater unchanged |

All integrations used unique identities and private storage. Recorded source
hashes and unchanged-path comparisons bind each result to its stated scope; later
changes have native regressions rather than a repeated full delivery run. The
first public-control fixture had two transitional buttons; disabling animations
only in its own host transaction made the actions unambiguous. No system setting
changed. Real installed controls, public replacement/restart, representative
visible-library playback, physical input and VoiceOver remain open. Do not publish
a test release or change the public feed to satisfy them.

### Telemetry and website

[SECURITY.md](SECURITY.md#telemetry-protocol-and-activation) owns the exact protocol,
retention, capacity models and activation rules. Public 2.5.0 is configured for
limited weekly reports; installation-linked buckets/milestones exclude photos,
filenames, paths and layouts. They are not a live-online-user counter. Server
changes remain local/undeployed; only the monitor reader was updated earlier.

The local operator dashboard now opens with `~/bss.sh`: GitHub, website and app
statistics share one page and completed UTC date ranges. `R` refreshes sources;
`1`, `7`, `2`, `M` and `A` select yesterday, 7/14/30 days or recorded history.
`D`/`W` show daily/sequential seven-day trends, and `Q` exits. `--once` prints a
snapshot; `--cached` avoids network checks; `--export-history PATH` exports the
aggregate-only SQLite history without replacing an existing file. History is
collected when the dashboard runs; the existing app watcher remains independent.
Website totals explicitly include the shared portfolio project because the
provider API cannot isolate historical Arras hostnames. GitHub asset requests
are not installs, and app reports are not active-user counts. Download-route
logging remains unpublished. The existing credentials, notification helper and
services were preserved, with the previous launcher backed up. The installed
follow-up covers UTC rollover of cached visitor uniques, unknown current-day app
totals, gaps in trends and a quit/refresh race. All 27 focused monitor/dashboard
checks passed, along with a real read-only source refresh, PTY date/view controls,
idle resizing and terminal restoration. Its exported SQLite history passed the
integrity check, contains only aggregate columns, and has private file permissions.
Evidence and installation receipts are in `/tmp/arras-unified-telemetry-20261016/`.
Android archival work is deferred. The unpublished silent launch film is now
finished locally in `~/Arras Launch 2.5.0/Desktop Film/`: `Arras-2.5.0-Launch.mp4`
and the matching self-contained editable `.tsrct`. The 10.4-second, 2940 × 1912,
30 fps export preserves the user's real two-photo join/Lock opening, then cuts
through six actual Desktop 2 screenshots for each of YOUR / OWN / WORLD and a
clean final desktop with only the Arras logo widget, ARRAS and tryarras.tech.
The unchanged 9.96-second source recording, original sample library and restore
archive remain preserved. Normal native imports and explicitly authorized System
Events control were used; these are real full-screen captures, not composed UI
mockups. Settings kept its x8/y40, 480 × 684-point capture position. Three early
captures with photos not yet visible were replaced and visually reviewed after
native drawing settled. All 312 exported frames decode; all 198 montage/finale
frames match the intended captures in order, with no unexplained black frames
and decoded audio peak zero. The project's filmstrip and exported pictures were
inspected; the identical initial upscale played to completion in QuickTime.
The final native-size copy was separately decoded, matched and inspected. Four
unaltered Retina stills are in `Stills/Native Desktop/`, with rights and sources
in `Assets/` and `Fonts/`, and provenance/export checks in the existing working
folder. The unnecessary upscale and staging duplicate were removed. Personal
storage, original footage and dirty repositories were preserved. No publication
is authorized.

| Checked scope | Evidence and limits |
| --- | --- |
| Privacy allowlists, weekly UTC cadence, bounded queues, immutable attempted payloads, corruption validation and persistent capped backoff/reset | `/tmp/arras-telemetry-state-polish-20261015/`; pre-fix weekly arithmetic crash reproduced, damaged state now rejected without rewriting photo/telemetry files |
| Six-week calendar-month reporting bound: 30 native starts/60 flushes, six November 2026 deliveries and same-week suppression | `/tmp/arras-telemetry-calendar-check-20261016/result.json`; exact native source with fixture dates/stub transport, no network or system-clock changes; corrects the earlier five-report monthly capacity assumption, not reporting behavior |
| Ten handler/Redis and thirteen monitor checks; atomic commit/replay, deduplication and expiry repair | `/tmp/arras-scheduled-updates-20261015/telemetry-handler-redis.log`, `/tmp/arras-transport-polish-20261015/result.json` and `/tmp/arras-telemetry-runtime-failure-20261014/`; local/provider prototypes, not production billing |
| 18 native starts across emulated Redis quota failures and actual local Lua 429 rejection, with frozen payloads/relaunch/backoff/recovery/retention | `/tmp/arras-telemetry-quota-relaunch-20261016/`; fixture dates, not six/twelve elapsed hours or provider monthly enforcement |
| 16 native transport starts: 4 KiB boundary, oversized/unfinished streams, redirect refusal, cookie/cache isolation, real timeout and cancellation/relaunch recovery | `/tmp/arras-telemetry-transport-check-20261016/`; private loopback, no production traffic; retry dates injected |
| Read-only signed-in provider checks on 15–16 October: Free Tier/500,000 monthly commands and advertised HSETEX/HEXPIREAT availability | `/tmp/arras-production-telemetry-review-20261015/result.json` and `/tmp/arras-production-telemetry-capabilities-20261016/result.json`; no ingestion/expiry writes, credentials/records, plan changes or population-level billing proof |
| Existing monitor cache after its successful 16 October 17:01 UTC aggregate read: two 2.5.0 configuration reports and one first-run event dated 16 October, in addition to two 2.5.0 configuration reports dated 9 October; the earlier 09:15 read had only one report for 16 October | `/tmp/arras-notary-pipeline-20261016/natural-telemetry-observation-latest.json`; original observation retained separately; anonymous aggregate observation, no forced network/Keychain access or synthetic traffic; not an online count, individual attribution, returning-weekly-client proof or quota/expiry verification |

The provider reported Redis 8.4.0/Upstash 1.18.1. An earlier empty `COMMAND` catalog
or `COMMAND INFO` argument error was compatibility behavior, not proof of missing
commands. Required command availability is verified; production ingestion/expiry,
topology, monthly usage and quota behavior for 1,000–5,000 Macs remain open. Existing
minute/day gates do not enforce the monthly allowance. No synthetic production
capacity traffic, credential-access bypass or paid upgrade is authorized.

The local website now prepares the eventual **2.5.0** feature guide, universal
compatibility, metadata and weekly-statistics disclosure. Existing navigation and
compatibility anchors remain. Six feature cards and the workflow cover editable
collages, linked collections, reference tools, appearance copying, setups and
recovery. Installation, FAQ/schema and both privacy pages share signing facts.
The 16 October download follow-up adds a fixed, uncached local 302 to the official
GitHub DMG, per-tab first-source attribution and bounded source/browser-category
events in Runtime Logs, separate from app statistics. HEAD/prefetch requests are
excluded and recognized bots are marked; these are request counts, not unique
humans or completed downloads. Privacy describes the session storage and log
scope. Repository links send only their origin; server-rendered GitHub star badges
refresh hourly and remain usable when GitHub is unavailable. Preferences and the
application menu also offer Star on GitHub. Preferences now reads the public count
on appearance or Settings focus, sharing concurrent requests and caching successes
and failures in memory for an hour. There is no separate launch request or polling
timer. Cookies, credentials and disk caching are disabled; an unavailable count
leaves the link usable. App Privacy and both website privacy pages disclose this
separate public metadata read.
All 26 focused website checks, 25 local production HTTP checks, the production
build, product/AEO/SEO checks and 102 legacy redirects passed. The HTTP audit first
caught one missed GitHub documentation-link policy, which was corrected and added
to the existing SEO guard. The existing native Settings command/reuse regression
passed once on source `c734684cd753`; the complete 425-test result above belongs
to its predecessor. The subsequent app-counter revision (`61c3e4a1c0db`) passed
six focused store/native-transport checks plus that Settings owner/reuse check.
These cover shared requests, hourly success/failure caching, clock correction,
invalid/negative/zero counts, cancellation and the 64 KiB response boundary. The
unchanged native counter source also fetched the real public count, then reused
it without another request. This is transport/cache evidence, not a physical star
click or rendered-count check. The updated website passed its 26 focused checks,
product checks, production build and four compiled privacy-page checks across both
Arras hostnames. Earlier unchanged download/SEO/redirect checks were not repeated.
Browser interaction and production event delivery remain untested for the new
website flow. The public 2.4.9 sites were not deployed.
The subsequent status-menu revision (`1620c162dcc6`) groups Add/Widgets and global
visibility first, then native horizontal Undo/Redo icons and removal recovery,
then Settings/Options and Quit. Context-menu text commands and Photos-toolbar
icons remain available. Three focused checks passed for the native icon actions,
key-equivalent dispatch, history availability/accessibility/help, Add commands
and effective collage-depth badges. The earlier Shift-key fixture constructed
inconsistent native event fields, and the first badge assertion queried a menu
that its fixture had not built; their raw results remain with the corrected
checks. Neither required a production shortcut change. The comparison changed
only `AppDelegate.swift` and `ArrangementHistory.swift` in app build inputs;
collage, Photos, updater and telemetry runtime sources are unchanged.
The user's general report that tried behavior looks good is retained without
attributing every outstanding gate or the new menu presentation to that report.
The user's later icon-row appearance/action acceptance is recorded below;
physical keyboard shortcuts and VoiceOver still require acceptance.
Evidence: `/tmp/arras-status-menu-polish-20261016/checks.json`.
The universal release and finalized Developer ID ZIP/DMG passed exact-content,
ticket and platform checks, with separate Apple app/DMG acceptance and no reported
issues. The preceding signed package remains available for rollback. Compiler/
probe caches and completed duplicate staging/upload files were then removed:
689,889,280 allocated file bytes, a 649,560,064-byte observed free-space increase,
and 171 protected file hashes unchanged. All raw focused results, logs, signed
work apps and sample libraries remain. Package/cleanup evidence is consolidated
in `/tmp/arras-status-menu-polish-20261016/result.json`. A final copy-only review
found the Privacy submenu still promised guaranteed capture exclusion, unlike
the existing Privacy Settings page. Its label/help now describes a compatibility
request, its call-app label includes recording apps, and fullscreen help names
the existing detection limit. Six exact text/comment substitutions were verified;
control flow, settings keys/actions and every other app build input are unchanged.
No additional subsystem tests were written or repeated for these wording edits.
The copy-only candidate (`25750ee2e1d6`) completed fresh universal ZIP/mounted-DMG
verification, Developer ID signing, separate Apple app/DMG acceptance with no
reported issues, ticket and platform-policy checks. Its compiler cache and
completed duplicate staging/upload files were removed: 337,772,544 allocated
file bytes, a 302,956,544-byte observed free-space increase, and 168 protected
file hashes unchanged. Signed apps, archives, evidence and sample layouts remain.
The final copy/package record is
`/tmp/arras-status-menu-polish-20261016/privacy-copy/result.json`.
The user then authorized refreshing the isolated Photos sample while preserving
its layout. It was gracefully quit, its latest library backed up after shutdown,
and the exact finalized signed ZIP launched through `NSWorkspace.openApplication`.
The running sample now uses `25750ee2e1d6`; all 13 library files, including both
saved widgets, matched the post-quit backup exactly. The previous bundle and
historical acceptance record remain available. Signature, ticket, platform policy
and current-source checks passed before replacement. Physical acceptance of the
new icon row was then confirmed by the user: it looks right, and Undo/Redo
correctly reverse and reapply a widget move. Physical keyboard shortcuts and
VoiceOver were not part of that confirmation. The separate collage acceptance
copy was unchanged.
Evidence: `/tmp/arras-notarized-sample-20261016-yvpz5b0n/menu-refresh-20261016/refresh.json`.
After the preceding counter verification, the task-owned preview was stopped and its
temporary source/build copy, compiler cache and probe/module cache were removed.
Allocated file bytes removed totalled 876,597,248; observed free space increased
by 863,604,736 bytes. All 369 protected file hashes remained unchanged, including
101 app build inputs and 229 website source files. Current packages, sample apps/
libraries, original source backups and native results/logs were retained;
`/tmp/arras-app-stars-20261016/cleanup.json` records the exact scope. The running
Photos sample and unlaunched collage copy were left unchanged during that cleanup
because the user deferred hands-on testing. The subsequently authorized Photos
sample refresh is recorded above; the separate collage copy still awaits its own
acceptance round at that point. The five-widget copy was subsequently updated
from the exact finalized `25750ee2e1d6` ZIP after source, signature, ticket and
platform-policy checks, preserving both libraries and the preceding bundle.
The user then authorized the switch and accepted the scoped physical checks
recorded under Native interaction above. The Photos sample is stopped, with its
latest post-quit library backup retained; the edited collage sample stays open.
Evidence: `/tmp/arras-collage-acceptance-20261016-4f953rt8/acceptance.json`.
Apple accepted the latest 2.5.0 app and DMG, including the appearance-paste and
arrangement-draft fixes, GitHub actions, Preferences star count, native status-menu icons
and consistent Privacy menu help,
with no reported issues. Separate packaging checks verified both
architectures, signed entitlements, Hardened Runtime, stapled tickets, Gatekeeper
and the exact ZIP/mounted-DMG contents. The current receipt is
`dist/notarized/Arras.notarization.json`; the preceding signed packages remain
preserved at `/tmp/arras-status-menu-polish-20261016/privacy-copy/previous-notarized/`;
the preceding counter revision is at
`/tmp/arras-status-menu-polish-20261016/previous-notarized/`. The older
GitHub-action revision remains at `/tmp/arras-app-stars-20261016/previous-notarized/` and the
appearance/menu-test revision remains at
`/tmp/arras-download-polish-20261016/previous-notarized/`.
The preceding revision initially stopped at a missing local Keychain profile,
before receiving an Apple request ID. After the user restored that profile, its
same frozen signed archive completed notarization without another build or
signature. That test-configuration revision then completed the workflow
normally; its application source matches the preceding appearance revision.
The later GitHub-action revision completed separate app/DMG acceptance with no
reported issues.
Twenty-seven postprocessor checks cover interrupted/resumed requests, changed
archives/source, concurrent runs, rejected results and completed-output recovery.
The gated release workflow has not run; its runner identity, Keychain profile and
repository variables still need configuration before authorized publication.
These checks do not establish first launch on a fresh Mac or Photos permissions
after the signing change. All 71 build/release script checks passed together after
the pipeline and metadata changes. Local metadata now records Developer ID/notarized
distribution and removes obsolete Open Anyway guidance from this website version.
Fourteen site product checks cover current and legacy installation wording,
inconsistent signing claims, stale remote metadata and existing URL safeguards.
Twelve app metadata checks also pass: Developer ID facts may describe pending or
completed notarization, while a notarized claim requires Developer ID signing.
These metadata checks are distinct from the actual package checks above.
Their fixtures copy only
the required configuration/documents rather than the entire working folder.
The supported webpack production build and explicitly local product/AEO/SEO
checks passed with 24 FAQ entries and 102 redirects. Desktop/mobile home layouts
and desktop FAQ interaction were reviewed. Evidence is in
`/tmp/arras-site-250-polish-20261016/` and
`/tmp/arras-notarization-20261016/` and
`/tmp/arras-notary-pipeline-20261016/`. The latter build uses a separate scratch tree
and preview port, preserving the original preview the user is reviewing.
An initial scratch build omitted the shared components directory; adding the
unchanged source directory fixed that fixture error. No production fix was needed.
The default Turbopack build failed a subprocess port-binding restriction; its log
is retained. The initial default checker queried public pages and found existing
`/faq` and `/security-privacy` route expectation mismatches. Local passing checks do
not fix those live responses, and nothing was deployed. Earlier checks covered
28 anchors and 14 local assets (`/tmp/arras-polish-site-20261015/result.json`).
The earlier 99 performance/100 other Lighthouse scores and HTML reduction from
291 KB to 53 KB are historical local results, not final-asset or public guarantees.
Direct HTTP checks on
15 October confirmed the 2.4.9 feed/checksum and no-app-telemetry disclosure;
homepage HTML did not prove its rendered version badge
(`/tmp/arras-public-state-20261015/result.json`). Read-only 16 October checks again
confirmed public **2.4.9** feed/artifacts, `/faq` returning 404 and
`/security-privacy` redirecting to `/security`. The official 2.4.9 ZIP matches its
published digest and contains both `arm64` and `x86_64`; old website Intel-source-only
wording was inaccurate. Public content and artifacts have not been changed.

Launch drafts in `~/Arras Launch 2.5.0/` were checked against current features;
the shot list includes adding/removing members, independent resizing/guides and
unobscured desktop results. On 16 October, both existing Reddit drafts were updated
to tryarras.tech with Reddit source attribution, short feature lists, accurate
weekly/milestone-statistics disclosure and Developer ID/notarized download facts.
The obsolete ad-hoc-signing claim was removed. Only the planned video end-card
domain changed; video remains deferred. October 9 captures are now explicitly
marked as older review assets that predate later interaction/Settings changes.
Evidence and original source backups are in
`/tmp/arras-launch-copy-20261016/result.json`. Earlier statistics boundaries and historical-score
labels were corrected (`/tmp/arras-launch-copy-polish-20261015/result.json`). No
posting/recording/publication occurred. Video remains deferred; final screenshots,
media, community rules and final-site Lighthouse acceptance remain open.

### Historical resource observations and cleanup

Further numerical tests are deferred. These historical intervals use different
candidates/workloads and exclude WindowServer, GPU/decoder-helper energy, battery
discharge and physical-interaction acceptance. They are not marketing claims.

| Earlier observation | Result and scope |
| --- | --- |
| Settled 55 seconds, five widgets and Settings visible, candidate `ea4d9f1b8bdc` | 0.200% of one core; physical footprint about 52 MiB, peak 56 MiB; sampled RSS 13.9–14.4 MiB excludes compressed pages |
| Three animated widgets in a shared test host, visible/covered/hidden/resumed | About 0.59%/0.70%/0.07%/0.52% of one core; peak RSS about 545 MB; includes test infrastructure and retained fixtures |
| Earlier Release renderer-only synthetic H.264, 640×360 at 24 fps, shown at 340×191 | 2.435% of one core; Settings closed, no full UI or energy comparison |

The earlier 7.8% settling interval did not establish a cause. The 9.76% and
moved/removed-movie intervals included intentional human edits and are excluded
from controlled comparisons. Sparse drag geometry/stack captures are not frame-rate
or smoothness proof; lower placement-call latency did not improve the six-panel
experiment's CPU time. The stopped graphics comparison is not completed attribution.
Earlier bundle/ZIP sizes are storage observations, not energy conclusions; current
sizes/digests come from the package receipt. Scope:
`/tmp/arras-cpu-audit-20261013/` and
`/tmp/arras-release-performance-20261014/scope.json`.

The initial cleanup removed 56 generated and 225 empty test directories, recovering
9.94 GiB with all 6,491 recovery files unchanged. Subsequent cleanup records
preserve exact allowlists, allocated sizes, observed free-space deltas and retained
source/result identities. The latest broader inventory removed 20 superseded
passing bundles and five obsolete build/cache/package paths: 1,374,007,296 allocated
bytes and a 1,361,870,848-byte observed free-space increase; all 41 protected
source/diff/log snapshots and 29 failed/ambiguous/visual bundles were preserved.
Evidence: `/tmp/arras-generated-output-cleanup-20261016/`. Per-round receipts are
linked from the current verified-package record.

Keep the current package, useful sample libraries and evidence needed for unresolved
failures, together with all recovery sources/media. Personal
`~/Library/Application Support/PhotoWidget/` stays untouched. The quota/transport
fixtures removed their compiled copies/caches after success. A stale Redis server
was stopped only after identity, empty databases, absent other clients and disabled
persistence were verified; no keys/files were deleted. Evidence:
`/tmp/arras-telemetry-quota-relaunch-20261016/stale-process-cleanup.json`.
The notarized-updater preparation fixture also removed its passing extracted
copies, corrupt archives, test executable and compiler cache: 381,603,840 allocated
bytes, with all four existing packages and the signed candidate unchanged.
Its source, outcomes, signed-bundle inventory and cleanup receipt remain in
`/tmp/arras-notarized-updater-preparation-20261016/`.
The later appearance follow-up compacted two explained regression captures to
their full logs, test trees, assertion-level exports and source snapshots. It also
removed an obsolete ad-hoc package backup and the completed disk-image staging
copy: 391,360,512 allocated file bytes removed, with a 368,640,000-byte observed
free-space increase. All 256 protected source/log/result/package files remained
byte-identical; the unresolved complete native result bundles remain intact.
Evidence: `/tmp/arras-appearance-gesture-polish-20261016/cleanup.json`.
The menu-test follow-up also removed finished compiler caches and duplicate
signing/staging outputs, and compacted its explained event-identity assertion
capture while retaining the full log, tree and assertion exports. It reclaimed
679,108,608 allocated file bytes, with a 614,400,000-byte observed free-space
increase; all 508 protected source/result/package files and the current build
inventory remained unchanged. Unresolved raw results, saved setups, recovery and
personal media remain intact. Evidence:
`/tmp/arras-menu-tracking-investigation-20261016/cleanup.json`.
The completed-signing follow-up removed seven accepted upload archives or exact
DMG staging duplicates from four completed runs. It retained the signed work apps,
final ZIP/DMG archives, Apple IDs/logs and sample libraries. Removed allocated file
bytes totalled 132,345,856; the observed free-space increase was 39,321,600 bytes,
with 173 protected file hashes unchanged. The current completed workflow then
revalidated its existing app, tickets and exact ZIP/mounted-DMG contents without
building, signing or uploading again. Evidence:
`/tmp/arras-completed-signing-cleanup-20261016/result.json`. This follow-up also
confirmed the updater/download runtime source still exactly matches the existing
archive-preparation evidence; no new functional updater defect was confirmed and
unchanged subsystem tests were not repeated. Physical delivery acceptance remains
open.

### Outstanding acceptance gates

- **Desktop and Settings:** verify hidden members, larger collages, displays,
  fullscreen/Stage Manager, sleep/wake, keyboard/VoiceOver and physical Cmd+, on
  the latest candidate. The current five-widget ordinary-Space/Floating/gesture
  acceptance above does not cover these additional cases. Resizing works with another app active, but its cursor
  remains unreliable; no invasive or focus-changing workaround is authorized.
  `NSCursor.current` and programmatic cursor requests do not prove the displayed
  system cursor. The latest 16 October capability check returned no enabled apps
  or browsers: local browser use is disabled in Work settings. Native desktop
  controls are unavailable, so physical interaction still requires the user.
  Resolve the intermittent zero-sample native-menu observation noted above;
  passing native repeats do not replace physical menu/Space acceptance.
  Investigate the separate missing-test-cover WindowServer observation recorded
  with the folder follow-up; later passing snapshots do not establish its cause.
- **Photos:** real edited-album updates, revoke/re-enable recovery, picker visual
  acceptance, intermittent native selection loss and a known sample iCloud-only asset. Normal collection sync works;
  no known cloud-only sample is available. Check Screen Recording recovery
  separately and leave unrelated permissions/personal media alone.
- **Updater:** physical controls in the installed app's real Settings and a
  public replacement/restart with a representative visible sample library.
  Current-source native component actions have fetched and verified the real
  public archive with a deliberate stop before replacement.
  Private component actions, helper runs, synthetic wake notifications and
  hidden-model field/byte preservation do not establish that complete workflow.
  Do not publish a test release or alter the public appcast to satisfy it.
- **Telemetry:** actual production ingestion/expiry compatibility, topology,
  measured monthly command consumption and quota-failure behavior for 1,000–5,000
  Macs. The actual Free Tier, allowance and required command availability are
  verified; minute/day gates do not
  enforce the monthly cap. Do not bypass denied credential access, expose secrets,
  send synthetic production traffic or enable paid upgrades. Local and
  expiring-provider fixtures are scoped evidence only.
- **Launch/site:** final real-footage video (deferred), labeled desktop screenshots,
  final community-rule/copy checks before posting, and final site
  assets/build/links/metadata/Lighthouse. The local site now prepares 2.5.0;
  the public/local route mismatches noted above still need reconciliation at publication.
  Successful local checks do not establish deployed behavior.
  Use bundled/sample media only; Settings must not obscure the desktop footage.
  No Arras publication is authorized while testing continues.

### Local 2.5.0 testing rounds

The newest GitHub actions, arrangement-draft and appearance-paste fixes are in the verified Developer ID/notarized
`dist/notarized/Arras.dmg` and `dist/notarized/Arras.app.zip`. The ad-hoc
`build/current/Release/Arras.app`, `dist/Arras.dmg` and `dist/Arras.app` symlink
contain the same compiled revision, with different distribution signatures.
Matching version numbers alone do not establish matching contents; package
verification checks source provenance. The installed Applications copy has not
been replaced. The isolated Photos sample was refreshed and checked as described
above; it is independent of the separate saved collage demonstration.
Export your existing
layout before trying the new build, and quit the existing Arras before opening the
candidate so two app instances do not write the same library. A new Saved Setup
is useful for experiments inside the candidate; a separate exported archive is
still needed when comparing with an older app that predates these features.

Record the version, package checksum and exact steps for each finding. Start with these rounds:

1. **Hidden collage regression:** put a large portrait and a small landscape in a
   collage, hide the portrait, then add another small photo. Check the visible
   group's bounds, spacing, resizing and dragging. Show the portrait again and
   repeat with the entire collage hidden before adding a photo.
2. **Arrangement recovery:** move and resize a photo and a whole collage; align
   and distribute a selection; drag a photo between two collages and back out.
   Undo and redo each action. Check group bounds, label scale, photo proportions,
   borders, and stacking. Cancel a drag with Escape and confirm it adds no history.
3. **Reusable appearance and reference edits:** copy appearance between hidden,
   locked and grouped photos. Confirm content and placement stay intact. Apply
   crop, rotation, flips and grayscale to a still, GIF, movie and slideshow.
   Check the next slide, relaunch, duplicate, and `.arras` export/import. Cancel
   a draft and confirm it leaves the desktop unchanged.
4. **Saved setups and removal:** save two named arrangements, switch between them,
   restore the previous desktop, remove a collage, then restore its removal after
   relaunch. Confirm later additions and edits survive removal recovery.
5. **Permissions and linked Photos:** explicitly request an album with access
   denied and confirm Open Photos Settings opens the Photos pane. Grant access,
   return to Arras and retry. Check album additions/edits, an iCloud-only asset,
   offline behavior and a desktop switch during a download. Check Screen Recording
   recovery separately. Record the macOS version and the permission state used;
   do not reset unrelated apps' permissions to run this test.
6. **Daily use:** use Settings at its minimum width, keyboard navigation, VoiceOver,
   Stage Manager, fullscreen, sleep/wake and each display arrangement you use.
   Inspect responsiveness with static and animated media. Further numerical
   resource comparisons remain deferred for this audit.

These are pending acceptance checks, not claims of completed validation. Keep
issues and results in the active review conversation; update this baseline when
a new 2.5.0 candidate replaces the previous package rather than adding dated report files.

## Repository hygiene

- `Sources/` and `Tests/` contain current app code and regression coverage.
- `scripts/` contains active build and release validation tools. Personal telemetry-monitor source and tests live separately at `~/Arras Tools/telemetry-monitor/`.
- [SECURITY.md](SECURITY.md#telemetry-protocol-and-activation) owns the telemetry protocol and operational requirements.
- `build/` is disposable generated output; never use it as a source checkout.
- `dist/` contains only the latest verified local distribution.
- The 16 October Release inventory contains only the app, intended assets and
  signing/provenance metadata. Test helpers and debug-only pointer/local-telemetry
  switches are absent. The current receipt links the inventory and cleanup chain,
  recording exact deletions and observed free-space changes. Keep the latest full
  result and unresolved failure evidence when removing superseded generated output.
- Use temporary directories for exploratory logs and fixtures. Keep only evidence
  needed for the current release; never keep source checkouts under `output/`.
- Preserve published release notes and decode migrations: they describe real
  releases and protect existing libraries, even when their UI has been removed.
- Recovery history from before the 8 October cleanup was moved outside this
  checkout to the sibling `Arras Recovery/2026-10-08-before-release-cleanup/`.
  It includes the old website deployment source and user-library recovery copies.
  Reconcile the website deployment changes before removing that archive.


### Launch preparation verified on 18 October 2026

The unpublished 2.5.0 build uses Wednesday–Tuesday UTC reporting periods and keeps
first-launch delivery eligible immediately. Presence detection now rejects stale
NSWorkspace conferencing entries whose PID no longer exists; activation and Space
changes resample that state. Thirty focused telemetry/presence checks passed.
The normal release build and Developer ID postprocessor passed. The current
receipt is `dist/notarized-20261018/Arras.notarization.json`; its source digest and
ZIP/DMG hashes were compared with the current checkout and files. Apple accepted
both submissions and both stapled tickets validate. No release was published.

The personal dashboard now has GitHub, website and app graph columns and 34
regression checks, including fast queued keys and terminal restoration. macOS
reports notifications authorized and a successful pending-alert scheduling
receipt. This does not prove that Focus allowed a visible banner. New first-run
counter observations are checked each minute while awake; closed/offline apps
and this Mac being asleep prevent immediate observation. Daily Vercel referrer
and path aggregates are archived privately; UTM access is paywalled by Vercel,
so separate anonymous Arras server counters are prepared but not yet enabled.

The website contains the actual 10.4-second desktop film and native sample-only
collage, slideshow/layer, appearance, Preferences and Privacy captures. The
original isolated one-logo sample layout and final wallpaper were restored after
capture. Website audit/evidence and the final AEO payload are under
`/tmp/arras-launch-prep-20261018/`. Publication of the app, website, domain
redirects and the AEO apply command remains subject to the owner's final approval.


The 18 October release was explicitly approved by the owner. Its verified local
`dist/notarized-20261018/` files were uploaded to the GitHub draft, and both asset
digests matched the notarization receipt before publication. The public release
is [v2.5.0](https://github.com/yashashwi-s/Arras/releases/tag/v2.5.0); its source
commit is `3af56a192190608d2916089427f47ebd2859fd24`. The updater feed uses the
uploaded ZIP digest. Never substitute the ad-hoc `dist/Arras.app.zip`.

The earlier absence of registered self-hosted runners did not establish hosted
runner availability. The source-push CI actually started, verified macOS SDK 27,
and ran native checks. Signing variables were absent at preflight, so publication
used the verified local packages rather than asking CI to rebuild them. Current
CI status belongs to the GitHub run, not an inference from registered runners.

Release validation also corrected the old-domain and unsigned-install assumptions
in product-document checks. All 73 Python checks passed, and the compiled source
digest still matches the notarization receipt. Earlier dated sections retain their
pre-release holds and limitations as historical evidence.

The first publication CI run exposed three animation-fixture assumptions when
Reduce Motion was enabled, a duplicate Touch Bar/sheet button query, and four
other UI failures on its small desktop. Transition-only fixtures now declare
their system-animation precondition, and the discard action is scoped to its
sheet. CI preserves native result bundles for remaining pointer/reachability
investigation. These are test/diagnostic changes; the published app source digest
and notarized artifacts are unchanged. Passing manual acceptance does not erase
an automated failure, and a skipped animation check is not animation coverage.

Final publication checks: both public package digests and the updater feed passed
the repository’s Public Release Audit. Production website AEO/SEO and 117 exact
legacy redirects passed; both telemetry hosts return direct enabled responses.
The unified dashboard reads all three sources, including a real first-party
website aggregate day, and reports no active incident. The monthly review apply
workflow passed and closed issue #5. Its exact source commit reached Vercel;
final website commit `09af65eccdbc72fdfb22714fd257a93a031ce5ba` is deployed to
Production. The separate live-report workflow passed as well.

Lighthouse measurements differ by host: the development Mac observed mobile
performance 99 and desktop 100; the GitHub runner observed mobile 82 (700 ms
blocking time) and desktop 100. Both had zero layout shift and 100 for
accessibility, best practices, SEO and agentic browsing. These are observations,
not guaranteed scores or app battery measurements. Portfolio/CV/PureMac/Fadeo
pages returned 200, and the public CV PDF remained byte-identical to its
separately authorized version. The editor-height fix is tracked in PR #3 and is
not in the immutable 2.5.0 release packages.

### Dual-target merge verification — 18 October 2026

The sandbox implementation was merged into `ArrasAppStore` without replacing the
free `Arras` target or the direct release workflow. The merged universal Store
Release passed source, metadata, privacy and both-slice entitlement validation;
its binary contains no updater, telemetry engine, self-installer or automatic
legacy migration symbols. All 81 Python checks passed. The merged Store native
suite ran 399 tests with zero failures and two environment skips (synthetic menu
activation and WindowServer coverage); those skips remain physical acceptance
limits. The direct universal Release also built and passed bundle validation.

The direct native suite ran 433 tests with zero failures and one environment
skip. Two focused Store UI checks passed after preserving its ungrouped Updates
accessibility structure: footer/update/privacy controls and single-window tab
navigation. These checks do not establish TestFlight delivery or permission
recovery on an installed Store build.

Apple registered the separate Store identifier and created app record
`6824271927`, **Arras Widgets** (saved after Apple rejected the plain Arras name). Version
2.5.0 customer-facing metadata is saved with manual release selected. The USD
4.99 base-price schedule is configured. On 19 October, the owner added Apple
Distribution and Mac Installer Distribution identities. Source commit
`0dc5baad19c306c97b77fd6be2b3718f0a24c23e` was archived and exported with Apple's
distribution provisioning profile. The expanded package passed both-architecture
source, sandbox and signature validation without installing it. Apple accepted
and processed the upload as 2.5.0; it is assigned to the private **Release
Testing** group with only the owner's account. Automatic group distribution is
disabled. The owner's TestFlight installation was verified at
`/Applications/Arras 2.app`: Apple's TestFlight Beta Distribution signature,
receipt, sandbox and both architectures match the uploaded source. The owner
confirmed Settings opens. In that installed beta, the native example picker
created a three-photo collage; native backup export produced a format-3 `.arras`
with one collage, its three members and three media files. A normal quit/reopen
restored all three photos and their collage. These smoke checks do not establish
Photos/iCloud permission recovery or physical Space/display acceptance.

Apple accepted three actual TestFlight window screenshots at 2560 × 1600. The
owner-confirmed content-rights answer, 4+ age rating and published **Data Not
Collected** privacy declaration are saved. Paid agreement, bank and tax statuses
were verified Active without copying their private details into this repository.
Version 2.5.0 is **Waiting for Review** after submission on 19 October 2026,
submission ID `b5547666-6198-4b8e-a46e-ead4c67d0e04`. **Manual release** remains
selected. Review submission is not approval or public availability. The website
privacy clarification is deployed; its Store badge remains hidden until approval
and a verified live listing. The free direct download stays primary.
Local evidence:
`/tmp/arras-store-submission-20261018/submission-evidence.json`, with archive/export/
upload logs under `build/app-store` (ignored, never release artifacts).

The initial dual-target CI run reproduced all four UI failures from main run
`39103489942`: native drag attachment, two offscreen control checks and reference
Apply persistence. All 433 direct unit checks passed in CI (five system-policy
skips). PR #3 separately fixes the editor-height/reachability cases; its remaining
native-input failure stays open. CI now validates each distribution in a separate
matrix job with fail-fast disabled, so a direct UI failure does not prevent Store
unit/build validation. Existing UI assertions and failure status are retained.
Run `39185427005` passed the Store unit suite (399 tests, five system-policy skips,
zero failures), universal Release validation and documentation checks. Its direct
suite passed all 433 unit tests with five policy skips, then reproduced the same
four UI failures; the overall workflow remains red. No failed assertion was
disabled to obtain the Store result.
