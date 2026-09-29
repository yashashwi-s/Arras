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

`project.yml` owns project configuration. Generate `Arras.xcodeproj`; do not
hand-edit it. Tests must use injected temporary storage and must never read or
write the user's `~/Library/Application Support/PhotoWidget/` data.

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
records; do not rewrite truthful history to describe current behavior.
`product-metadata.json` owns stable machine-readable public facts, while
version, date, artifacts, and digests come from GitHub Releases and the appcast.

Validate the documentation and public contract offline with:

```sh
python3 scripts/validate_product_metadata.py
python3 -m unittest discover -s scripts -p 'test_*.py'
```

The separate `Public Release Audit` workflow downloads the latest public
artifacts and reports discrepancies; it never edits content or publishes releases.

Follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report suspected
vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
