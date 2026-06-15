# hanji — Backlinks Panel (SDK ② MetadataQuerying)

Design doc · 2026-06-10 · Epic D of the v1 close-out roadmap
Builds on the global-search index (`2026-06-10-hanji-global-search-design.md`, schema v2 slot) and the original PRD (M3 백링크 패널, SDK surface ②).

## 1. Goal

A right-sidebar **Backlinks** panel showing every note that links to the active
note ([[wikilink]] or markdown link), with context snippets, updating live as
notes change. Built as a **first-party plugin** over a new minimal SDK query
surface (②) — dogfooding the PRD's `MetadataQuerying`.

### Decisions (locked)

- **D-scope:** Linked mentions only. Unlinked mentions (plain-text title hits,
  reusable from FTS) are a follow-up.
- **D-arch:** Approach A — pure `LinkParser` (MarkdownCore) → `link` table in
  the MKSearchKit DB (migration v2, updated on every reindex) → minimal SDK ②
  surface on the host → `BacklinksPlugin` that depends on ExtensionSDK only.
- **D-matching:** Obsidian-style — `[[Plan]]` matches `Projects/Plan.md` by
  filename base; a full relative path (`[[Projects/Plan]]`) also matches.
  Aliases (`[[Plan|별칭]]`) and heading refs (`[[Plan#섹션]]`) resolve to the
  target before `|` / `#`. Case-insensitive.
- **D-ui:** Right sidebar (the existing plugin-sidebar pane; registering the
  panel automatically restores the 3-column layout).

## 2. Architecture & data flow (시각화)

```
                         ┌──────────────────────────── hanji ────────────────────────────┐
                         │                                                                    │
  edit / save / watcher  │   AppState.scheduleReindex()              (background queue)       │
 ────────────────────────┼──────────────┐                                                     │
                         │              ▼                                                     │
                         │   ┌─────────────────────┐  parse body   ┌──────────────────────┐   │
                         │   │ MKSearchKit          │──────────────▶│ MarkdownCore          │   │
                         │   │ SearchIndex.upsert   │  [[links]]    │ LinkParser (pure)     │   │
                         │   └──────────┬──────────┘◀──────────────└──────────────────────┘   │
                         │              │ writes                                              │
                         │              ▼                                                     │
                         │   ┌──────────────────────────────┐                                 │
                         │   │ SQLite (App Support, v2)      │                                 │
                         │   │  note · note_fts · ▶link◀     │                                 │
                         │   └──────────┬───────────────────┘                                 │
                         │              │ backlinks(of:)                                      │
                         │              ▼                                                     │
                         │   ┌─────────────────────┐   maps to SDK types   ┌───────────────┐  │
                         │   │ AppCore.Host         │──────────────────────▶│ ExtensionSDK  │  │
                         │   │ (MetadataQuerying)   │  Backlink / publisher │  surface ②    │  │
                         │   └──────────┬──────────┘                       └───────┬───────┘  │
                         │              │ host.query / host.editor.activeNotePath  │ depends  │
                         │              ▼                                          ▼          │
                         │   ┌────────────────────────────────────────────────────────────┐   │
                         │   │ BacklinksPlugin (ExtensionSDK만 의존)                        │   │
                         │   │  activeNotePath ⊕ indexDidUpdate ──▶ query.backlinks(...)   │   │
                         │   │  ▼                                                          │   │
                         │   │  우측 사이드바 패널: 소스 제목 + 문맥 스니펫, 클릭 → openNote │   │
                         │   └────────────────────────────────────────────────────────────┘   │
                         └────────────────────────────────────────────────────────────────────┘

  갱신 흐름:  타이핑/저장/외부변경 ─▶ scheduleReindex ─▶ link 테이블 갱신
              ─▶ indexDidUpdate 발행 ─▶ 패널이 backlinks() 재조회 ─▶ 리스트 갱신
  탐색 흐름:  노트 열림 ─▶ activeNotePath 발행 ─▶ backlinks(현재 노트) ─▶
              스니펫 리스트 ─▶ 클릭 ─▶ workspace.openNote(소스 노트)
```

## 3. Components

### 3.1 `LinkParser` (MarkdownCore — pure, no deps)

```swift
public struct LinkRef: Equatable {
    public let target: String      // normalized: before |/#  (raw case kept)
    public let range: Range<Int>   // UTF-16 range of the whole link in the body
}
public enum LinkParser {
    public static func links(in text: String) -> [LinkRef]
}
```
Recognizes `[[Target]]`, `[[Target|alias]]`, `[[Target#heading]]`, and
markdown `[text](relative.md)` (URL-decoded). Skips: embeds/images `![[…]]`
and `![…](…)`, external `http(s)://…` links, and anything inside fenced code
blocks. Targets keep their raw text; **normalization for matching**
(lowercase + strip `.md`) happens at the storage layer.

### 3.2 MKSearchKit — migration v2 + backlinks query

```sql
-- registerMigration("v2")
CREATE TABLE link (
  source TEXT NOT NULL,   -- vault-relative path of the linking note
  target TEXT NOT NULL    -- normalized: lowercased, .md stripped (may contain '/')
);
CREATE INDEX link_target ON link(target);
```
- `upsert(path:url:mtime:)` additionally deletes `link WHERE source = ?` and
  inserts one row per `LinkParser` hit (MKSearchKit gains a `MarkdownCore`
  dependency — pure lib, acceptable).
- `remove(paths:)` also deletes the paths' link rows.
- New API:
```swift
public struct Backlink {
    public let sourcePath: String
    public let sourceTitle: String
    public let snippet: String           // ±40 around the link, composed-char safe
    public let matchRanges: [Range<Int>] // UTF-16 in snippet
}
public func backlinks(of relativePath: String) throws -> [Backlink]
```
Matching: a note at `Projects/Plan.md` collects links whose target equals
`plan` (filename base) **or** `projects/plan` (full relative, `.md` stripped),
both lowercased. Snippets are built from the source's stored FTS body using
the same boundary-snapped window as `SearchHit`.

### 3.3 SDK ② surface (`ExtensionSDK`)

```swift
public struct SDKBacklink: Identifiable {     // SDK-owned type; MKSearchKit stays hidden
    public let sourcePath: String
    public let sourceTitle: String
    public let snippet: String
    public let matchRanges: [Range<Int>]
    public var id: String { sourcePath }
}
public protocol MetadataQuerying: AnyObject {
    func backlinks(toNoteAt relativePath: String) -> [SDKBacklink]
    var indexDidUpdate: AnyPublisher<Void, Never> { get }
}
// PluginHost gains:    var query: MetadataQuerying { get }
// EditorContext gains: var activeNotePath: AnyPublisher<String?, Never> { get }
```
Host implements both: `backlinks` maps MKSearchKit `Backlink` → `SDKBacklink`;
`indexDidUpdate` = `appState.$searchIndexUpdatedAt.map { _ in () }`;
`activeNotePath` = `appState.$selectedFile.map { vault-relative path }`.

### 3.4 `BacklinksPlugin` (new target; deps: ExtensionSDK only)

`activate(host:)` registers a sidebar view "Backlinks". The view combines
`activeNotePath` and `indexDidUpdate` (Combine `combineLatest`-style refresh),
calls `query.backlinks(toNoteAt:)`, and renders: source title (medium weight)
+ highlighted snippet (caption), count in the header, click →
`workspace.openNote(relativePath:)`. Empty states: "노트를 열면 백링크가
표시됩니다" / "No backlinks". Registering the panel makes the existing shell
show the right sidebar again (3-column rule already in ContentView).

## 4. Testing

Headless (`swift run Checks`):
- `LinkParser`: wikilink/alias/heading/markdown-link/embeds-skipped/external-
  skipped/code-fence-skipped, ranges correct.
- `LinkTable` (MKSearchKit): upsert populates, edit replaces, remove/rename
  drops, `backlinks(of:)` matches by filename base + full path, alias/heading
  links resolve, snippet + ranges sane.
- `BacklinksPlugin` loop: activate via real Host+AppState on a temp vault →
  sidebar contribution registered; `host.query.backlinks` returns the linking
  note (drives the same path the view uses).
- E2E: create A linking `[[Plan]]` → backlinks of `Projects/Plan.md` contains A.

UI: build + screenshot (3-column with panel, snippet highlight).

## 5. Out of scope

Unlinked mentions; graph view; link auto-rename on note rename (separate
epic); SDK `notes(query:)` general queries (Epic F's need decides its shape).
