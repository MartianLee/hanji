# hanji

A native macOS (SwiftUI + TextKit 2) markdown editor that opens markdown vaults,
with a Swift extension SDK. Design: [`docs/2026-06-06-native-markdown-editor-design.md`](docs/2026-06-06-native-markdown-editor-design.md).

## Status: Live Preview + first-party plugins (Periodic Notes, Templater)

- **Onboarding** — a Welcome screen (prominent **Open Vault…** + recent vaults),
  recent-vault memory, automatic re-open of the last vault on launch, and a
  **Settings** window (⌘,) to manage recents
- **Command palette (⌘P)** to run plugin commands and a **quick switcher (⌘O)**
  for fuzzy file-name jump
- First-party **Periodic Notes** (default-on) — *Open today's daily / this week's /
  this month's note*; reads your existing Obsidian `periodic-notes` config (folder,
  date format, template) and creates the note from its template if missing
- First-party **Templater** — *New note from template…*; renders Obsidian
  `<% tp.* %>` syntax (core date/file functions: `tp.date.now/tomorrow/yesterday`,
  `tp.file.title/creation_date/cursor`) with the caret placed at `tp.file.cursor`
- **Live Preview** for headings, bold, italic, inline code, links & wikilinks,
  blockquotes, callouts, frontmatter, lists & tasks (with clickable checkboxes),
  and fenced code blocks: inline styling with caret-aware marker hiding
  (markers reveal on the line you're editing)
- Edit + atomic save in a TextKit 2 editor
- In-memory metadata index (titles, tags)
- Compile-time plugin SDK: ① code-block renderers, ③ commands (⌘P) + sidebar,
  and a workspace note create/open capability. Bundled Word Count plugin proves
  the host↔plugin loop
- **Extensible code-block renderers** (`CodeBlockRenderer` SDK surface): fenced blocks
  render as inline widgets that reserve their own height (raw source revealed while
  editing). Built-in: **mermaid** diagrams (WKWebView), **Dataview-lite** (`LIST FROM #tag`),
  and a `card` renderer
- **Inline images** — `![[file]]` / `![alt](path)` rendered from the vault
- **Global search (⇧⌘F)** — sidebar search panel over a persistent FTS5 index
  (Korean-friendly trigram matching); results jump the caret to the match. The
  index lives in Application Support and updates incrementally as you edit

## Build & run

```sh
swift run Checks     # run unit checks (zero-dependency test runner)
swift run hanji  # run from SPM
./Scripts/bundle-app.sh && open hanji.app   # build & launch a .app bundle
```

Requires the Swift toolchain. **Command Line Tools is sufficient** to build and run
(full Xcode is optional, and only needed for XCTest, Instruments, and code-signing).

## Architecture (modules)

```
HanjiApp (exe) → AppCore → { VaultKit, ExtensionSDK, EditorEngine, MarkdownCore }
VaultKit → MarkdownCore
TemplateKit (pure: moment format, template engine, periodic/templater config)
WordCountPlugin · CoreRenderers → ExtensionSDK
PeriodicNotesPlugin · TemplaterPlugin → { ExtensionSDK, TemplateKit }
```

`MKSearchKit → GRDB` is the only external dependency (FTS5 search index).
Plugins depend only on `ExtensionSDK` (plus pure libs like `TemplateKit`) — never on
`AppCore`/the app. First-party features are built on the same SDK. The template/periodic
logic lives in the pure, dependency-free `TemplateKit`, fully covered by `swift run Checks`.

## License

MIT
