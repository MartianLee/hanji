# hanji

A native macOS (SwiftUI + TextKit 2) markdown editor that opens markdown vaults,
with a Swift extension SDK. Design: [`docs/2026-06-06-native-markdown-editor-design.md`](docs/2026-06-06-native-markdown-editor-design.md).

## Status: Live Preview + extensible block renderers

- Opens a vault folder, lists `.md` files
- **Live Preview** for headings, bold, italic, inline code, links & wikilinks,
  blockquotes, callouts, frontmatter, lists & tasks (with clickable checkboxes),
  and fenced code blocks: inline styling with caret-aware marker hiding
  (markers reveal on the line you're editing)
- Edit + atomic save in a TextKit 2 editor
- In-memory metadata index (titles)
- Compile-time plugin SDK + bundled Word Count plugin (proves the host↔plugin loop)
- **Extensible code-block renderers** (`CodeBlockRenderer` SDK surface): fenced blocks
  render as inline widgets that reserve their own height (raw source revealed while
  editing). Built-in: **mermaid** diagrams (WKWebView), **Dataview-lite** (`LIST FROM #tag`),
  and a `card` renderer
- **Inline images** — `![[file]]` / `![alt](path)` rendered from the vault

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
VaultKit → MarkdownCore        WordCountPlugin · CoreRenderers → ExtensionSDK
```

Plugins depend only on `ExtensionSDK`. First-party features are built on the same SDK.

## License

MIT
