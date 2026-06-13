# hanji — Dataview TABLE / WHERE / SORT

Design doc · 2026-06-11 · Epic F of the v1 close-out roadmap
Completes the PRD §13 Dataview-lite scope (LIST/TABLE subset) and the planned
MetadataIndex→SQLite consolidation step.

## 1. Goal

Upgrade the `dataview` code-block renderer from `LIST FROM #tag` to the PRD
subset: **TABLE with frontmatter columns, FROM #tag / "folder" / all, WHERE
(AND-chained comparisons), SORT**, with `file.name` / `file.mtime` built-ins —
backed by persisted tag/field tables in the search index.

### Decisions (locked)

- **D-arch:** Approach A — frontmatter+tags become MKSearchKit **migration v3**
  tables (`tag`, `field`), populated during `upsert`; query execution lives in
  MKSearchKit (`dataview(_:)`); the renderer receives results through a closure
  wired by the app. In-memory `MetadataIndex` stays for now but the renderer
  stops using it.
- **D-syntax (subset):** keywords case-insensitive, multiline:
  - `LIST` | `TABLE col1, col2, …`
  - `FROM #tag` | `FROM "folder"` | omitted (whole vault)
  - `WHERE f OP v [AND …]` — OP ∈ `=` `!=` `<` `<=` `>` `>=`; v = number or
    "quoted string"; **missing field ⇒ condition false**
  - `SORT key [ASC|DESC]` (single key; default `file.name` ASC)
  - built-ins usable as column/condition/sort keys: `file.name` (title),
    `file.mtime` (modification time; rendered as `YYYY-MM-DD`)
- **D-frontmatter:** scalars only (`key: value` — quoted/unquoted strings,
  numbers, true/false); lists/nested YAML out of scope; keys lowercased.
- **D-migration:** v3 resets derived rows (Epic D's backfill lesson) so
  existing indexes repopulate tags/fields on the next pass.
- **D-compat:** `DataviewQuery.tagForListQuery` stays as a wrapper; existing
  `LIST FROM #tag` blocks render identically.

## 2. Flow (시각화)

```
 note.md ── upsert ──▶ Tags.extract ───────▶ tag(path, tag)        ┐
            (재색인)    Frontmatter.parse ──▶ field(path, key, val)  │ SQLite v3
                       LinkParser ─────────▶ link(...)   (기존 v2)   ┘
 ```dataview                                        │
 TABLE status FROM #proj   ── DataviewQuery.parse ──┤
 WHERE n >= 2 SORT n DESC      (MarkdownCore, 순수)  ▼
 ```                                   SearchIndex.dataview(query)
                                       source→WHERE→SORT 실행
                                                    │ [DataviewRow]
        에디터 위젯 ◀── DataviewRenderer(테이블/리스트) ◀┘
        (색인 갱신 시 기존 refresh 경로로 자동 재렌더)
```

## 3. Components

### 3.1 `Frontmatter.parse` (MarkdownCore, pure)

`parse(_ text: String) -> [String: String]` — reads the leading `---` block
(must open at line 1 and close), collects `key: value` scalar lines: strips
quotes from quoted strings, keeps numbers/booleans as their literal text, keys
trimmed+lowercased. Non-scalar lines (lists `- x`, nested maps) are skipped.
No frontmatter → `[:]`.

### 3.2 `DataviewQuery.parse` (MarkdownCore, pure)

```swift
public struct ParsedQuery: Equatable {
    public enum Kind: Equatable { case list, table }
    public enum Source: Equatable { case tag(String), folder(String), all }
    public enum Op: String, Equatable { case eq = "=", ne = "!=", lt = "<", le = "<=", gt = ">", ge = ">=" }
    public struct Condition: Equatable { public let field: String; public let op: Op; public let value: String }
    public let kind: Kind
    public let columns: [String]                       // table only; lowercased keys
    public let source: Source
    public let conditions: [Condition]                 // AND-chained
    public let sort: SortKey?
    public struct SortKey: Equatable { public let field: String; public let ascending: Bool }
}
public static func parse(_ source: String) -> ParsedQuery?    // nil = syntax error
```
Tokenized line-by-line on keywords (`TABLE|LIST`, `FROM`, `WHERE`, `SORT`);
`WHERE` splits on ` AND ` (case-insensitive); condition values keep quotes
stripped. `tagForListQuery` becomes `parse(...)` filtered to
`kind == .list && source == .tag`.

### 3.3 MKSearchKit migration v3 + `dataview(_:)`

```sql
CREATE TABLE tag   (path TEXT NOT NULL, tag TEXT NOT NULL);     -- lowercased tag, no '#'
CREATE TABLE field (path TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL);
CREATE INDEX tag_tag ON tag(tag);
CREATE INDEX field_key ON field(key);
-- + derived-row reset (DELETE FROM note / note_fts) for backfill
```
`upsert` adds: delete old tag/field rows for the path, insert `Tags.extract`
(lowercased) and `Frontmatter.parse` results. `remove` deletes both.

```swift
public struct DataviewRow: Identifiable {
    public let path: String
    public let title: String
    public let values: [String?]    // aligned with query.columns ([] for LIST)
    public var id: String { path }
}
public func dataview(_ query: ParsedQuery) throws -> [DataviewRow]
```
Execution: candidates by source (`JOIN tag` / `path LIKE 'folder/%'` escaped /
all notes) with title+mtime; fetch each candidate's fields (single grouped
query); evaluate conditions in Swift — numeric compare when **both** sides
parse as `Double`, else case-insensitive string compare; missing field ⇒
false. Sort by the key (numeric-aware; `file.name` → title, `file.mtime` →
mtime), default title ascending. Column values: field text, `file.name` →
title, `file.mtime` → `YYYY-MM-DD` via MomentFormat-style formatting in Swift.

### 3.4 `DataviewRenderer` (CoreRenderers)

`init(query: @escaping (ParsedQuery) -> [DataviewRow])` replaces
`indexProvider`. HanjiApp wires
`{ [weak appState] q in (try? appState?.searchIndex?.dataview(q)) ?? [] }`.
- parse fail → error widget: "Dataview: 구문을 이해하지 못했어요" + raw query
  in mono.
- LIST → existing bullet list of titles.
- TABLE → header row (`File` + column names) + divider + data rows
  (title, then values; `—` for nil), monospaced-digits, lines clipped to 1.
- Re-rendering on index updates rides the existing editor refresh path
  (widgets rebuild on text/selection changes; an explicit refresh on
  `searchIndexUpdatedAt` is NOT added in this epic — documented limitation:
  a table refreshes when the note re-renders).

### 3.5 Tests

- `Frontmatter` (pure): quoted/unquoted/number/bool, no-frontmatter, unclosed
  block, lists skipped, key lowercasing.
- `DataviewParse` (pure): full TABLE query, LIST + WHERE, FROM folder, no FROM,
  multiple ANDs, sort default direction, syntax errors → nil, legacy
  `tagForListQuery` wrapper intact.
- `DataviewExec` (MKSearchKit, temp vault): tag source, folder source, all
  source; numeric vs string WHERE; missing-field false; SORT numeric DESC +
  `file.mtime`; built-in columns; v3 backfill (reindex after open repopulates
  tags/fields); remove cleans rows.
- Existing `DataviewQuery`/`IndexTags` groups stay green.
- E2E: create two frontmatter notes + a TABLE query through
  `searchIndex.dataview` directly.
- UI: build + screenshot of a rendered table.

## 4. Out of scope

OR/parentheses, functions (`date()`, `length()`), GROUP BY, task queries,
inline `key:: value` fields, clickable rows, live table refresh on index
update without a note re-render.

## 5. Performance (measured/analyzed 2026-06-14)

Variables: N = notes, F = `field` rows, T = `tag` rows, C = notes matched by
`FROM`, f_c = field rows of those candidates, k = WHERE conditions, R = result
rows, cols = TABLE columns. `dataview(_:)` runs in `SearchIndex.swift`.

Per-query cost, by phase:

| Phase | Code | Time | Space |
|---|---|---|---|
| Source filter — `FROM #tag` | `JOIN tag` (tag(tag) index, note.path PK) | O(log T + C·log N) | O(C) |
| Source filter — folder / all | `note` scan (LIKE prefix not index-optimized) | O(N) | O(C) |
| Field fetch | `SELECT … FROM field WHERE path IN (…)` — **no `field(path)` index → full scan** | **O(F)** | O(f_c) |
| fieldMap build | dictionary fill | O(f_c) | O(f_c) |
| WHERE filter | numeric if both `Double`, else CI string; missing field ⇒ false | O(C·k) | — |
| SORT | `sorted`; `sortValue` recomputed per comparison (not memoized) | O(R log R) | — |
| Render | `Grid` (eager, not lazy) + synchronous `fittingSize` height reserve | O(R·cols) | O(R·cols) |

**Total: time O(F + N + R·log R); space O(C + f_c + R).** The field fetch is
O(F) (not O(C)) because `field` is indexed on `key`, not `path`.

**Decision — no optimization for v1.** A full scan of F = 10,000 small SQLite
rows is ~1–3 ms (SQLite scans millions of rows/sec); negligible even though the
complexity is O(F) rather than O(C). Optimization is deferred until vaults reach
hundreds of thousands of field rows or tens of thousands of notes.

Structural notes for that future scale (tracked, NOT fixed now):
1. `dataview` runs on the **main thread** via `makeView`, re-executed on every
   note re-render, **no result cache** — the first thing to bite under repeated
   edits on a large query.
2. `WHERE path IN (…)` binds one placeholder per candidate; a broad source
   (`FROM` omitted / large folder) on a vault exceeding
   `SQLITE_MAX_VARIABLE_NUMBER` (~32,766 on current macOS SQLite) makes the
   query **throw → empty result**. Batch the IN-list or use a temp table.
3. Add migration v4 index `field(path)` (and `tag(path)`) → field fetch becomes
   O(C·log F + f_c); also speeds the upsert/remove deletes.
4. `Tags.extract` scans the whole body **including fenced code blocks**, so a
   note whose `dataview` block literally contains `#tag` is tagged with it
   (observed: a `LIST FROM #proj` dashboard lists itself). Skip fences in tag
   extraction.
