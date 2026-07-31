# CLAUDE.md — Tableau

Guidance for AI coding agents working in this repo.

The first half is general working principles, adapted from
[Andrej Karpathy's observations on LLM coding pitfalls](https://github.com/multica-ai/andrej-karpathy-skills).
The second half is what this specific codebase will bite you with.

---

## 1. Think before coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

- State assumptions explicitly — if uncertain, ask rather than guess
- Present multiple interpretations rather than silently picking one
- Push back when a simpler approach exists
- Stop when confused; name what's unclear instead of writing code around it

In this repo specifically: **don't theorise about AppKit, test it.** Three
separate bugs here were diagnosed by adding an `NSLog` and running the app,
after plausible-sounding theories turned out to be wrong. See §7.

## 2. Simplicity first

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked
- No abstractions for single-use code
- No "flexibility" or "configurability" that wasn't requested
- No error handling for impossible scenarios
- If 200 lines could be 50, rewrite it

## 3. Surgical changes

**Touch only what you must. Clean up only your own mess.**

- Don't "improve" adjacent code, comments, or formatting
- Don't refactor things that aren't broken
- Match existing style even if you'd do it differently
- If you notice unrelated dead code, mention it — don't delete it
- Remove imports/variables your change orphaned; leave pre-existing dead code alone

## 4. Goal-driven execution

**Define success criteria. Loop until verified.**

Turn vague instructions into checkable steps:

```
1. [Step] -> verify: [check]
2. [Step] -> verify: [check]
```

For this repo the verification bar is concrete: **`./build.sh` prints
`** BUILD SUCCEEDED **`, the app launches, and `photos.json` still decodes.**
"It compiles" is not done.

## 5. Report honestly

- If tests fail, say so and show the output
- If you skipped part of the task, say which part and why
- Don't describe work as verified when it was only written
- A plausible explanation is not a diagnosis — say which one you actually confirmed

---

## 6. What this project is

A macOS menu bar agent (`LSUIElement`) that puts photo widgets on the desktop.
Swift + AppKit, with SwiftUI for the settings panel. No dependencies.

```
Sources/App/
├── AppDelegate.swift        # status item menu + settings window lifecycle
├── ContentView.swift        # SwiftUI settings UI
├── DesktopPhotoWindow.swift # borderless NSWindow + drag/resize/snap/crossfade
├── ImageManager.swift       # PhotoManager: state, persistence, window creation
├── PhotoItem.swift          # Codable per-photo model
└── ...                      # one file per feature; see FEATURES.md
```

**Build:** `./build.sh` (xcodegen + xcodebuild). `--run` installs to
`/Applications` and launches; `--release` packages and prints the appcast fields.

**New files are picked up automatically by xcodegen** — never hand-edit
`Tableau.xcodeproj`, it's generated. If it conflicts in a merge, run
`xcodegen generate` instead of resolving it by hand.

---

## 7. Traps specific to this codebase

These have each caused a real bug. They are not hypothetical.

### `PhotoItem` decoding is hand-written and load-bearing

`init(from decoder:)` uses `decodeIfPresent(...) ?? default` for **every** field
added after v1.0. Any new field must follow that exact pattern.

Get this wrong and `photos.json` fails to decode, `loadSaved()` returns early,
and **every user loses every widget silently**. There is no error surfaced.
Before shipping a schema change, decode a real pre-change `photos.json` against
the new model and confirm it survives.

### Don't `Task { }` in a termination handler

`willTerminate` ran its save inside a `Task`, which schedules work for a
main-queue turn that never arrives during shutdown. The save silently never
happened for months. Notifications delivered on `.main` are already on the main
actor — use `MainActor.assumeIsolated` and run synchronously.

### `NSMenuItem.image` does not render on macOS 27

Confirmed on macOS 27.0: images assigned to status bar menu items are simply not
drawn, including plain SF Symbols, with or without a submenu. Use an
`NSTextAttachment` in `attributedTitle` instead. Keep the plain `title` set too,
for VoiceOver and menu search.

### Compiler warnings are not an OS audit

The deployment target is 14.0, so the compiler stays silent about anything
deprecated in macOS 15+. `disableScreenUpdatesUntilFlush()` sat in the code for
two releases doing nothing. Check SourceKit diagnostics against the current SDK.

### The app is deliberately not sandboxed

The updater has to replace `Tableau.app` and spawn a helper that outlives the
process; App Sandbox forbids both. Don't "fix" this by re-adding the entitlement
— it would break updates and silently move Application Support back into
`~/Library/Containers`, orphaning everyone's data. See `StorageMigration.swift`.

### Never let animation cost the idle CPU budget

Near-zero idle CPU is a stated feature. GIF playback uses a
`CAKeyframeAnimation` that runs on the render server. A `Timer` or
`CADisplayLink` per widget would wake the app process constantly. Keep animation
declarative and on the render server.

### Don't test against the user's real data

`PhotoManager.storageDir` is hardcoded to
`~/Library/Application Support/PhotoWidget/`, which holds real photos and
`photos.json`. Running the live class from a harness writes junk there and spawns
real desktop windows. Compile the model types against a scratch directory
instead.

---

## 8. Conventions

- 4-space indent, `// MARK: -` section headers
- **Comments explain _why_, not _what_.** The codebase justifies non-obvious
  decisions (`isReleasedWhenClosed = false ... to prevent use-after-free on
  re-show`). Match that voice. Don't narrate what the code plainly does
- No emoji in source
- SwiftUI animations use `easeInOut` only — no springs, matching native macOS feel
- `@MainActor` on anything touching windows or `PhotoManager`
- Keep `FEATURES.md` truthful. It documented click-through as shipped for two
  releases after it was removed

## 9. Releasing

1. Bump `MARKETING_VERSION` in `project.yml`
2. `./build.sh --release` — prints the SHA-256 and exact `appcast.json` fields
3. Upload `dist/Tableau.app.zip` to a GitHub Release tagged `vX.Y.Z`
4. Paste the printed fields into `appcast.json` and push to `main`

The updater refuses any download whose checksum isn't declared, so step 4 is not
optional. Publishing is outward-facing — confirm with the user before doing it.
