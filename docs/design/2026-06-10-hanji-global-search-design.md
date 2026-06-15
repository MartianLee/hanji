# hanji — Global Search (FTS5) + Persistent Incremental Index

Design doc · 2026-06-10 · Epic C of the v1 close-out roadmap
Builds on [`2026-06-06-native-markdown-editor-design.md`](2026-06-06-native-markdown-editor-design.md) (M3: "글로벌 검색(FTS, v1 확정)").

## 1. Goal

Full-text search across the vault (titles + bodies, Korean-friendly), backed by a
persistent SQLite index that updates incrementally — closing the largest remaining
v1 gap. UI is an Obsidian-style sidebar search panel (⇧⌘F).

### Decisions (locked)

- **D-dep:** Adopt **GRDB.swift** (first external dependency; MIT, proven in
  Signal/DuckDuckGo/Arc). Revising the project's zero-dependency stance was
  deliberate: GRDB's migrator and ValueObservation directly serve Epics D/F.
  The dependency is **isolated to one new target** (`SearchKit`).
- **D-ui:** **Sidebar search panel** (not a palette): the left sidebar gains two
  icon tabs — Files / Search — like a minimal Obsidian ribbon.
- **D-location:** Index DB lives **outside the vault** at
  `~/Library/Application Support/hanji/index/<sha256-of-vault-path>.db`.
  Reason: don't pollute the user's vault, and index writes inside the vault
  would wake our own FSEvents watcher → reindex feedback loop.
- **D-korean:** FTS5 **trigram tokenizer** so sub-word matches work for Korean
  ("운동" matches "헬스운동화"); queries shorter than 3 characters fall back to
  `LIKE`.
- **D-arch:** Approach A — incremental adoption. SQLite/FTS5 is the source of
  truth for *search*; the in-memory `MetadataIndex` (titles/tags, used by
  Dataview-lite) stays for now and merges into SQLite in Epic F.

## 2. Targets & dependencies

```
Package.swift: + .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
SearchKit (NEW) → GRDB                      ← the ONLY target that knows GRDB
AppCore         → SearchKit (+ existing)
HanjiApp    → search panel UI
Checks          → SearchKit (headless index tests on temp DBs)
```

## 3. SearchKit

### 3.1 Schema (GRDB migrator, v1)

```sql
CREATE TABLE note (
  path  TEXT PRIMARY KEY,    -- vault-relative
  title TEXT NOT NULL,
  mtime DOUBLE NOT NULL      -- contentModificationDate, for skip-unchanged
);
CREATE VIRTUAL TABLE note_fts USING fts5(
  path UNINDEXED,            -- row identity for upsert/delete + hit mapping
  title, body,               -- stored, so snippets read straight from the row
  tokenize='trigram'
);
```

Upsert = `DELETE FROM note_fts WHERE path = ?` then `INSERT`; vault sizes
(hundreds–thousands of notes) make the unindexed-path scan negligible.

(Epic D adds a `link` table as migration v2; Epic F adds frontmatter fields.)

### 3.2 API

```swift
public final class SearchIndex {
    public init(vaultRoot: URL) throws            // opens/creates the per-vault DB
    public func reindexAll(vault root: URL) throws    // walk .md files; skip when mtime unchanged
    public func reindex(paths: [String], vault root: URL) throws   // incremental upsert
    public func remove(paths: [String]) throws
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit]
    public static func indexFileURL(forVault root: URL) -> URL    // App Support path
}

public struct SearchHit {
    public let path: String          // vault-relative
    public let title: String
    public let snippet: String       // ±40 chars around the first match
    public let matchRanges: [Range<Int>]   // UTF-16 ranges inside `snippet` to highlight
    public let firstMatchOffset: Int?      // UTF-16 offset in the full body (caret jump)
    public let score: Double         // bm25 (lower = better, FTS5 convention)
}
```

- `search`: query length ≥ 3 → FTS5 `MATCH` with bm25 ranking; < 3 → `LIKE
  '%q%'` over title/body (escaped) ordered by title match first. Both paths
  produce `SearchHit`s with the same shape.
- Snippet/offset are computed in Swift from the body stored in the FTS row
  (locate the first case-insensitive occurrence) — avoids FTS5 `snippet()`
  offset quirks with trigram and keeps highlight ranges UTF-16-exact for AppKit.

## 4. AppState integration (incremental)

- `openVault`: create `SearchIndex`, then `reindexAll` on a background queue
  (mtime-skip makes warm reopen cheap). Failures degrade silently: search
  returns empty, an error line shows in the search panel.
- Every write path the app owns — `save()`, `createNote`, `newNote`, `rename`,
  `move`, `delete`, `duplicate`, `importNotes`, undo — and the FS-watcher's
  `reloadTree()` call `reindexChanged()`: collect affected vault-relative paths
  and `reindex(paths:)` / `remove(paths:)` on the background queue. The watcher
  path may over-approximate (reindexAll with mtime-skip) — correct and cheap.
- No `@Published` results in AppState; the panel queries `SearchIndex` directly
  (debounced). AppState just exposes `searchIndex: SearchIndex?`.

## 5. UI — sidebar modes + search panel

- `UIState.sidebarMode: SidebarMode = .files` (`.files | .search`).
- Sidebar top: two icon buttons (`doc.text` / `magnifyingglass`) toggling the
  mode; the active one is highlighted. Files mode = existing tree (unchanged).
- Search mode: search field (auto-focused) + results list.
  - Typing debounces 200 ms, then queries off-main; results render as
    **title + snippet with the match ranges bolded/tinted**.
  - Click/⏎ opens the note and sets `pendingCursorOffset = firstMatchOffset`
    (existing caret-jump infra) so the editor lands on the match.
  - Empty query → hint text; no hits → "No results".
- **⇧⌘F** (Go menu: "Search in Vault") switches to search mode and focuses the
  field. ⌘O/⌘P unchanged.

## 6. Testing

Headless (`swift run Checks`, temp vault + temp DB):
- index build, Korean sub-word match (trigram), English match, title match
- short-query LIKE fallback (1–2 chars incl. Korean)
- snippet content + highlight ranges + firstMatchOffset correctness
- mtime skip (reindexAll twice → second is no-op), incremental `reindex(paths:)`
  after an edit, `remove` after delete
- per-vault DB path derivation (sha256, App Support)

E2E scenario gains: save note with a unique phrase → `search` finds it with the
right path/snippet. Panel UI: build + screenshot.

## 7. Out of scope (follow-ups)

Search operators (`path:`, `tag:`), regex/case toggles, search-and-replace,
result count badges, MetadataIndex unification (Epic F), backlink `link` table
(Epic D, schema v2).
