# hanji

A native macOS (SwiftUI + TextKit 2) markdown editor that opens markdown vaults,
with a Swift extension SDK. Design: [`docs/2026-06-06-native-markdown-editor-design.md`](docs/2026-06-06-native-markdown-editor-design.md).

## Status: M1 — Live Preview basics

- Opens a vault folder, lists `.md` files
- **Live Preview** for headings, bold, italic, inline code, links & wikilinks:
  inline styling with caret-aware marker hiding (markers reveal on the line you're editing)
- Edit + atomic save in a TextKit 2 editor
- In-memory metadata index (titles)
- Compile-time plugin SDK + bundled Word Count plugin (proves the host↔plugin loop)

## Build & run

```sh
swift run Checks     # run unit checks (zero-dependency test runner)
swift run hanji  # run from SPM
./Scripts/bundle-app.sh && open hanji.app   # build & launch a .app bundle
```

Requires the Swift toolchain. **Command Line Tools is sufficient** to build and run
(full Xcode is optional, and only needed for XCTest, Instruments, and code-signing).

## Architecture (M0 modules)

```
HanjiApp (exe) → AppCore → { VaultKit, ExtensionSDK, EditorEngine, MarkdownCore }
VaultKit → MarkdownCore        WordCountPlugin → ExtensionSDK
```

Plugins depend only on `ExtensionSDK`. First-party features are built on the same SDK.

## License

MIT
