# Arras security and trust

Arras is open-source software published by
[Yashashwi Singhania](https://yashashwi.me/). This document records verifiable
properties of the current distribution and explains how to report a
vulnerability. The user-facing companion is the official
[Security & Privacy page](https://arras.yashashwi.me/security).

## Obtain and verify Arras

Download Arras only from the
[official GitHub release](https://github.com/yashashwi-s/Arras/releases/latest).
The release ZIP and DMG are the public artifacts; no Homebrew distribution is
currently maintained.

The current public app:

- requires macOS 14 or later;
- uses bundle identifier `com.yashashwi.tableau` for upgrade compatibility;
- contains a universal executable with Apple Silicon (`arm64`) and Intel
  (`x86_64`) slices;
- is ad-hoc signed, without a Developer ID team identity; and
- is not notarized.

The release therefore does not provide Apple's Developer ID/notarization trust
chain. Gatekeeper may block first launch. Verify the download source before
using **Open Anyway** or clearing quarantine. The release asset digest and the
SHA-256 in [appcast.json](appcast.json) provide visible byte-level
integrity values from the same GitHub publication infrastructure; the updater refuses a ZIP whose SHA-256 does not match its
feed.

The source is public in this repository. `project.yml` defines the build
identity and entitlements, and the tag workflow builds the published artifacts.

## Local data and permissions

Arras has no account, advertising SDK, app analytics, telemetry, or external
crash-reporting service. Photos and layout data are stored locally under
`~/Library/Application Support/PhotoWidget/`. Imported media is copied there
and may be downsampled or re-encoded; exported `.arras` files contain those
stored copies.

The app requests or uses system capabilities only for the feature that needs
them:

- **Photos:** the system Photos picker imports selected assets. iCloud-backed
  selections may be downloaded by Photos.
- **Screen Recording:** interactive region capture runs macOS
  `/usr/sbin/screencapture`. Arras remains usable without it.
- **Notifications:** requested only when an update/announcement banner needs to
  be posted.
- **Launch at Login:** configured through `SMAppService` when enabled.
- **Accessibility:** not required for moving widgets, snapping, the global
  shortcut, or other shipped controls.
- **Full Disk Access:** not required.

The optional screen-capture setting requests AppKit window exclusion from
ordinary screenshots and compatible capture/share paths. Capture behavior is
controlled by macOS and should be tested with the sharing software in use; the
setting cannot cover AirPlay or HDMI display mirroring. Optional conferencing
hiding watches for selected running applications, not for actual capture, and
cannot detect browser calls.

Arras is deliberately not App Sandbox-enabled. Its in-place updater must replace
the app bundle and start a helper that survives the current process. The app
does use the hardened runtime, but ad-hoc signing and lack of notarization remain
material distribution limitations.

## Network behavior

Normal widget display, editing, backups, and local imports require no Arras
server.

Update checks fetch:

`https://raw.githubusercontent.com/yashashwi-s/Arras/main/appcast.json`

Update downloads use the HTTPS GitHub release URL in that feed and GitHub's
download infrastructure. The release URL carries product/version query values;
immediately before each download Arras adds a fresh random `request` UUID. It
is request-scoped measurement data, not a persisted installation or device
identifier. Arras sends no photo, filename, layout, account, or hardware
identifier with an update request.

The updater validates HTTPS, a SemVer version, minimum macOS version, SHA-256,
the presence of an extracted app, bundle identifier, embedded app version, and forward-only version
precedence before swap. A helper retains the previous bundle until the new
version writes a startup health marker; failure triggers rollback. The installer
removes quarantine from the verified staged bundle because the public app is
not notarized.

The Arras website is a separate service and may use Vercel Analytics and Speed
Insights. Those website measurements are not embedded in the Arras app.

## Supported versions

Security fixes are made for the latest published release. Before reporting an
issue in an older build, reproduce it on the current
[GitHub release](https://github.com/yashashwi-s/Arras/releases/latest) when it is
safe to do so.

## Report a vulnerability

Do not open a public issue for a suspected vulnerability. Use
[GitHub Private Vulnerability Reporting](https://github.com/yashashwi-s/Arras/security/advisories/new)
and include:

- affected version and macOS version;
- impact and the conditions required to reproduce it;
- minimal reproduction steps or a proof of concept;
- relevant logs with personal data removed; and
- any suggested mitigation.

Reports are investigated as maintainer availability allows. Confirmed issues
will be prioritized according to impact and exploitability. Credit is offered
when desired and appropriate; no fixed response or release deadline is
promised.
