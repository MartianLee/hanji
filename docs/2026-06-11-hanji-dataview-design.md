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
