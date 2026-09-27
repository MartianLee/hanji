# Contributing to Hanji

Thanks for your interest! Hanji is a native macOS (SwiftUI + TextKit 2)
markdown editor for local markdown vaults, with a Swift extension SDK.

## Building

```sh
swift build                 # build everything
swift run hanji             # run from SPM
./Scripts/bundle-app.sh && open Hanji.app   # build & launch a .app bundle
```

**Command Line Tools is sufficient** — full Xcode is only needed for XCTest,
Instruments, and code-signing. Minimum target: macOS 14; building needs a
Swift 6.1+ toolchain (Xcode 16.3+ / matching Command Line Tools). The only external
dependency is [GRDB](https://github.com/groue/GRDB.swift) (FTS5 search index),
isolated to the `MKSearchKit` target.

## Testing

This project does **not** use XCTest (Command Line Tools ships no XCTest). Tests
live in a tiny zero-dependency runner under `Sources/Checks`:

```sh
swift run Checks            # run all checks
swift run Checks <Group>    # run one group, e.g. `swift run Checks LinkParser`
./Scripts/e2e.sh           # headless end-to-end scenario + bundle + launch smoke
```

Add a test by writing a `func myChecks()` (using `expect`/`expectEqual`) in a
`Sources/Checks/*.swift` file and registering `("MyGroup", myChecks)` in
`Sources/Checks/main.swift`. **Every change should keep `swift run Checks` green**
(currently 1056 assertions / 128 groups). Prefer pure, headless tests; UI behavior
that needs a window (e.g. drawing) is verified by screenshot during review.

## Architecture & where code goes

```
HanjiApp (exe) → { AppCore, EditorEngine, CoreRenderers, first-party plugins }
AppCore        → { VaultKit, ExtensionSDK, MarkdownCore, MKSearchKit }
EditorEngine   → { MarkdownCore, ExtensionSDK }
MKSearchKit    → GRDB           (the ONLY module allowed to import GRDB)
Plugins        → ExtensionSDK   (+ pure libs like TemplateKit) — never AppCore/the app
```

- **Pure logic** (parsers, formatters, query language) goes in dependency-free
  modules: `MarkdownCore`, `TemplateKit`. Keep it pure and fully checked.
- **Editor rendering** (Live Preview, widgets, fragments) is in `EditorEngine`.
- **Search / index / Dataview execution** is in `MKSearchKit` (the only GRDB user).
- **First-party features are plugins** built on the same SDK as third parties.

## Plugins (compile-time model)

Plugins implement the `Plugin` protocol in `ExtensionSDK` and depend **only** on
`ExtensionSDK` (plus pure libs). They are **compiled into the app**: add your
target to `Package.swift`, then register an instance in the `plugins` array in
`Sources/HanjiApp/HanjiApp.swift`. There is no dynamic/community plugin
loader yet (it's on the roadmap) — to ship a plugin today, contribute it or fork.
See `BacklinksPlugin`/`CalendarPlugin` for end-to-end examples (sidebar panel +
the `MetadataQuerying` SDK surface).

## Commits & PRs

- Keep `swift build` and `swift run Checks` green; add/adjust checks for behavior
  changes.
- Conventional-ish messages (`feat(editor): …`, `fix(search): …`, `docs: …`).
- One focused change per PR where possible; describe the user-visible effect.

## Known gaps / good first issues

See the roadmap and known limitations in [`README.md`](README.md#status--known-gaps).
Performance/correctness debt (large-vault async search, schema `field(path)`
index, `Tags.extract` skipping code fences, etc.) is tracked there and makes good
starter work.
