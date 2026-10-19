# Arras security and trust

Arras is free, MIT-licensed open-source software published by
[Yashashwi Singhania](https://yashashwi.me/). This document records verifiable
properties of the current distribution and explains how to report a
vulnerability. The user-facing companion is the official
[Security & Privacy page](https://tryarras.tech/security).

## Obtain and verify Arras

Download Arras only from the
[official GitHub release](https://github.com/yashashwi-s/Arras/releases/latest).
The release ZIP and DMG are the public artifacts; no Homebrew distribution is
currently maintained.

The current **2.5.0** app:

- requires macOS 14 or later;
- uses bundle identifier `com.yashashwi.tableau` for upgrade compatibility;
- contains a universal executable for Apple Silicon (`arm64`) and Intel (`x86_64`);
- is signed with a Developer ID Application certificate, team `K28DKAV937`; and
- is notarized by Apple, with validated app and DMG tickets.

Open the official DMG and drag Arras to **Applications**, then open it. macOS may
ask to confirm opening an app downloaded from the internet. Versions through
2.4.9 were ad-hoc signed and unnotarized; their verification warning and
**Open Anyway** workaround do not describe the 2.5.0 distribution.

The release asset digest and the SHA-256 in [appcast.json](appcast.json) let you
confirm your download matches the published file. Both values come from the
same GitHub publication infrastructure; the updater refuses a ZIP whose SHA-256
does not match its feed.

New local builds record a digest of application/build inputs before signing.
Packaging verifies this against the current checkout and compares extracted ZIP
and mounted DMG contents with the validated app. This records build provenance;
it does not change the ad-hoc signing or notarization status. Private test builds
display their build number and cannot install public updates.

The separate Developer ID distribution postprocessor signs a copy of a verified
build, checks the certificate team and both architectures, and uses a Keychain
profile for Apple uploads. It preserves submission IDs while Apple is processing.
Only accepted results for the uploaded archive hashes, valid stapled app/DMG
tickets, platform policy checks and exact packaged app copies permit local output
promotion. Its receipt records the postprocessor digest alongside the unchanged
compilation digest. A pending submission is not a notarized release.

The 2.5.0 app and DMG passed that workflow: Apple accepted both with no reported
issues, stapled tickets validate, macOS recognizes Notarized Developer ID, and
the exact ZIP/mounted-DMG app copies match the signed build. The receipt is
`dist/notarized-20261018/Arras.notarization.json`. Publication uses these exact
verified files; its updater digest is checked against GitHub’s uploaded asset.

The source is public in this repository. `project.yml` defines the build identity
and entitlements. See [release guidance](CONTRIBUTING.md#build-and-test) for the
automated workflow and the verified local publication path.

## Local data and permissions

Arras has no account, advertising SDK, or external crash-reporting service.
The 2.5.0 release enables the limited statistics described below, including weekly
configuration reports to the first-party endpoint. DEBUG builds default to local
payload inspection. Photos and layout data are stored locally under
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

The optional screen-capture setting retains a compatibility request for older
capture tools. [Apple describes the underlying window-sharing flag as
legacy](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none).
Modern recording and sharing apps may still capture visible widgets. Hide widgets
before starting a share if they must stay private, and check the sharing preview.
AirPlay and HDMI mirroring are not covered. Optional conferencing hiding watches
for selected running applications, not for actual capture, and cannot detect
browser calls.

The free direct-download `Arras` target is deliberately not App Sandbox-enabled:
its in-place updater replaces its own bundle and starts a surviving helper.
It uses the hardened runtime. The telemetry and updater details below describe
that distribution.

### App Store target (not yet released)

`ArrasAppStore` is sandboxed and uses the separate identifier
`com.yashashwi.arras.appstore`. It stores photos/layouts in its own container and
requires explicit user selection to import a direct-download library. Existing
content is not overwritten; old folder grants and telemetry state are not copied.
Selected file reads and persistent folder bookmarks use security-scoped access.
Photos access still requires macOS authorization. Region capture uses
ScreenCaptureKit and captures the selected region after its selection UI closes.

The Store target excludes telemetry, the direct updater, self-installer and
legacy automatic migration from compilation. Its privacy manifest declares no
tracking or collected data and identifies its UserDefaults/file-timestamp API
reasons. The public GitHub star-count request remains available, without a
library or installation identifier. Updates open the Mac App Store. Release
entitlements reject temporary filesystem and Debug/runtime exceptions; the
narrow UI-test fixture exception belongs only to Debug.

The distribution-signed 2.5.0 beta was installed through TestFlight and submitted
to App Review on 19 October 2026 with manual release selected. Apple has not yet
approved or publicly released it. Its published App Privacy response is **Data
Not Collected**; Apple separately manages TestFlight feedback and diagnostics.

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

Opening Preferences can read the public repository star count from
`https://api.github.com/repos/yashashwi-s/Arras`. It is cached in memory for an
hour, including failures, with refresh on Preferences appearance/Settings focus.
There is no separate launch request or polling timer. This read
sends no photo-library data or installation UUID and uses no cookies,
credentials or disk cache. Redirects are refused, responses are limited to
64 KiB and the request/resource timeouts are three/five seconds. Like other
network connections, GitHub receives normal connection information. The GitHub
link works when the count is unavailable.

The updater validates HTTPS, a SemVer version, minimum macOS version, SHA-256,
the presence of an extracted app, bundle identifier, embedded app version, and forward-only version
precedence before swap. A helper retains the previous bundle until the new
version writes a startup health marker; failure triggers rollback. The installer
stages and validates the downloaded bundle before replacing the running app; it
also removes the staged bundle's quarantine attribute as part of that verified
update flow.

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

## Limited statistics — 2.5.0

**Arras 2.5.0 enables limited statistics, with weekly configuration reports.**
The endpoint is `https://tryarras.tech/api/telemetry/v1`. The former
`https://arras.yashashwi.me/api/telemetry/v1` remains a direct compatible API
route, without a redirect, for existing clients.
DEBUG defaults to local payload inspection and supports explicit loopback testing;
there is no third-party analytics fallback.

When enabled, reports contain random installation/event UUIDs, numeric app/build
and macOS major/minor, binary architecture, UTC day, first-use/version milestones
and weekly widget-count buckets in public 2.5.0. The installation UUID links reports within one
installation and survives upgrades while its local file remains. It is not a
hardware fingerprint or an unlinked aggregate. No photos, media, filenames,
paths, EXIF, user text, layouts, desktop/clipboard content, accounts or hardware
identifiers are collected.

Identity/queue files are private, separate from photos and excluded from backups.
Invalid state fails closed. Bounded delivery/retries and a server/Redis kill
switch prevent telemetry failures from affecting widget data. The route rejects
unknown/oversized fields and atomically deduplicates and rate-limits ingestion.
Raw validated events/UUIDs expire 30 days after their UTC day ends; separate
aggregate counts expire after 400 days. Hosting still sees transport headers/IPs;
Vercel runtime logs use the current one-hour retention. Upstash backups are
separate from active-record expiry, as disclosed in the telemetry reference. Website traffic
and GitHub download counts remain separate from app IDs.

[The protocol below](#telemetry-protocol-and-activation) owns the exact payload, exclusions,
limits, storage and activation steps. Accurate disclosures, retention/deletion
responsibilities and emergency controls must be validated before enabling it.
The direct-distribution version intentionally has no opt-out toggle;
consent/withdrawal controls are not a blocker for that release. Re-evaluate
controls, disclosures and App Store privacy requirements before any Mac App Store
submission. The 2.5.0 Developer ID distribution is described above. Direct distribution remains unsandboxed.

## Telemetry protocol and activation

Use the local dashboard for current service status; this document defines the
2.5.0 protocol and operating rules.

When enabled, Arras sends limited usage and configuration statistics to understand
which features are used and improve the app. It does not collect your photos,
filenames, paths or personal content. No account is required and there is no
advertising. The first version intentionally has no telemetry opt-out toggle.

The random installation ID links reports from one Arras installation. In
technical privacy terminology this is a pseudonymous identifier, not an
unlinked aggregate or an assertion that an installation can never be correlated.
Never advertise this as “no tracking.”

### Architecture and ownership

`PhotoManager successful save → typed broad counts → TelemetryRuntime → TelemetryEngine actor → private local state → first-party HTTPS route → Redis`

`TelemetryRuntime.swift` is the only adapter from widget models. It copies broad
integer counts, never `PhotoItem`, `PhotoMedia`, filenames, URLs, image objects,
bookmarks or user text. Facts are emitted only after a successful durable save
and only if type counts changed. Changes to position, opacity, rotation and
appearance do not enqueue a report. The telemetry actor performs disk and network
work off the main actor; there is no launch wait or termination flush. A single
hourly timer with five-minute tolerance and a wake notification check whether a
reporting period or a retry is due. Initial delivery waits 30 seconds asynchronously.

The current reporting-period snapshot is coalesced while it is still queued, so a first import
can be reflected in the first batch. Once a request begins, its event IDs and
snapshot are frozen and that freeze is persisted across retries and relaunches. Configurations changed after successful delivery appear in
the following week's snapshot in public 2.5.0. This is deliberate coarse sampling.

### Exact schema version 1

Batch keys are exactly `schema_version` (1), `environment` (`production` or
`development`), `install_id` (random v4 UUID), and `events` (1–32 events).

Every event has `event_id` (random v4 UUID for retry deduplication), `event`,
`day` (integer UTC days since 1970-01-01), `app_version`, `build`, `os_version`
(macOS major.minor only), and `architecture` (`arm64` or `x86_64`, the running
binary architecture; Rosetta therefore reports x86_64).

| Event | Additional fields | Frequency / meaning |
| --- | --- | --- |
| `first_run` | `existing_configuration`: Boolean | First launch of telemetry, once locally; existing installs are distinguishable from a new install funnel. |
| `app_updated` | `previous_version`: numeric version string | Once per running marketing-version transition, including downgrades. A same-version build change appears in the next configuration report. |
| `first_widget_created` | None | First successful configured-widget addition after an empty first-run baseline. Importing a backup also counts as configuration. |
| `first_collage_created` | None | First configured collage/container after a baseline without one. |
| `first_feature_used` | `widget_type`: fixed enum below | Once locally per broad widget type first added after the baseline. |
| `daily_configuration` | `configuration`: fixed snapshot below | Public 2.5.0: at most one successful report per installation and Wednesday–Tuesday UTC week. The compatible server additionally rejects duplicate daily snapshots. |

The snapshot has exactly `widget_count`, `collage_count`, and `counts_by_type`.
Each count is one of `0`, `1`, `2-4`, `5-9`, `10-19`, `20+`. The type map has
exactly nine keys: `photo`, `animated_image`, `video`, `slideshow`, `collage`,
`container`, `linked_folder`, `photos_collection`, `live_photo`.

Counts describe configured widgets, including hidden ones and grouped child
photos. Only desktop collage parents use `collage`; migrated combined-photo records use
`slideshow`.
The retired Bubble/Polaroid workflow emits no counts; `container` stays in schema 1
for protocol compatibility and is zero in current builds. Collage adoption is
inferred from a nonzero bucket. There are no widget IDs, per-collage image counts, membership graphs or layout details.

All metadata strings are bounded numeric versions or fixed enums. The server
rejects unexpected keys anywhere, invalid UUIDs/enums/dates/buckets, mismatched
environments, empty/oversized event arrays and bodies exceeding 16 KiB. It does
not truncate and retain arbitrary submitted JSON. The client validates its own
persisted queue again before using it.

### Explicit exclusions

No photos, image bytes or media; filenames, file paths, directory names or source
URLs; EXIF/image metadata; widget contents; user-entered text; layouts, coordinates,
sizes, z-order or membership; desktop or clipboard contents; accounts, email,
names, Apple IDs; serial numbers, hardware UUIDs, MAC addresses, display names or
identifiers, persistent OS/device fingerprints; precise location; IP-derived
profiling; screen contents; click streams, drag paths, resize ticks, session
lengths or playback history. No third-party analytics SDK is added to Arras.

### Identity, local storage and failure isolation

UUIDs come only from `UUID()`, never hardware/macOS identifiers. The installation
UUID is stored as UTF-8 in
`~/Library/Application Support/PhotoWidget/Telemetry/install-id` (0600).
Deduplication flags, version state, retry state and the typed queue live in the
same directory's atomic `state.json` (0600), including attempted event IDs; the directory is created with 0700.
These files are separate from `photos.json` and excluded from `.arras` backups.

The ID survives app upgrades and reinstalls while its file remains. Deleting the
ID file regenerates it; deleting the directory resets both identity and first-use
state. Invalid/unreadable existing identity or state disables that telemetry
engine instead of silently resetting it or overwriting the damaged file. Local
telemetry write failures stop sending and cannot change the photo store.
Decoded scheduling dates and retry counters are checked before use, including
arithmetic bounds; damaged values disable telemetry without rewriting the file.

The queue is limited to 32 events and seven days of history. Successful delivery
is limited to one batch per configured UTC period: a week in public 2.5.0 and a
day in compatible daily-mode pilots. Failures have at most three attempts per UTC
day and at least six hours between attempts. Repeated failures increase the delay
to 12, 24, 48 and 96 hours, then seven days; successful delivery resets it.
Persisted attempt state prevents a relaunch retry storm. Each request has a ten-second timeout and a fifteen-second
resource limit. The actual transport uses an ephemeral session without cookies,
credentials or caches; redirects are refused and response bodies stop at 4 KiB.
A single in-flight guard coalesces concurrent flush calls. Permanent schema/body
rejections discard that batch; offline, timeout, rate limits and server failures
retain it until bounded expiry. There is no promise of complete event delivery.

### Endpoints and emergency switches

Primary URL: `https://tryarras.tech/api/telemetry/v1`.

- `GET`: identifier-free, uncached control response
  `{"schema_version":1,"enabled":true|false}`. Any failure/malformed response
  prevents POST. Disabled collection discards the queue and checks again no
  sooner than 24 hours later.
- `POST`: a validated schema-1 batch. 204 acknowledges acceptance (including
  deduplicated retries). 400/413/415/422 are permanent rejection; 429/5xx are
  bounded retry; 410 disables collection and discards the queue.

App: `ArrasTelemetryEnabled=true` for 2.5.0 and `ArrasTelemetryURL` in `project.yml`.
Release builds create no telemetry engine while disabled. DEBUG defaults to
local-only payload logging. DEBUG can send only to an explicit loopback
`ARRAS_TELEMETRY_LOCAL_URL=http://127.0.0.1:13000/api/telemetry/v1`; it always
labels these batches `development`. Unit/UI test launch paths do not start the
runtime. Release builds ignore that development override.

Server: `ARRAS_TELEMETRY_ENABLED` defaults off; `ARRAS_TELEMETRY_ENVIRONMENT`
explicitly separates production/development Redis namespaces. Redis uses
`ARRAS_TELEMETRY_REDIS_URL`, then `ARRAS_TELEMETRY_KV_URL`, then the website's
existing `REDIS_URL`. The pilot uses its own free Upstash database; production
configuration requires certificate-validated TLS with
`ARRAS_TELEMETRY_REDIS_REQUIRE_TLS=1`. No database URL
or service credential is embedded in the app. Redis calls have two-second
connection/command timeouts, no offline queue and no connection retry loop.

Setting `arras:telemetry:v1:production:disabled` to `1` in Redis takes effect in
warm server invocations as well as newly started ones. Setting the server enable
flag off also disables collection. Neither requires an app update. No public
admin or statistics-reading route was introduced.

### Server retention, aggregation and abuse protection

The website's `app/api/telemetry/v1/route.js` uses the existing Next route-handler
structure and ioredis dependency. The 2.5.0 server requires
Redis 8+ `HSETEX` and `HEXPIREAT`; unsupported commands fail closed rather than
using a less safe storage path. The provider scratch database supports both.
On 16 October, read-only queries on the actual production resource reported
Redis 8.4.0 / Upstash 1.18.1, and `ACL CAT hash` advertised both commands.
This establishes availability, not execution of production ingestion or expiry.
The earlier argument error/empty `COMMAND` result is consistent with the
provider's [documented compatibility behavior](https://upstash.com/docs/redis/commands/server/command):
it accepts no arguments and returns an empty array. Production write/expiry and
quota behavior remain unverified. Evidence:
`/tmp/arras-production-telemetry-capabilities-20261016/result.json`.

Each `day:<UTC-day>` hash owns validated raw events, installation/day snapshot
claims, `_schema`, and the anonymous `_aggregate` JSON object. One `HSETEX` commits
new events, deduplication and updated counters together, with an absolute raw-data
expiry 30 days after that UTC day ends. Only `_aggregate` and `_schema` are then
extended to 400 days. If that extension fails, the committed data still has a
safe expiry; a retry repairs anonymous retention without recounting. A batch can
commit some days before failing, and its stable event IDs make replay safe.

The old Lua sequence was atomic with respect to concurrent requests but did not
roll back command errors. Local Redis and an expiring Upstash test database both
reproduced missing totals after retry, and raw/aggregate writes without expiry.
The new candidate passes every tested command boundary, concurrent retries and
multi-day partial commits. These are controlled runtime errors, not proof of the
provider's actual monthly-quota enforcement timing.

Legacy raw/aggregate hashes remain untouched. On first ingestion for a legacy
day, the server reconstructs counters and snapshot claims from its retained event
ledger. This also repairs an orphaned claim or raw event left by the old partial
write. An aggregate exceeding its available raw evidence raises a reconciliation
error instead of erasing history. The new `_aggregate` contains only marginal
counts for events, baseline, version transitions, feature adoption, version/build,
OS, architecture and broad configuration buckets; it contains no installation or
event IDs and no joined layout. Absolute deadlines are never extended by retries.

Budgets are six POST attempts per installation per UTC day and 10,000 accepted
POST requests per environment/day, plus a global 1,000 route requests/minute
ceiling. Short-lived abuse counters expire within two days. Rotating anonymous
IDs cannot evade the global budget. These limits bound ingestion; they do not
authenticate an installation or guarantee protection against a large denial of
service or poisoned metrics. Configure appropriate hosting edge abuse controls
before enabling production.

The handler never reads/stores IP, referrer, user-agent or cookies and never logs
request bodies or exception details. HTTP hosting still sees IP addresses and
transport headers. Hosting/CDN logs, Redis backups, access permissions and
retention must be audited before production; application TTLs do not delete a
provider backup. Do not use infrastructure logs to profile users.

An authorized maintainer reads only `_aggregate`/`_schema` from each new day hash,
or historical `aggregate:<UTC-day>` hashes, for product totals. Never request the
complete new day hash for a dashboard: it also contains installation-linked data. Website traffic/referrers and GitHub asset-download totals
remain separate from app UUIDs. Compare aggregate first-run → first-widget →
configured reporting-period activity; never transmit an attribution token, website cookie,
referrer or fingerprint into the app. Existing installs, reinstallations,
download retries, missing telemetry and delayed/offline delivery mean this is a
coarse funnel estimate, not person-level attribution.

### Private pilot operation

The 2.5.0 Release configuration enables weekly reporting and retains public updates.
Private pilots also enable reporting but disable public updates. Build with
`./build.sh --pilot BUILD`; never change flags inside an existing app bundle.
Use a monotonically increasing internal build identifier for each shared revision,
with fresh source, signing and distribution checks. Refer to the release by its
marketing version in user-facing copy.

The deployed pilot uses the website route with
`ARRAS_TELEMETRY_ENABLED=1`, `ARRAS_TELEMETRY_ENVIRONMENT=production` and
`ARRAS_TELEMETRY_REDIS_REQUIRE_TLS=1`. Its dedicated Upstash database is
`arras-telemetry-pilot`, separate from the website's other Redis storage.
Credentials belong only in hosting secrets. Paid upgrades, Prod Pack and
paid edge rules are not authorized. Free-quota exhaustion may stop telemetry;
it must not affect the app's photo library.

Use `~/bss.sh` for current health and accepted aggregate counts. Historical smoke
tests included synthetic installations; they must not be described as people or
customer adoption. Aggregate keys are
`arras:telemetry:v1:production:day:<UTC-day>` anonymous fields or historical
`aggregate:<UTC-day>` hashes; build counts represent accepted
configuration reports for that UTC day, not multi-day unique installations.
Do not publish raw records, credentials or an unauthenticated statistics route.

To stop collection, set `arras:telemetry:v1:production:disabled` to `1` in the
authorized database console, or redeploy with the server enable flag `0`.
The Redis switch works on warm invocations: GET becomes false and POST returns
410. Clients clear queued telemetry and wait at least 24 hours before checking
again. Clear the switch only after resolving the cause.

The route does not log request bodies or read IP/user-agent headers. No scheduled
telemetry exports are enabled. Provider logs and backups have separate retention
from application TTLs; keep the privacy page accurate and remove the database
and any provider archives when retiring the telemetry service. Check current provider policies
before changing these disclosures:
[Vercel logs](https://vercel.com/docs/logs/runtime),
[Upstash durability](https://upstash.com/docs/redis/features/durability),
[inactive databases](https://upstash.com/docs/redis/help/faq), and
[backup security measures](https://upstash.com/static/trust/security-measures.pdf).

Website source is maintained separately. The 2.5.0 site uses `tryarras.tech` as
its primary domain; old Arras page URLs redirect there. Both telemetry endpoint
hosts stay directly compatible for installed copies. Preserve those APIs and
review the full shared-project diff when deploying portfolio or CV changes.
Anonymous website visit/download aggregates are separate from app UUIDs; see the
website policy for their referrer/UTM fields, retention and request-count limits.

### Free-plan launch capacity

On 15 October, the signed-in Upstash console identified `arras-telemetry-pilot`
as Free Tier and showed limits of 500,000 commands/month, 10 GB bandwidth and
250 MB storage. Vercel's existing integration connects it to the website's
Production environment. Rounded usage was 13k commands, 4 MB bandwidth and 6 KB
storage at $0.00; this is an account snapshot, not a per-batch billing measurement.
The provider's [pricing page](https://upstash.com/pricing/redis) also lists these
command/bandwidth limits. The console labels the resource AWS, us-east-1 and
Global; that does not establish its full replica topology. No plan or connection
settings were changed. Application field expiry does not delete provider
backups, which remain a separate retention gate.

Every successful client batch makes a control GET and upload POST. Both share
the minute gate and kill switch. POST budget checks and ingestion use one script;
invalid payloads still consume the control budget. Optional CLIENT SETINFO is
disabled on the short-lived connections.

The previous candidate measured 16 executed operations per ordinary same-day
GET/upload pair, and 58 for a 13-event batch spread over eight days. That layout
has been superseded by the single-write daily record. Its provider scratch
prototype measured eight Lua calls plus EVAL for a first-day upload, seven plus
EVAL on an existing day, and six plus EVAL for an identical retry. Adding the
three-operation control GET gives **12, 11 and 10 operations respectively**.
Same-day milestones share the write. These are executed-script counts, not an
account invoice or observed quota consumption; the anonymous test database's
metrics did not provide a usable billing counter.

The watcher keeps the existing five-minute endpoint and hourly aggregate
schedule. Allow 34,560 endpoint operations/month at the conservative four per
check, plus 5,760 canonical reads of eight days per hour. Dates without a new
record require an additional historical lookup, adding at most 5,760 operations.
Bootstrap, manual refreshes, rejected traffic and console browsing add work;
UI redraws make no API calls. Upstash documents that [console browsing consumes
commands](https://upstash.com/docs/redis/troubleshooting/command_count_increases_unexpectedly).
Its [pricing FAQ](https://upstash.com/pricing/redis) excludes operational commands
such as AUTH/INFO/PING; do not assume nested script work is free.

The then-current Monday cadence could intersect six Monday–Sunday UTC weeks. A 16 October replay
of the exact native engine, restarted on each fixture date, delivered on
1, 2, 9, 16, 23 and 30 November 2026. Its second flush each day was suppressed.
Weekly cadence is a calendar bucket, not a rolling seven-day minimum between
uploads. Five deliveries is therefore a workload example, not a conservative
monthly upper bound. Wednesday-based periods can also intersect six weeks in a month. The maximum-week model uses six deliveries per installation,
twelve operations each, and the maximum 46,080 watcher allowance:

| Active installations | Weekly reports plus watcher |
| --- | ---: |
| 1,000 | 118,080 operations/month |
| 5,000 | 406,080 operations/month |

The five-delivery example remains 346,080 operations at 5,000 installations with
the then-current maximum watcher allowance; its existing-day/canonical-only variant is
315,320. Milestones spanning days, failed requests, abuse and console usage
consume the margin. The current local store measured forty operations for a
fresh eight-day batch including control and twenty-four for its identical retry.
Replacing one of six twelve-operation reports with that backlog gives
546,080 at 5,000 installations, compared with 486,080 for five deliveries.
These are hypothetical synchronized workloads, not observed populations or
provider billing. The six-delivery backlog model exceeds the 500,000-command
allowance when executed operations are used as a conservative proxy. Provider
accounting can differ, including its operational-command exclusions; these
models do not prove a 5,000-installation free-tier guarantee.

The calendar replay used 30 separate native engine starts and 60 flush calls,
fixture dates and a private stub transport. It changed no Mac clock or cadence,
made no network requests and did not exercise provider limits. Source hashes and
results are in `/tmp/arras-telemetry-calendar-check-20261016/result.json`.

A five-week replay of the current Lua on isolated Redis 8.0.6 measured
9.13/46.68 MB above baseline for 1,000/5,000 synthetic installations, retaining
17,000/85,000 events including all initial milestones. It uses one connection;
historical budget keys remain present and inflate memory. This verifies that
retained workload locally, excluding provider overhead, a full 400-day rollup
history and population-level connection behavior. It supersedes the older
8.26/41.57 MB result from the previous layout.

Ten handler/Redis checks and thirteen monitor checks pass locally, including
raw retention, legacy preservation, ambiguity rejection and error recovery. The
provider scratch prototype also passes concurrent/retry and command-boundary
checks. The current compiled native client passed loopback delivery through two
errors after atomic commits: frozen payloads and backoff survived relaunch,
retry counted each event once and repaired anonymous retention before clearing
the queue. No production capacity traffic or Arras deployment was performed.
Actual production write/expiry capability, billing/topology, sustained population,
provider storage/long-term history and monthly-quota behavior remain gates.

On 16 October, a loopback-only replay used the exact native telemetry and website
handler/store with dedicated Redis 8. It injected the provider's
[documented quota error](https://upstash.com/docs/redis/troubleshooting/max_requests_limit)
before control/ingest execution and exercised the actual Lua per-install 429 gate.
Across 18 separate native processes, failed batches and six-/twelve-hour retry
deadlines survived restart; recovery acknowledged the identical payload once,
retained raw/aggregate expiry and suppressed same-week repeats. Fixture dates
advanced without changing the Mac clock. No provider traffic or quota exhaustion
was induced. Evidence: `/tmp/arras-telemetry-quota-relaunch-20261016/result.json`.
This verifies rejection/recovery behavior locally, not provider enforcement,
monthly billing or population capacity.

Set `ArrasTelemetryReportingDays` to numeric `7` in the build's source
configuration for weekly mode; numeric `1` selects the compatible daily mode.
An absent value retains daily behavior, while invalid values disable telemetry.
Run the normal provenance, validation and signing pipeline after changing source;
never edit a packaged app or DMG to enable reporting. Retained private pilot
artifacts may remain daily. The v1 wire event name remains `daily_configuration`.

**Public 2.5.0 uses weekly reporting; private pilots may remain daily.** Weekly
mode sends one current point-in-time configuration per Wednesday–Tuesday UTC week,
starting with the first launch rather than waiting for Wednesday. An app that is
closed reports on its next eligible launch/wake; this is not a precise Wednesday
appointment. It preserves installation identity/milestones and suppresses another successful
report that week. It does not upload seven daily snapshots or measure live users
or WAU. Client retries retain exponential 6-hour-to-7-day backoff and at most
three attempts/day. A successful upload clears the outage delay; the persisted
UTC-week limit continues to suppress another successful report that week.

The 10,000-batch/day and minute gates do not enforce a monthly command allowance.
Cheap rejection before storage and a measured monthly guard remain necessary
for broad rollout. Deleting data does not reset provider usage. Quota exhaustion
must pause collection and expose monitor failures, preserving photo/library data
and leaving paid upgrades off. No silent provider upgrade or sampling was added.

The capacity table above records the 16 October watcher schedule. The 18 October
minute first-launch checks add read work, and the optional website counters add
their own admitted writes. Those must be included in a launch usage budget; the
older totals are not a current combined-service guarantee.

### Local pilot dashboard and watcher

The maintainer's existing `~/bss.sh` opens one page with matching graph columns
for GitHub, website and app data. **O**, **D** and **W** show overview, daily and
Wednesday-based weekly detail; range keys apply to all three sources. No separate
telemetry command is needed. A failed source retains its last good values and
freshness label while the other columns remain usable. App counts are accepted
configuration or milestone reports, not verified people, installations or active
Macs. Today is partial UTC data; missing observations remain unknown.

```sh
~/bss.sh
~/bss.sh --monitor-status
~/bss.sh --monitor-check
~/bss.sh --monitor-stop
~/bss.sh --monitor-start
```

The personal monitoring tools are maintained outside the app repository at
`~/Arras Tools/telemetry-monitor/`. They are not app or release dependencies.
The installer checks the existing TUI's integration boundaries and preserves an
original backup at `~/.local/share/arras-monitor/bss.before-telemetry.sh`.
The native helper lives at `~/Applications/Arras Monitor.app`; a compatibility
link remains beside the collector. Reinstallation preserves its existing
signing certificate. For a first install, an existing local certificate can be
selected with the installer's `--signing-identity` option; otherwise signing is
ad-hoc. No developer membership purchase or new credential is requested.
`~/bss.sh --monitor-setup` accepts the database HTTPS REST URL and **read-only**
REST token through an interactive terminal. Token input is hidden and the value
is stored via macOS Keychain APIs, never in command arguments, environment
variables, app builds, chat, configuration files or logs. Setup validates a
read-only aggregate query. The user must select the existing Read-Only Token;
the code never probes write permission, resets credentials or requests a
standard/admin token. See [Upstash REST access](https://upstash.com/docs/redis/features/restapi).

The installed watcher checks local state every 30 seconds, endpoint control
every five minutes, today’s anonymous counters every minute and the eight
possible recent event days every hour while this Mac is awake and logged in. The first read covers 30 UTC days; subsequent reads refresh
the eight possible recent event days so delayed reports are included. Commands
request only `_aggregate`/`_schema` with `HMGET`, and use `HGETALL` only for
historical aggregate keys when a day has no new record. Corrupt or denied new
records raise an error instead of falling back. No raw event, snapshot-ID,
installation-ID, SCAN/KEYS, analytics export or synthetic telemetry POST is used.
Hourly aggregate reads use about 5,760 commands per 30-day month. Minute
checks add up to 42,480 canonical reads; absent canonical records may require
one additional legacy lookup each. These checks consume the same free quota; endpoint checks also consume existing route/connection commands. These
are free-plan usage, not a subscription purchase or unlimited-capacity promise.
Manual refresh has a 30-second cooldown. UI redraws use only the local cache.

Checks fail visibly for an unavailable/malformed endpoint, disabled collection,
denied aggregate access, corrupt/non-private local telemetry files, exhausted
daily delivery retries or expired queued events. Last good totals remain cached
with their observation time on read failure. Daily batching and an app that is
closed are not themselves failures. No observer reads or modifies `photos.json`,
resets the install UUID, changes the kill switch or retries the app's queue.
Private cache/log files are bounded and contain sanitized counters/status only.

A signed local notification helper reports each new failure once and reports
recovery. A separate native heartbeat guard checks every minute and alerts if
the collector's heartbeat is over two minutes old, allowing it to detect a
crashed/hung collector independently. Startup has a 90-second grace period;
an intentional stop disables both jobs and persists that intent across login.
macOS must allow Arras Monitor notifications; a denied permission requires
enabling it in System Settings → Notifications. OS Focus/notification policy can
silence presentation. Dashboard alerts remain visible even when notifications
are unavailable. The last scheduling result and OS permission query are tracked
separately: macOS accepting a request does not prove that a banner appeared.
Scheduling uses the normal UNUserNotificationCenter API, which enforces OS
permission; framework denial is reported explicitly. Foreground presentation
uses the notification delegate. Permission is checked
every five minutes; failed collector-alert deliveries remain pending and retry at most every
five minutes, with the latest failure/recovery for each incident taking precedence.
This is local monitoring: it cannot run while the Mac is asleep or off. An offline
Mac can report its connection failure, but cannot observe fresh server health or
diagnose an invited user's offline device immediately. Failure
notifications occur when a check observes a fault, not at an unobservable remote
instant. It uses no AI scheduler, messaging service or paid alerting integration.

The single-page dashboard restores the original GitHub bar charts and uses
matching graphs for GitHub, website and app data. All selected periods use
completed UTC days; missing observations remain unknown. Separate labels keep
GitHub asset requests, website page views and app configuration reports distinct.
An hourly history collector continues collecting while the dashboard is closed
and respects the monitor’s explicit stop setting. Vercel OAuth credentials are
renewed by the official CLI, without logging or copying tokens into the cache.

New-install alerts compare only anonymous first-run counters, separating an empty
configuration’s first launch from adoption by an existing configuration. The first
read establishes a baseline and never announces historical reports as new installs.
Counters and pending alerts survive restart; delayed offline arrivals may be found
by the hourly sweep. Notification delivery requires macOS permission, this Mac
being awake and logged in, and successful app/server delivery. A first-run report
is not proof of a completed installation, and notifications are not instantaneous.

Vercel’s free access permits daily referrer/path aggregates. The provider rejected
UTM queries on 18 October with an explicit Web Analytics Plus/Enterprise requirement;
no paid upgrade was enabled. The website uses separate Arras-only
server request/download counters with short referrer and UTM labels, no IPs, full
referring URLs, raw user agents, cookies or visitor IDs. These anonymous day buckets
expire after 90 days; the private local archive retains daily aggregates for later
comparison. A default 5,000-event monthly write allowance and per-day cardinality
bound protect this extra store, but do not guarantee a provider command budget.
No website identifier is joined to the app installation UUID. The website collector was activated with the reviewed production configuration
on 18 October 2026; the normal dashboard launcher read its first aggregate day
successfully. It does not backfill unavailable historical UTM data. See the website’s Security page for the
customer disclosure. Provider connection logs have separate retention.

### Reset history and future production capacity

The private test dataset was reset on 7 October 2026. The monitor records that
boundary and treats absent totals as unknown until new reports arrive. App
identities, delivery eligibility and photo libraries were not reset. Server
cleanup must not cause a second first-run event or fabricate missing activity.

The monetary budget remains **$0**. Public 2.5.0 limited statistics are authorized;
public rollout still needs measured capacity within the existing free service.
No paid storage or infrastructure changes are authorized. Cloudflare D1 was discussed as a candidate, but no
migration has been implemented or authorized for deployment. Do not advertise
10,000 daily installations as supported by the current pilot infrastructure.

Before public activation, measure normal reports, retries, abuse, retention
cleanup, aggregate reads and index/storage overhead against current free quotas.
Validate strict input rejection before storage work, atomic deduplication,
environment separation, emergency disabling and bounded retention. Quota
exhaustion must stop collection without buying capacity or changing photo
behavior. Reconcile privacy disclosures and monitoring with the verified design.

### Distribution scope and App Store review

Release scope confirmed 7 October 2026: consent/withdrawal controls are not a
blocker for the current direct-distribution release. The first telemetry version
intentionally has no opt-out toggle. The production endpoint, disclosures, retention and emergency controls are
deployed. Isolated Redis tests cover rejection, deduplication, expiry and failure
behavior; live checks verify both endpoint hosts and anonymous website writes.
No synthetic app batches were sent to production. Provider-scale quota behavior
and capacity for 5,000 Macs remain unproven. A stable random UUID remains linkable within
one installation.

The separate Store target excludes this telemetry engine and declares no data
collection. Any future change must re-evaluate controls, consent/withdrawal,
disclosures and privacy declarations against the then-current
[App Review guidelines](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage).
The direct-distribution decision does not establish Store approval.
The 2.5.0 Developer ID distribution is described above. Direct releases use
unsandboxed self-updating.

### Development isolation and monitor permissions

Production retains the historical `Telemetry` identity and queue directory.
Development transport uses `TelemetryDevelopment`; local dry-run inspection uses
`TelemetryDryRun`. Both are siblings in the library directory and cannot consume
production milestones or delivery eligibility. Older production queues with a
recorded attempt are conservatively frozen when the new freeze field is absent.

The local monitor displays current notification permission separately from the
last scheduling receipt. Denied or undetermined permission remains actionable
in the dashboard, and pending incident notifications are retained until delivery
can be scheduled with authorized or provisional permission. A scheduling receipt
still does not establish that a banner was visible.
