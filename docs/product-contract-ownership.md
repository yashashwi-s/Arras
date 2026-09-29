# Public contract ownership

| Document | Role |
| --- | --- |
| README.md | Concise user overview, current download path, compatibility, and starting points |
| FEATURES.md | Reviewed current shipped and reachable behavior, maintained on main |
| ARCHITECTURE.md | Version-independent engineering ownership and lifecycle contracts |
| SECURITY.md | Distribution trust, local data, network behavior, and disclosure policy |
| CONTRIBUTING.md, CLAUDE.md, PR/issue templates | Contributor and agent guidance |
| CHANGELOG.md, release-notes/*.json | Historical records; do not rewrite truthful history |
| product-metadata.json | Canonical stable machine-readable public facts |
| appcast.json, GitHub Releases | Generated updater state and published release-specific artifacts |
| CODE_OF_CONDUCT.md, LICENSE | Community policy and legal terms |

The website reads the main-branch product contract over HTTPS, validates it, and
uses a generated committed fallback if the network or remote contract fails.
This is read-only consumption: routine product changes do not require a website
copy/paste or cross-repository writer. The fallback is an outage cache, not an
independent owner. The separate live website audit reports fallback drift.

The website cites main FEATURES, which permits correcting documentation without
making a new app release. Main FEATURES must describe the latest public release,
not unfinished work on a development branch. A behavior PR must update relevant
documentation or give a checked, written reason that it remains correct. The
release-specific history remains in the release notes and changelog.

Offline validation checks schema, project/release configuration, links, required
documents, README size, stale headings, and retired distribution instructions.
It cannot prove every prose claim or whether code is reachable: reviewers must
trace the released code and tests. Public Release Audit separately downloads and
checks the current artifacts and updater feed without modifying them.

The one-time artifact review found that the v2.4.9 ZIP and DMG contain the same
universal arm64/x86_64 executable, despite an Apple-Silicon-only footer in the
published release body and old product metadata. Historical release JSON was
left intact; future boilerplate derives compatibility from the product contract.
