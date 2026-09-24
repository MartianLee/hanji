# Dataview TABLE/WHERE/SORT Implementation Plan

**Goal:** Upgrade the `dataview` block from `LIST FROM #tag` to TABLE with frontmatter columns, FROM #tag/"folder"/all, AND-chained WHERE comparisons, SORT, and `file.name`/`file.mtime` built-ins — backed by persisted tag/field tables.

**Architecture:** Pure `Frontmatter.parse` + an extended `DataviewQuery` (parser + `Parsed`/`ResultRow` types) live in MarkdownCore so both MKSearchKit and CoreRenderers can share them without new coupling. MKSearchKit migration v3 adds `tag`/`field` tables (populated in `upsert`, reset for backfill — Epic D lesson) and `dataview(_:)` executes source→WHERE→SORT. `DataviewRenderer` swaps its `indexProvider` for a query closure wired from `appState.searchIndex`.

**Tech Stack:** Swift 5.10/SPM, GRDB (MKSearchKit-only invariant), custom Checks runner.

**Spec:** `docs/design/2026-06-11-hanji-dataview-design.md`

**Conventions:** TDD via `Sources/Checks` (`expect`/`expectEqual`, register in `main.swift`, `swift run Checks <Group>`); red = build failure for new symbols; commits to main. Search module = **MKSearchKit**. READ real files before editing.

---

## File structure

- Create `Sources/MarkdownCore/Frontmatter.swift` — scalar frontmatter parser.
- Modify `Sources/MarkdownCore/DataviewQuery.swift` — `Parsed`, `ResultRow`, `parse`, legacy wrapper.
- Modify `Sources/MKSearchKit/SearchIndex.swift` — migration v3, tag/field upkeep, `dataview(_:)`.
- Modify `Sources/CoreRenderers/DataviewRenderer.swift` — query-closure init, TABLE grid, error widget.
- Modify `Sources/HanjiApp/HanjiApp.swift` — renderer wiring.
- Tests: `Sources/Checks/FrontmatterChecks.swift`, additions to `DataviewChecks.swift` + `SearchIndexChecks.swift` + `E2EChecks.swift`; registrations in `main.swift`. `README.md`.

---

## Task 1: Frontmatter.parse (pure)

**Files:**
- Create: `Sources/MarkdownCore/Frontmatter.swift`
- Create: `Sources/Checks/FrontmatterChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Failing test** — `Sources/Checks/FrontmatterChecks.swift`

```swift
import Foundation
import MarkdownCore

func frontmatterChecks() {
    let doc = """
    ---
    status: active
    priority: 3
    title: "Quoted Title"
    nick: '단따옴표'
    done: true
    tags:
      - a
      - b
    empty:
    ---
    # Body
    key: not frontmatter
    """
    let fm = Frontmatter.parse(doc)
    expectEqual(fm["status"], "active", "unquoted string")
    expectEqual(fm["priority"], "3", "number kept as text")
    expectEqual(fm["title"], "Quoted Title", "double quotes stripped")
    expectEqual(fm["nick"], "단따옴표", "single quotes stripped")
    expectEqual(fm["done"], "true", "boolean kept as text")
    expect(fm["tags"] == nil, "list values skipped")
    expect(fm["- a"] == nil && fm["a"] == nil, "list items not keys")
    expect(fm["empty"] == nil, "empty value skipped")
    expect(fm["key"] == nil, "body lines not parsed")

    expectEqual(Frontmatter.parse("no frontmatter").count, 0, "no block → empty")
    expectEqual(Frontmatter.parse("---\nkey: v\nno close").count, 0, "unclosed block → empty")
    expectEqual(Frontmatter.parse("---\nKEY: v\n---\n").count, 1, "parses")
    expectEqual(Frontmatter.parse("---\nKEY: v\n---\n")["key"], "v", "keys lowercased")
}
```

- [ ] **Step 2: Register** — `("Frontmatter", frontmatterChecks),` in `main.swift` (after `("HRParser", ...)`).

- [ ] **Step 3: Red** — `swift run Checks Frontmatter` → `cannot find 'Frontmatter' in scope`.

- [ ] **Step 4: Implement `Sources/MarkdownCore/Frontmatter.swift`**

```swift
import Foundation

/// Scalar `key: value` pairs from a leading frontmatter block (opened by `---`
/// on line 1, closed by `---`). Lists, nested maps (indented lines), and empty
/// values are skipped; quotes are stripped; keys are lowercased.
public enum Frontmatter {
    public static func parse(_ text: String) -> [String: String] {
        let ns = text as NSString
        guard ns.length > 0 else { return [:] }
        let firstLine = ns.lineRange(for: NSRange(location: 0, length: 0))
        var first = ns.substring(with: firstLine)
        if first.hasSuffix("\n") { first.removeLast() }
        guard first.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var pending: [String: String] = [:]
        var pos = NSMaxRange(firstLine)
        while pos < ns.length {
            let lr = ns.lineRange(for: NSRange(location: pos, length: 0))
            var line = ns.substring(with: lr)
            if line.hasSuffix("\n") { line.removeLast() }
            if line.trimmingCharacters(in: .whitespaces) == "---" { return pending }   // closed
            // Indented lines belong to nested structures — skip them.
            if !line.hasPrefix(" ") && !line.hasPrefix("\t"),
               let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !key.hasPrefix("-"), !value.isEmpty {
                    if value.count >= 2,
                       (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                       (value.hasPrefix("'") && value.hasSuffix("'")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    pending[key] = value
                }
            }
            pos = NSMaxRange(lr)
            if lr.length == 0 { break }
        }
        return [:]   // never closed → not frontmatter
    }
}
```

- [ ] **Step 5: Green** — `swift run Checks Frontmatter` → ✅ (12 assertions).

- [ ] **Step 6: Commit**

```bash
git add Sources/MarkdownCore/Frontmatter.swift Sources/Checks/FrontmatterChecks.swift Sources/Checks/main.swift
git commit -m "feat(core): scalar frontmatter parser"
```

---

## Task 2: DataviewQuery.parse — Parsed/ResultRow + legacy wrapper

**Files:**
- Modify: `Sources/MarkdownCore/DataviewQuery.swift` (READ it first; it currently holds `tagForListQuery`)
- Modify: `Sources/Checks/DataviewChecks.swift` (append a group; existing `dataviewQueryChecks` MUST stay green)
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Failing test** — append to `Sources/Checks/DataviewChecks.swift`:

```swift
func dataviewParseChecks() {
    // Full TABLE query.
    let q = DataviewQuery.parse("""
    TABLE status, priority FROM #proj
    WHERE priority >= 2 AND status != "done"
    SORT priority DESC
    """)
    expect(q != nil, "table query parses")
    expectEqual(q?.kind, .table, "kind table")
    expectEqual(q?.columns ?? [], ["status", "priority"], "columns kept in order, lowercased")
    expectEqual(q?.source, .tag("proj"), "tag source")
    expectEqual(q?.conditions.count, 2, "two AND conditions")
    expectEqual(q?.conditions.first, DataviewQuery.Condition(field: "priority", op: .ge, value: "2"), "numeric condition")
    expectEqual(q?.conditions.last, DataviewQuery.Condition(field: "status", op: .ne, value: "done"), "string condition unquoted")
    expectEqual(q?.sort, DataviewQuery.SortKey(field: "priority", ascending: false), "sort desc")

    // LIST + folder source + default sort direction.
    let l = DataviewQuery.parse("LIST FROM \"Projects/Sub\" SORT file.name")
    expectEqual(l?.kind, .list, "list kind")
    expectEqual(l?.source, .folder("Projects/Sub"), "folder source")
    expectEqual(l?.sort, DataviewQuery.SortKey(field: "file.name", ascending: true), "sort default asc")

    // No FROM → whole vault; no WHERE/SORT.
    let all = DataviewQuery.parse("TABLE status")
    expectEqual(all?.source, .all, "no FROM → all")
    expect(all?.conditions.isEmpty ?? false, "no conditions")
    expect(all?.sort == nil, "no sort")

    // Errors → nil.
    expect(DataviewQuery.parse("PIVOT x") == nil, "unknown verb")
    expect(DataviewQuery.parse("LIST FROM proj") == nil, "bare FROM target")
    expect(DataviewQuery.parse("TABLE a WHERE b ~ 2") == nil, "unknown operator")

    // Legacy wrapper unchanged.
    expectEqual(DataviewQuery.tagForListQuery("LIST FROM #proj"), "proj", "legacy wrapper")
    expect(DataviewQuery.tagForListQuery("TABLE foo") == nil, "wrapper rejects table")
}
```

- [ ] **Step 2: Register** — `("DataviewParse", dataviewParseChecks),` after `("DataviewQuery", ...)`.

- [ ] **Step 3: Red** — `swift run Checks DataviewParse` → missing `DataviewQuery.parse`/`Condition`.

- [ ] **Step 4: Implement** — replace `Sources/MarkdownCore/DataviewQuery.swift` with:

```swift
import Foundation

/// The `dataview` block's query language — the PRD's LIST/TABLE subset.
public enum DataviewQuery {
    public enum Kind: Equatable { case list, table }
    public enum Source: Equatable { case tag(String), folder(String), all }
    public enum Op: String, Equatable, CaseIterable { case le = "<=", ge = ">=", ne = "!=", eq = "=", lt = "<", gt = ">" }
    public struct Condition: Equatable {
        public let field: String
        public let op: Op
        public let value: String
        public init(field: String, op: Op, value: String) { self.field = field; self.op = op; self.value = value }
    }
    public struct SortKey: Equatable {
        public let field: String
        public let ascending: Bool
        public init(field: String, ascending: Bool) { self.field = field; self.ascending = ascending }
    }
    public struct Parsed: Equatable {
        public let kind: Kind
        public let columns: [String]
        public let source: Source
        public let conditions: [Condition]
        public let sort: SortKey?
        public init(kind: Kind, columns: [String], source: Source, conditions: [Condition], sort: SortKey?) {
            self.kind = kind; self.columns = columns; self.source = source
            self.conditions = conditions; self.sort = sort
        }
    }
    /// One result row (defined here so renderers don't import the index module).
    public struct ResultRow: Identifiable {
        public let path: String
        public let title: String
        public let values: [String?]
        public var id: String { path }
        public init(path: String, title: String, values: [String?]) {
            self.path = path; self.title = title; self.values = values
        }
    }

    private static let shape = try! NSRegularExpression(
        pattern: #"^\s*(LIST|TABLE)\b(.*?)(?:\bFROM\b(.*?))?(?:\bWHERE\b(.*?))?(?:\bSORT\b(.*?))?\s*$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// nil = syntax error (renderer shows an error widget).
    public static func parse(_ source: String) -> Parsed? {
        let flat = source.replacingOccurrences(of: "\n", with: " ")
        let ns = flat as NSString
        guard let m = shape.firstMatch(in: flat, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r).trimmingCharacters(in: .whitespaces)
        }
        let kind: Kind = group(1)?.uppercased() == "TABLE" ? .table : .list

        let colsPart = group(2) ?? ""
        var columns: [String] = []
        if kind == .table {
            columns = colsPart.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        } else if !colsPart.isEmpty {
            return nil   // LIST takes no columns
        }

        let source: Source
        switch group(3) {
        case nil, "": source = .all
        case let f? where f.hasPrefix("#") && f.count > 1:
            source = .tag(String(f.dropFirst()).lowercased())
        case let f? where f.hasPrefix("\"") && f.hasSuffix("\"") && f.count >= 2:
            source = .folder(String(f.dropFirst().dropLast()))
        default: return nil
        }

        var conditions: [Condition] = []
        if let wherePart = group(4), !wherePart.isEmpty {
            for clause in splitCaseInsensitive(wherePart, on: " AND ") {
                guard let cond = parseCondition(clause) else { return nil }
                conditions.append(cond)
            }
        }

        var sort: SortKey?
        if let sortPart = group(5), !sortPart.isEmpty {
            let bits = sortPart.split(separator: " ").map(String.init)
            guard bits.count <= 2, let field = bits.first else { return nil }
            var ascending = true
            if bits.count == 2 {
                switch bits[1].uppercased() {
                case "ASC": ascending = true
                case "DESC": ascending = false
                default: return nil
                }
            }
            sort = SortKey(field: field.lowercased(), ascending: ascending)
        }
        return Parsed(kind: kind, columns: columns, source: source, conditions: conditions, sort: sort)
    }

    private static func parseCondition(_ clause: String) -> Condition? {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        for op in Op.allCases {   // <= and >= before < and > (CaseIterable order above)
            if let range = trimmed.range(of: op.rawValue) {
                let field = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces).lowercased()
                var value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !field.isEmpty, !value.isEmpty else { return nil }
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                return Condition(field: field, op: op, value: value)
            }
        }
        return nil
    }

    private static func splitCaseInsensitive(_ s: String, on separator: String) -> [String] {
        var parts: [String] = []
        var rest = Substring(s)
        while let r = rest.range(of: separator, options: [.caseInsensitive]) {
            parts.append(String(rest[..<r.lowerBound]))
            rest = rest[r.upperBound...]
        }
        parts.append(String(rest))
        return parts
    }

    /// Legacy v0 helper (`LIST FROM #tag` → tag) kept for compatibility.
    public static func tagForListQuery(_ source: String) -> String? {
        guard let q = parse(source), q.kind == .list, case .tag(let t) = q.source else { return nil }
        return t
    }
}
```
⚠️ The old file declared `tagForListQuery` with specific behavior — the existing `dataviewQueryChecks` group asserts `"LIST FROM #proj"` → `"proj"`, case-insensitive, `"TABLE foo"` → nil, `"LIST FROM proj"` → nil. The wrapper above preserves all four. `!=` must be tried before `=` — the `Op.allCases` order above guarantees `<=`, `>=`, `!=` precede `=`, `<`, `>`.

- [ ] **Step 5: Green** — `swift run Checks DataviewParse && swift run Checks DataviewQuery` → both ✅.

- [ ] **Step 6: Commit**

```bash
git add Sources/MarkdownCore/DataviewQuery.swift Sources/Checks/DataviewChecks.swift Sources/Checks/main.swift
git commit -m "feat(core): dataview query parser — TABLE/FROM/WHERE/SORT subset"
```

---

## Task 3: MKSearchKit v3 — tag/field tables + dataview execution

**Files:**
- Modify: `Sources/MKSearchKit/SearchIndex.swift`
- Modify: `Sources/Checks/SearchIndexChecks.swift` (append group)
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Failing test** — append to `Sources/Checks/SearchIndexChecks.swift` (file already imports MarkdownCore? if not, add `import MarkdownCore`):

```swift
func dataviewExecChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-dv-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault.appendingPathComponent("Projects"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "---\nstatus: active\npriority: 3\n---\n#proj alpha".write(to: vault.appendingPathComponent("Projects/Alpha.md"), atomically: true, encoding: .utf8)
    try? "---\nstatus: done\npriority: 10\n---\n#proj beta".write(to: vault.appendingPathComponent("Projects/Beta.md"), atomically: true, encoding: .utf8)
    try? "---\nstatus: active\npriority: 2\n---\n#proj 감마".write(to: vault.appendingPathComponent("Gamma.md"), atomically: true, encoding: .utf8)
    try? "no tag, no fields".write(to: vault.appendingPathComponent("Plain.md"), atomically: true, encoding: .utf8)

    guard let index = try? SearchIndex(vaultRoot: vault) else { expect(false, "index opens"); return }
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    try? index.reindexAll(vault: vault)

    // TABLE … FROM #tag WHERE … SORT … (numeric compare + desc).
    let q = DataviewQuery.parse("TABLE status, priority FROM #proj WHERE priority >= 2 AND status != \"done\" SORT priority DESC")!
    let rows = (try? index.dataview(q)) ?? []
    expectEqual(rows.map(\.title), ["Alpha", "Gamma"], "filtered + numeric sort desc")
    expectEqual(rows.first?.values, ["active", "3"], "column values aligned")

    // Folder source.
    let folder = DataviewQuery.parse("LIST FROM \"Projects\"")!
    expectEqual((try? index.dataview(folder))?.map(\.title).sorted(), ["Alpha", "Beta"], "folder source")

    // All source + missing field ⇒ condition false.
    let all = DataviewQuery.parse("TABLE status WHERE status = \"active\"")!
    expectEqual((try? index.dataview(all))?.count, 2, "missing-field notes excluded")

    // Built-ins: sort by file.mtime works; file.name column resolves.
    let builtin = DataviewQuery.parse("TABLE file.name FROM #proj SORT file.mtime ASC")!
    let b = (try? index.dataview(builtin)) ?? []
    expectEqual(b.count, 3, "builtin query returns all tagged")
    expectEqual(b.first?.values.first ?? nil, b.first?.title, "file.name column mirrors title")

    // Editing away the tag/fields drops the note from results.
    try? "no more tag".write(to: vault.appendingPathComponent("Gamma.md"), atomically: true, encoding: .utf8)
    try? index.reindex(paths: ["Gamma.md"], vault: vault)
    let after = (try? index.dataview(folder.kind == .list ? DataviewQuery.parse("LIST FROM #proj")! : folder)) ?? []
    expect(!after.contains { $0.title == "Gamma" }, "reindex removes stale tag rows")
}
```

- [ ] **Step 2: Register** — `("DataviewExec", dataviewExecChecks),` after `("LinkTable", ...)`.

- [ ] **Step 3: Red** — `swift run Checks DataviewExec` → `no member 'dataview'`.

- [ ] **Step 4: Implement in `Sources/MKSearchKit/SearchIndex.swift`**

In `init`, after `registerMigration("v2")` (REMEMBER: never edit applied migrations — this is a NEW one):
```swift
        migrator.registerMigration("v3") { db in
            try db.create(table: "tag") { t in
                t.column("path", .text).notNull()
                t.column("tag", .text).notNull()      // lowercased, no '#'
            }
            try db.create(table: "field") { t in
                t.column("path", .text).notNull()
                t.column("key", .text).notNull()      // lowercased
                t.column("value", .text).notNull()
            }
            try db.create(indexOn: "tag", columns: ["tag"])
            try db.create(indexOn: "field", columns: ["key"])
            // Backfill: force re-derive (mtime-skip would starve the new tables).
            try db.execute(sql: "DELETE FROM note")
            try db.execute(sql: "DELETE FROM note_fts")
        }
```
In `upsert`, inside the write closure after the link inserts:
```swift
            try db.execute(sql: "DELETE FROM tag WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM field WHERE path = ?", arguments: [path])
            for tag in Tags.extract(from: body) {
                try db.execute(sql: "INSERT INTO tag (path, tag) VALUES (?, ?)",
                               arguments: [path, tag.lowercased()])
            }
            for (key, value) in Frontmatter.parse(body) {
                try db.execute(sql: "INSERT INTO field (path, key, value) VALUES (?, ?, ?)",
                               arguments: [path, key, value])
            }
```
In `remove`, inside the loop:
```swift
                try db.execute(sql: "DELETE FROM tag WHERE path = ?", arguments: [path])
                try db.execute(sql: "DELETE FROM field WHERE path = ?", arguments: [path])
```
Append to the class:
```swift
    // MARK: - Dataview

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Execute a parsed dataview query: source filter → WHERE → SORT.
    public func dataview(_ query: DataviewQuery.Parsed) throws -> [DataviewQuery.ResultRow] {
        struct Candidate { let path: String; let title: String; let mtime: Double; var fields: [String: String] }
        var candidates: [Candidate] = try dbQueue.read { db in
            let rows: [Row]
            switch query.source {
            case .tag(let tag):
                rows = try Row.fetchAll(db, sql: """
                    SELECT n.path AS path, n.title AS title, n.mtime AS mtime
                    FROM note n JOIN tag t ON t.path = n.path WHERE t.tag = ?
                    """, arguments: [tag.lowercased()])
            case .folder(let folder):
                let escaped = folder.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                rows = try Row.fetchAll(db, sql: """
                    SELECT path, title, mtime FROM note WHERE path LIKE ? ESCAPE '\\'
                    """, arguments: [escaped + "/%"])
            case .all:
                rows = try Row.fetchAll(db, sql: "SELECT path, title, mtime FROM note")
            }
            return rows.map { Candidate(path: $0["path"], title: $0["title"], mtime: $0["mtime"], fields: [:]) }
        }
        guard !candidates.isEmpty else { return [] }

        let fieldRows: [(String, String, String)] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT path, key, value FROM field")
                .map { ($0["path"], $0["key"], $0["value"]) }
        }
        var fieldMap: [String: [String: String]] = [:]
        for (path, key, value) in fieldRows { fieldMap[path, default: [:]][key] = value }
        for i in candidates.indices { candidates[i].fields = fieldMap[candidates[i].path] ?? [:] }

        func value(_ c: Candidate, _ key: String) -> String? {
            switch key {
            case "file.name": return c.title
            case "file.mtime": return Self.dayFormatter.string(from: Date(timeIntervalSince1970: c.mtime))
            default: return c.fields[key]
            }
        }

        let filtered = candidates.filter { c in
            query.conditions.allSatisfy { cond in
                guard let lhs = value(c, cond.field) else { return false }   // missing field ⇒ false
                if let ln = Double(lhs), let rn = Double(cond.value) {
                    switch cond.op {
                    case .eq: return ln == rn
                    case .ne: return ln != rn
                    case .lt: return ln < rn
                    case .le: return ln <= rn
                    case .gt: return ln > rn
                    case .ge: return ln >= rn
                    }
                }
                let cmp = lhs.caseInsensitiveCompare(cond.value)
                switch cond.op {
                case .eq: return cmp == .orderedSame
                case .ne: return cmp != .orderedSame
                case .lt: return cmp == .orderedAscending
                case .le: return cmp != .orderedDescending
                case .gt: return cmp == .orderedDescending
                case .ge: return cmp != .orderedAscending
                }
            }
        }

        let sortField = query.sort?.field ?? "file.name"
        let ascending = query.sort?.ascending ?? true
        func sortValue(_ c: Candidate) -> (Double?, String) {
            if sortField == "file.mtime" { return (c.mtime, "") }
            let v = value(c, sortField) ?? ""
            return (Double(v), v.lowercased())
        }
        let sorted = filtered.sorted { a, b in
            let av = sortValue(a), bv = sortValue(b)
            let comparison: ComparisonResult
            if let an = av.0, let bn = bv.0 {
                comparison = an == bn ? .orderedSame : (an < bn ? .orderedAscending : .orderedDescending)
            } else if av.1 != bv.1 {
                comparison = av.1 < bv.1 ? .orderedAscending : .orderedDescending
            } else {
                comparison = .orderedSame
            }
            if comparison == .orderedSame {
                return a.title.lowercased() < b.title.lowercased()   // stable tiebreak
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }

        return sorted.map { c in
            DataviewQuery.ResultRow(path: c.path, title: c.title,
                                    values: query.columns.map { value(c, $0) })
        }
    }
```

- [ ] **Step 5: Green** — `swift run Checks DataviewExec` ✅; regressions `swift run Checks IndexTags && swift run Checks LinkTable && swift run Checks SearchQuery` ✅; full suite ✅.

- [ ] **Step 6: Commit**

```bash
git add Sources/MKSearchKit/SearchIndex.swift Sources/Checks/SearchIndexChecks.swift Sources/Checks/main.swift
git commit -m "feat(search): tag/field tables (schema v3, backfilled) + dataview execution"
```

---

## Task 4: Renderer rework + wiring + E2E + README

**Files:**
- Modify: `Sources/CoreRenderers/DataviewRenderer.swift` (full rewrite below)
- Modify: `Sources/HanjiApp/HanjiApp.swift`
- Modify: `Sources/Checks/E2EChecks.swift`
- Modify: `README.md`

- [ ] **Step 1: Rewrite `Sources/CoreRenderers/DataviewRenderer.swift`**

```swift
import SwiftUI
import ExtensionSDK
import MarkdownCore

/// Renders a ```dataview block: LIST as bullets, TABLE as a grid. Queries run
/// through a closure so this stays decoupled from the index implementation.
public struct DataviewRenderer: CodeBlockRenderer {
    public let language = "dataview"
    let runQuery: (DataviewQuery.Parsed) -> [DataviewQuery.ResultRow]

    public init(query: @escaping (DataviewQuery.Parsed) -> [DataviewQuery.ResultRow]) {
        self.runQuery = query
    }

    public func makeView(source: String) -> AnyView {
        guard let parsed = DataviewQuery.parse(source) else {
            return AnyView(DataviewErrorView(source: source))
        }
        let rows = runQuery(parsed)
        switch parsed.kind {
        case .list:
            return AnyView(DataviewListView(rows: rows))
        case .table:
            return AnyView(DataviewTableView(columns: parsed.columns, rows: rows))
        }
    }
}

struct DataviewListView: View {
    let rows: [DataviewQuery.ResultRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if rows.isEmpty {
                Text("No results").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    Text("•  \(row.title)").font(.callout)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct DataviewTableView: View {
    let columns: [String]
    let rows: [DataviewQuery.ResultRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("No results").font(.callout).foregroundStyle(.secondary).padding(10)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("File").font(.caption.bold())
                        ForEach(columns, id: \.self) { Text($0).font(.caption.bold()) }
                    }
                    Divider()
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.title).font(.callout).lineLimit(1)
                            ForEach(Array(row.values.enumerated()), id: \.offset) { _, v in
                                Text(v ?? "—").font(.callout).monospacedDigit().lineLimit(1)
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct DataviewErrorView: View {
    let source: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dataview: 구문을 이해하지 못했어요").font(.caption).foregroundStyle(.red)
            Text(source.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
```
(Opaque `.textBackgroundColor` backgrounds are required — overlay widgets must cover the raw source.)

- [ ] **Step 2: Rewire `Sources/HanjiApp/HanjiApp.swift`** — replace the old registration
```swift
                    h.renderers.register(DataviewRenderer(indexProvider: { [weak appState] in
                        appState?.index ?? MetadataIndex()
                    }))
```
with:
```swift
                    h.renderers.register(DataviewRenderer(query: { [weak appState] parsed in
                        (try? appState?.searchIndex?.dataview(parsed)) ?? []
                    }))
```
Remove the now-unused `MetadataIndex` import only if nothing else in the file uses it (grep first — `VaultKit` import may still be needed elsewhere).

- [ ] **Step 3: E2E step** — in `Sources/Checks/E2EChecks.swift`, right after the backlinks step (4c), insert:

```swift
    // 4d. Dataview: frontmatter fields queryable as a TABLE.
    try? "---\nstatus: active\npriority: 5\n---\n#dv one".write(to: root.appendingPathComponent("DV1.md"), atomically: true, encoding: .utf8)
    try? "---\nstatus: done\npriority: 1\n---\n#dv two".write(to: root.appendingPathComponent("DV2.md"), atomically: true, encoding: .utf8)
    try? appState.searchIndex?.reindexAll(vault: root)
    let dvq = DataviewQuery.parse("TABLE status FROM #dv WHERE priority > 2")!
    let dv = (try? appState.searchIndex?.dataview(dvq)) ?? []
    expectEqual(dv.map(\.title), ["DV1"], "E2E: dataview TABLE filters by frontmatter")
    expectEqual(dv.first?.values.first ?? nil, "active", "E2E: column value")
```

- [ ] **Step 4: README** — extend the Dataview bullet:
```markdown
  render as inline widgets that reserve their own height (raw source revealed while
  editing). Built-in: **mermaid** diagrams (WKWebView), **Dataview** (`LIST`/`TABLE`
  with `FROM #tag`/`"folder"`, `WHERE`, `SORT`, frontmatter fields + `file.name`/
  `file.mtime`), and a `card` renderer
```
(Replace the existing `**Dataview-lite** (`LIST FROM #tag`)` phrase.)

- [ ] **Step 5: Verify** — `swift build` ✅; `swift run Checks` full ✅; `./Scripts/e2e.sh` ✅.

- [ ] **Step 6: Commit**

```bash
git add Sources/CoreRenderers/DataviewRenderer.swift Sources/HanjiApp/HanjiApp.swift Sources/Checks/E2EChecks.swift README.md
git commit -m "feat(dataview): TABLE rendering over the index (FROM/WHERE/SORT, built-ins)"
```

---

## Self-review (vs spec)

- §3.1 Frontmatter → Task 1 (incl. unclosed/lists/indent-skip/lowercase). §3.2 Parsed/parse/ResultRow/wrapper → Task 2 (ResultRow placed in MarkdownCore so CoreRenderers needs no MKSearchKit import — matches the spec's decoupling intent). §3.3 v3 schema + upsert/remove + dataview exec (numeric/string compare, missing⇒false, built-ins, backfill) → Task 3. §3.4 renderer (closure init, LIST parity, TABLE grid, error widget, opaque bg) + wiring → Task 4. §3.5 tests → Tasks 1–4 (+ existing DataviewQuery/IndexTags kept green). §4 exclusions respected (no OR/functions/GROUP BY/clickable/live-refresh).
- Type consistency: `Frontmatter.parse`, `DataviewQuery.{Kind,Source,Op,Condition,SortKey,Parsed,ResultRow,parse,tagForListQuery}`, `SearchIndex.dataview(_:) -> [DataviewQuery.ResultRow]`, `DataviewRenderer(query:)` — consistent across tasks.
- Pinned risks: Op order (`<=`,`>=`,`!=` before `=`,`<`,`>`); LIST-with-columns → nil; legacy wrapper behavior preserved; v3 is a NEW migration (never edit applied ones).
