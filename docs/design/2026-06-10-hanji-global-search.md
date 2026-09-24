# Global Search (FTS5 + GRDB) Implementation Plan

**Goal:** Vault-wide full-text search (Korean-friendly trigram FTS5) over a persistent, incrementally-updated SQLite index, surfaced as an Obsidian-style sidebar search panel (⇧⌘F).

**Architecture:** New `SearchKit` target is the only thing that knows GRDB. `SearchIndex` owns a per-vault DB in Application Support (outside the vault — avoids polluting it and avoids FSEvents feedback). AppState schedules debounced background reindexes (mtime-skip makes them cheap) from every write path + the watcher; the sidebar gains Files/Search icon tabs and a search panel whose hits jump the caret to the match via the existing `pendingCursorOffset`.

**Tech Stack:** Swift 5.10 / SPM, GRDB.swift 7.x (first external dependency), system SQLite FTS5 `trigram` tokenizer (macOS 14 ships SQLite ≥3.43), CryptoKit (SHA-256 path hashing), custom `Checks` runner.

**Spec:** `docs/design/2026-06-10-hanji-global-search-design.md`

**Conventions:** tests are `Sources/Checks/<Name>Checks.swift` functions registered in `Sources/Checks/main.swift`, run via `swift run Checks <Group>`. TDD "red" for a new symbol = build failure. Commit after each task with real timestamps (evening rule — no backdating needed). First `swift build` after Task 1 fetches GRDB from GitHub (network required once; afterwards cached).

---

## File structure

- `Package.swift` — GRDB package + `SearchKit` target; `AppCore` and `Checks` gain `SearchKit`.
- Create `Sources/SearchKit/SearchIndex.swift` — DB location, schema/migration, reindex, remove.
- Create `Sources/SearchKit/SearchHit.swift` — hit model + snippet/offset computation (pure helpers).
- Modify `Sources/AppCore/AppState.swift` — `searchIndex`, `scheduleReindex()`, `searchIndexUpdatedAt`.
- Modify `Sources/HanjiApp/UIState.swift` — `SidebarMode`, focus token.
- Create `Sources/HanjiApp/SearchPanelView.swift` — search field + results list.
- Modify `Sources/HanjiApp/ContentView.swift` — sidebar mode tabs; files mode = existing tree.
- Modify `Sources/HanjiApp/HanjiApp.swift` — ⇧⌘F menu item.
- Create `Sources/Checks/SearchIndexChecks.swift`, append to `Sources/Checks/E2EChecks.swift`, register in `main.swift`.

---

## Task 1: GRDB dependency + SearchKit skeleton (DB file, schema)

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SearchKit/SearchIndex.swift`
- Create: `Sources/Checks/SearchIndexChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Add the GRDB package and SearchKit target in `Package.swift`**

Add a `dependencies:` array to the `Package(` initializer (after `platforms:`):
```swift
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
```
Add to `targets:`:
```swift
        .target(name: "SearchKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
```
Append `"SearchKit"` to BOTH the `AppCore` target's dependencies and the `Checks` target's dependencies.

- [ ] **Step 2: Write the failing test** — `Sources/Checks/SearchIndexChecks.swift`

```swift
import Foundation
import SearchKit

func searchIndexChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-si-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }

    // Per-vault DB path: deterministic, under Application Support, outside the vault.
    let dbURL = SearchIndex.indexFileURL(forVault: vault)
    expect(dbURL.path.contains("Application Support"), "index lives in Application Support")
    expect(!dbURL.path.hasPrefix(vault.path), "index lives outside the vault")
    expectEqual(SearchIndex.indexFileURL(forVault: vault), dbURL, "path derivation is deterministic")
    defer { try? fm.removeItem(at: dbURL) }

    // Opening creates the DB file with the schema in place.
    let index = try? SearchIndex(vaultRoot: vault)
    expect(index != nil, "index opens")
    expect(fm.fileExists(atPath: dbURL.path), "DB file created")
}
```

- [ ] **Step 3: Register** — add `("SearchIndex", searchIndexChecks),` to `Sources/Checks/main.swift` (before the `("E2E", e2eChecks),` line).

- [ ] **Step 4: Run to verify it fails**

Run: `swift run Checks SearchIndex` — first run resolves+builds GRDB (takes a few minutes).
Expected: build failure `no such module 'SearchKit'`.

- [ ] **Step 5: Implement `Sources/SearchKit/SearchIndex.swift`**

```swift
import Foundation
import CryptoKit
import GRDB

/// Persistent per-vault full-text index (SQLite + FTS5 trigram via GRDB).
/// Lives in Application Support — outside the vault, so index writes never
/// pollute the vault or wake the vault's FSEvents watcher.
public final class SearchIndex {
    let dbQueue: DatabaseQueue

    public init(vaultRoot: URL) throws {
        let url = Self.indexFileURL(forVault: vaultRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "note") { t in
                t.column("path", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("mtime", .double).notNull()
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE note_fts USING fts5(
                  path UNINDEXED, title, body, tokenize='trigram'
                )
                """)
        }
        try migrator.migrate(dbQueue)
    }

    /// `~/Library/Application Support/hanji/index/<sha256-of-vault-path>.db`
    public static func indexFileURL(forVault root: URL) -> URL {
        let canonical = root.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appendingPathComponent("hanji/index/\(hex).db")
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `swift run Checks SearchIndex`
Expected: `✅ All checks passed (5 assertions, 1 group(s))`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved Sources/SearchKit/SearchIndex.swift Sources/Checks/SearchIndexChecks.swift Sources/Checks/main.swift
git commit -m "feat(search): GRDB dependency + SearchKit target with per-vault FTS5 schema"
```

---

## Task 2: Indexing (reindexAll with mtime-skip, incremental reindex, remove)

**Files:**
- Modify: `Sources/SearchKit/SearchIndex.swift` (append methods)
- Modify: `Sources/Checks/SearchIndexChecks.swift` (new group function)
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — append to `Sources/Checks/SearchIndexChecks.swift`

```swift
func searchReindexChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-sr-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault.appendingPathComponent("Sub"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "# Hello\nfirst body".write(to: vault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try? "deep text".write(to: vault.appendingPathComponent("Sub/b.md"), atomically: true, encoding: .utf8)
    try? "ignored".write(to: vault.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

    guard let index = try? SearchIndex(vaultRoot: vault) else { expect(false, "index opens"); return }
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }

    try? index.reindexAll(vault: vault)
    expectEqual(try? index.indexedCount(), 2, "two md files indexed (txt skipped)")

    // mtime-skip: a second full pass touches nothing.
    expectEqual(try? index.reindexAll(vault: vault), 0, "warm second pass reindexes 0 files")

    // Incremental: editing one file reindexes just it.
    try? "# Hello\nedited body".write(to: vault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try? index.reindex(paths: ["a.md"], vault: vault)
    let hitsAfterEdit = (try? index.search("edited")) ?? []
    expectEqual(hitsAfterEdit.first?.path, "a.md", "incremental reindex picks up the edit")
    expect(((try? index.search("first")) ?? []).isEmpty, "old body is gone from the index")

    // reindex(paths:) of a missing file removes it; remove(paths:) works directly.
    try? fm.removeItem(at: vault.appendingPathComponent("Sub/b.md"))
    try? index.reindex(paths: ["Sub/b.md"], vault: vault)
    expectEqual(try? index.indexedCount(), 1, "missing file dropped on incremental pass")
    try? index.remove(paths: ["a.md"])
    expectEqual(try? index.indexedCount(), 0, "explicit remove empties the index")
}
```

Note: this test calls `search(_:)` (Task 3). The two tasks' red phases overlap — implement Task 2's methods plus a minimal `search` stub is NOT allowed; instead implement Task 2 fully and Task 3's `search` right after, then run. To keep the loop tight, Step 4 below only checks compilation of Task 2 methods via `indexedCount`; full green for this group lands at the end of Task 3.

- [ ] **Step 2: Register** — add `("SearchReindex", searchReindexChecks),` to `main.swift` after `("SearchIndex", ...)`.

- [ ] **Step 3: Implement — append to `Sources/SearchKit/SearchIndex.swift`** (inside the class)

```swift
    // MARK: - Indexing

    /// Index every `.md` under the vault, skipping files whose mtime is
    /// unchanged. Returns the number of files (re)indexed.
    @discardableResult
    public func reindexAll(vault root: URL) throws -> Int {
        let fm = FileManager.default
        var seen: Set<String> = []
        var changed = 0
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                  options: [.skipsHiddenFiles]) {
            for case let url as URL in en where url.pathExtension.lowercased() == "md" {
                let path = relativePath(of: url, under: root)
                seen.insert(path)
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                let stored = try dbQueue.read { db in
                    try Double.fetchOne(db, sql: "SELECT mtime FROM note WHERE path = ?", arguments: [path])
                }
                if let stored, abs(stored - mtime) < 0.001 { continue }
                try upsert(path: path, url: url, mtime: mtime)
                changed += 1
            }
        }
        // Drop rows for files that no longer exist.
        let indexed = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM note")
        }
        let gone = indexed.filter { !seen.contains($0) }
        if !gone.isEmpty { try remove(paths: gone) }
        return changed
    }

    /// Incrementally (re)index specific vault-relative paths; missing files are removed.
    public func reindex(paths: [String], vault root: URL) throws {
        for path in paths {
            let url = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                try remove(paths: [path])
                continue
            }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            try upsert(path: path, url: url, mtime: mtime)
        }
    }

    public func remove(paths: [String]) throws {
        try dbQueue.write { db in
            for path in paths {
                try db.execute(sql: "DELETE FROM note WHERE path = ?", arguments: [path])
                try db.execute(sql: "DELETE FROM note_fts WHERE path = ?", arguments: [path])
            }
        }
    }

    public func indexedCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? 0
        }
    }

    private func upsert(path: String, url: URL, mtime: Double) throws {
        let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let title = url.deletingPathExtension().lastPathComponent
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO note (path, title, mtime) VALUES (?, ?, ?)",
                           arguments: [path, title, mtime])
            try db.execute(sql: "DELETE FROM note_fts WHERE path = ?", arguments: [path])
            try db.execute(sql: "INSERT INTO note_fts (path, title, body) VALUES (?, ?, ?)",
                           arguments: [path, title, body])
        }
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let r = root.standardizedFileURL.path + "/"
        let u = url.standardizedFileURL.path
        return u.hasPrefix(r) ? String(u.dropFirst(r.count)) : url.lastPathComponent
    }
```

- [ ] **Step 4: Confirm it compiles (group stays red until Task 3 adds `search`)**

Run: `swift build`
Expected: errors ONLY about `search` not existing (referenced by the new test). Proceed straight to Task 3 — do not commit yet.

---

## Task 3: search() — trigram MATCH, LIKE fallback, SearchHit with snippet/offset

**Files:**
- Create: `Sources/SearchKit/SearchHit.swift`
- Modify: `Sources/SearchKit/SearchIndex.swift` (append `search`)
- Modify: `Sources/Checks/SearchIndexChecks.swift` (new group)
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — append to `Sources/Checks/SearchIndexChecks.swift`

```swift
func searchQueryChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-sq-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "운동 기록\n오늘은 헬스운동화를 신고 턱걸이를 했다. 운동 최고."
        .write(to: vault.appendingPathComponent("건강.md"), atomically: true, encoding: .utf8)
    try? "# Reading list\nGood code Bad code is a great book."
        .write(to: vault.appendingPathComponent("books.md"), atomically: true, encoding: .utf8)

    guard let index = try? SearchIndex(vaultRoot: vault) else { expect(false, "index opens"); return }
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    try? index.reindexAll(vault: vault)

    // Korean sub-word match via trigram: "운동화" inside "헬스운동화".
    let korean = (try? index.search("운동화")) ?? []
    expectEqual(korean.first?.path, "건강.md", "Korean sub-word match")
    expect(korean.first?.snippet.contains("헬스운동화") ?? false, "snippet shows match context")
    expect(!(korean.first?.matchRanges.isEmpty ?? true), "highlight ranges present")
    if let hit = korean.first, let offset = hit.firstMatchOffset {
        let body = try! String(contentsOf: vault.appendingPathComponent("건강.md"), encoding: .utf8)
        let ns = body as NSString
        expectEqual(ns.substring(with: NSRange(location: offset, length: 3)), "운동화", "offset lands on the match")
    } else { expect(false, "firstMatchOffset present") }

    // English match + bm25 ordering sanity.
    let english = (try? index.search("great book")) ?? []
    expectEqual(english.first?.path, "books.md", "English phrase match")

    // Short query (< 3 chars) takes the LIKE fallback — Korean 2-char included.
    let short = (try? index.search("턱걸")) ?? []
    expectEqual(short.first?.path, "건강.md", "2-char Korean query via LIKE fallback")

    // Title match works (filename base is the title).
    let title = (try? index.search("books")) ?? []
    expectEqual(title.first?.path, "books.md", "title match")

    // No hits / blank query.
    expect(((try? index.search("zzqqxx")) ?? []).isEmpty, "no false hits")
    expect(((try? index.search("  ")) ?? []).isEmpty, "blank query → empty")
}
```

- [ ] **Step 2: Register** — add `("SearchQuery", searchQueryChecks),` after `("SearchReindex", ...)`.

- [ ] **Step 3: Create `Sources/SearchKit/SearchHit.swift`**

```swift
import Foundation

/// One global-search result. Snippet is a window around the first body match;
/// `matchRanges` are UTF-16 ranges INSIDE the snippet (for highlighting);
/// `firstMatchOffset` is the UTF-16 offset in the full body (caret jump).
public struct SearchHit: Identifiable {
    public let path: String
    public let title: String
    public let snippet: String
    public let matchRanges: [Range<Int>]
    public let firstMatchOffset: Int?
    public let score: Double
    public var id: String { path }

    /// Build a hit from a stored row + the query (pure; unit-tested via search()).
    static func make(path: String, title: String, body: String, query: String, score: Double) -> SearchHit {
        let ns = body as NSString
        let match = ns.range(of: query, options: [.caseInsensitive])
        guard match.location != NSNotFound else {
            // Title-only match: snippet is the body head.
            let head = ns.substring(to: min(80, ns.length))
            return SearchHit(path: path, title: title, snippet: head,
                             matchRanges: [], firstMatchOffset: nil, score: score)
        }
        let start = max(0, match.location - 40)
        let end = min(ns.length, match.location + match.length + 40)
        var snippet = ns.substring(with: NSRange(location: start, length: end - start))
        snippet = snippet.replacingOccurrences(of: "\n", with: " ")
        if start > 0 { snippet = "…" + snippet }
        if end < ns.length { snippet += "…" }

        // Highlight every occurrence inside the snippet (cap 5).
        let sns = snippet as NSString
        var ranges: [Range<Int>] = []
        var cursor = 0
        while ranges.count < 5 {
            let r = sns.range(of: query, options: [.caseInsensitive],
                              range: NSRange(location: cursor, length: sns.length - cursor))
            guard r.location != NSNotFound else { break }
            ranges.append(r.location..<(r.location + r.length))
            cursor = r.location + r.length
        }
        return SearchHit(path: path, title: title, snippet: snippet,
                         matchRanges: ranges, firstMatchOffset: match.location, score: score)
    }
}
```

- [ ] **Step 4: Append `search` to `SearchIndex`**

```swift
    // MARK: - Search

    /// Full-text search. Queries of 3+ characters use FTS5 trigram MATCH with
    /// bm25 ranking; shorter ones fall back to LIKE (substring) so 1–2-char
    /// Korean queries still work.
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        struct Stored { let path: String; let title: String; let body: String; let score: Double }
        let stored: [Stored]
        if q.count >= 3 {
            let match = "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            stored = try dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT path, title, body, bm25(note_fts) AS score
                    FROM note_fts WHERE note_fts MATCH ?
                    ORDER BY score LIMIT ?
                    """, arguments: [match, limit])
                .map { Stored(path: $0["path"], title: $0["title"], body: $0["body"], score: $0["score"]) }
            }
        } else {
            let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let like = "%\(escaped)%"
            stored = try dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT path, title, body, 0.0 AS score
                    FROM note_fts
                    WHERE title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\'
                    ORDER BY (title LIKE ? ESCAPE '\\') DESC, path LIMIT ?
                    """, arguments: [like, like, like, limit])
                .map { Stored(path: $0["path"], title: $0["title"], body: $0["body"], score: $0["score"]) }
            }
        }
        return stored.map { SearchHit.make(path: $0.path, title: $0.title, body: $0.body,
                                           query: q, score: $0.score) }
    }
```

- [ ] **Step 5: Run to verify everything passes**

Run: `swift run Checks SearchIndex && swift run Checks SearchReindex && swift run Checks SearchQuery`
Expected: all three groups `✅ All checks passed`. (If `MATCH` errors with `no such tokenizer: trigram`, the system SQLite is too old — macOS 14+ is required; report BLOCKED.)

- [ ] **Step 6: Commit**

```bash
git add Sources/SearchKit Sources/Checks/SearchIndexChecks.swift Sources/Checks/main.swift
git commit -m "feat(search): incremental FTS5 index + trigram search with snippets"
```

---

## Task 4: AppState wiring — searchIndex, debounced background reindex

**Files:**
- Modify: `Sources/AppCore/AppState.swift`
- Modify: `Sources/Checks/SearchIndexChecks.swift` (new group)
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — append to `Sources/Checks/SearchIndexChecks.swift` (add `import AppCore` at the top of the file)

```swift
func appStateSearchChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-as-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "# Note\nxylophone serenade".write(to: vault.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)

    let state = AppState(defaults: UserDefaults(suiteName: "mk-as-\(UUID().uuidString)")!)
    state.openVault(at: vault)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    expect(state.searchIndex != nil, "search index opens with the vault")

    // openVault schedules a background reindex; pump until searchable.
    var hits: [SearchHit] = []
    let deadline = Date().addingTimeInterval(5)
    while hits.isEmpty && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hits = (try? state.searchIndex?.search("xylophone")) ?? []
    }
    expectEqual(hits.first?.path, "n.md", "vault open indexes existing notes")

    // Saving an edit reindexes incrementally (via scheduleReindex).
    state.open(state.files[0])
    state.activeText = "# Note\nquixotic melody"
    state.save()
    var edited: [SearchHit] = []
    let deadline2 = Date().addingTimeInterval(5)
    while edited.isEmpty && Date() < deadline2 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        edited = (try? state.searchIndex?.search("quixotic")) ?? []
    }
    expectEqual(edited.first?.path, "n.md", "save reindexes the note")
}
```

- [ ] **Step 2: Register** — add `("AppStateSearch", appStateSearchChecks),` after `("SearchQuery", ...)`.

- [ ] **Step 3: Run to verify it fails** — `swift run Checks AppStateSearch` → build failure (`AppState` has no `searchIndex`).

- [ ] **Step 4: Implement in `Sources/AppCore/AppState.swift`**

Add `import SearchKit` at the top. Add stored properties next to `watcher`:
```swift
    public private(set) var searchIndex: SearchIndex?
    /// Bumps whenever a background reindex completes (search panel refresh hook).
    @Published public private(set) var searchIndexUpdatedAt = Date()
    private let searchQueue = DispatchQueue(label: "io.hanji.searchindex", qos: .utility)
```
In `openVault(at:)`, after starting the watcher, add:
```swift
        searchIndex = try? SearchIndex(vaultRoot: root)
        scheduleReindex()
```
In `reloadTree()`, at the end, add:
```swift
        scheduleReindex()
```
In `save()`, after the write, add:
```swift
        scheduleReindex()
```
Add the method (near reloadTree):
```swift
    /// Debounced background reindex. A full pass with mtime-skip is cheap and
    /// self-correcting, so every write path and the FS watcher just call this.
    public func scheduleReindex() {
        guard let index = searchIndex, let root = vaultRoot else { return }
        searchQueue.async { [weak self] in
            guard (try? index.reindexAll(vault: root)) != nil else { return }
            DispatchQueue.main.async { self?.searchIndexUpdatedAt = Date() }
        }
    }
```
(The serial utility queue itself coalesces bursts; no timer needed.)

- [ ] **Step 5: Run to verify it passes**

Run: `swift run Checks AppStateSearch` → `✅`. Then the full suite: `swift run Checks` → all groups green (no regressions; AppState/E2E groups still pass).

- [ ] **Step 6: Commit**

```bash
git add Sources/AppCore/AppState.swift Sources/Checks/SearchIndexChecks.swift Sources/Checks/main.swift
git commit -m "feat(search): AppState owns the index; write paths + watcher trigger background reindex"
```

---

## Task 5: UI — sidebar Files/Search tabs, search panel, ⇧⌘F

**Files:**
- Modify: `Sources/HanjiApp/UIState.swift`
- Create: `Sources/HanjiApp/SearchPanelView.swift`
- Modify: `Sources/HanjiApp/ContentView.swift`
- Modify: `Sources/HanjiApp/HanjiApp.swift`
- Modify: `Package.swift` (HanjiApp deps: add `"SearchKit"`)

> Build-verified + screenshot; no unit tests (SwiftUI). Read each file before editing — adapt names to the real code.

- [ ] **Step 1: `UIState.swift`** — add the mode + focus token:

```swift
enum SidebarMode { case files, search }
```
and inside `UIState`:
```swift
    @Published var sidebarMode: SidebarMode = .files
    /// Incremented to ask the search panel to grab keyboard focus (⇧⌘F).
    @Published var searchFocusToken = 0
```

- [ ] **Step 2: Create `Sources/HanjiApp/SearchPanelView.swift`**

```swift
import SwiftUI
import AppCore
import SearchKit

/// Obsidian-style sidebar search: debounced query over the vault FTS index,
/// snippets with highlighted matches, ⏎/click jumps to the match.
struct SearchPanelView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var uiState: UIState

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
                TextField("Search in vault", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($focused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()

            if query.isEmpty {
                Spacer()
                Text("Type to search the vault").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else if hits.isEmpty {
                Spacer()
                Text("No results").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(hits) { hit in
                    Button { open(hit) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title).fontWeight(.medium).lineLimit(1)
                            Text(highlighted(hit))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
        .onAppear { focused = true }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200))   // debounce
            guard !Task.isCancelled else { return }
            runSearch()
        }
        .onChange(of: appState.searchIndexUpdatedAt) { _, _ in runSearch() }
        .onChange(of: uiState.searchFocusToken) { _, _ in focused = true }
    }

    private func runSearch() {
        guard !query.isEmpty, let index = appState.searchIndex else { hits = []; return }
        hits = (try? index.search(query)) ?? []
    }

    private func open(_ hit: SearchHit) {
        appState.openNote(relativePath: hit.path)
        appState.pendingCursorOffset = hit.firstMatchOffset
    }

    private func highlighted(_ hit: SearchHit) -> AttributedString {
        var attributed = AttributedString(hit.snippet)
        for range in hit.matchRanges {
            let ns = hit.snippet as NSString
            guard range.upperBound <= ns.length,
                  let swiftRange = Range(NSRange(location: range.lowerBound,
                                                 length: range.upperBound - range.lowerBound),
                                         in: attributed) else { continue }
            attributed[swiftRange].font = .caption.bold()
            attributed[swiftRange].foregroundColor = .accentColor
        }
        return attributed
    }
}
```
Note: `Range(NSRange, in: AttributedString)` is unavailable — convert through the snippet `String`:
replace the guard with:
```swift
            guard let stringRange = Range(NSRange(location: range.lowerBound,
                                                  length: range.upperBound - range.lowerBound),
                                          in: hit.snippet),
                  let swiftRange = attributed.range(of: String(hit.snippet[stringRange])) else { continue }
```
…but `range(of:)` finds the FIRST occurrence, which mis-highlights repeats. The robust form: rebuild by slicing — use this implementation instead of the loop above:
```swift
    private func highlighted(_ hit: SearchHit) -> AttributedString {
        let ns = hit.snippet as NSString
        var out = AttributedString()
        var cursor = 0
        for range in hit.matchRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound >= cursor, range.upperBound <= ns.length else { continue }
            out += AttributedString(ns.substring(with: NSRange(location: cursor, length: range.lowerBound - cursor)))
            var match = AttributedString(ns.substring(with: NSRange(location: range.lowerBound,
                                                                    length: range.upperBound - range.lowerBound)))
            match.font = .caption.bold()
            match.foregroundColor = .accentColor
            out += match
            cursor = range.upperBound
        }
        out += AttributedString(ns.substring(from: cursor))
        return out
    }
```

- [ ] **Step 3: `ContentView.swift`** — sidebar mode tabs. In `fileListPane`, wrap the existing content: put this `modeTabs` view ABOVE `filterField`, and switch the body on the mode:

```swift
    @ViewBuilder private var modeTabs: some View {
        HStack(spacing: 14) {
            modeTab(.files, icon: "doc.text", help: "Files")
            modeTab(.search, icon: "magnifyingglass", help: "Search (⇧⌘F)")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func modeTab(_ mode: SidebarMode, icon: String, help: String) -> some View {
        Button { uiState.sidebarMode = mode } label: {
            Image(systemName: icon)
                .foregroundStyle(uiState.sidebarMode == mode ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
```
Restructure `fileListPane`'s outer `VStack(spacing: 0)` to:
```swift
            VStack(spacing: 0) {
                modeTabs
                Divider()
                if uiState.sidebarMode == .search {
                    SearchPanelView()
                } else {
                    filterField
                    List(selection: $treeSelection) { treeRows(visibleTree) }
                    Divider()
                    /* existing gear footer unchanged */
                }
            }
```
Keep every existing modifier (context menu, drop, onChange handlers, alerts, toolbar) exactly where they are — they hang off the outer container and still apply.

- [ ] **Step 4: `HanjiApp.swift`** — add to the `CommandMenu("Go")`:

```swift
                Button("Search in Vault") {
                    uiState.sidebarMode = .search
                    uiState.searchFocusToken += 1
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
```
And in `Package.swift`, add `"SearchKit"` to the `HanjiApp` executable target dependencies.

- [ ] **Step 5: Build + full checks + screenshot**

```bash
swift build && swift run Checks
./Scripts/bundle-app.sh
HANJI_OPEN_VAULT=<test-vault> open ./hanji.app
```
Screenshot: sidebar shows the two icon tabs; clicking 🔍 (or ⇧⌘F) shows the search field; typing a Korean word from a real note (e.g. "운동") lists title+snippet hits with the match highlighted; clicking a hit opens the note with the caret at the match.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/HanjiApp Sources/AppCore
git commit -m "feat(search): sidebar Files/Search tabs + search panel with snippet highlights (⇧⌘F)"
```

---

## Task 6: E2E step, README, full verification

**Files:**
- Modify: `Sources/Checks/E2EChecks.swift`
- Modify: `README.md`

- [ ] **Step 1: Add a search step to the E2E scenario** — in `Sources/Checks/E2EChecks.swift`, right after step "4. Rename it, then edit + save" (the `expectEqual(onDisk, ...)` line), insert:

```swift
    // 4b. Global search finds the freshly saved content (sync reindex for determinism).
    try? appState.searchIndex?.reindexAll(vault: root)
    let searchHits = (try? appState.searchIndex?.search("first step")) ?? []
    expectEqual(searchHits.first?.path, "Projects/Plan.md", "E2E: global search finds saved note")
    expect(searchHits.first?.firstMatchOffset != nil, "E2E: search hit carries a caret offset")
```
Add `import SearchKit` to the file's imports.

- [ ] **Step 2: README status section** — add a bullet:

```markdown
- **Global search (⇧⌘F)** — sidebar search panel over a persistent FTS5 index
  (Korean-friendly trigram matching); results jump to the match. The index
  lives in Application Support and updates incrementally as you edit.
```
And note GRDB in the architecture section: `SearchKit → GRDB (the only external dependency)`.

- [ ] **Step 3: Full verification**

```bash
swift run Checks          # all groups green
./Scripts/e2e.sh          # headless E2E + bundle + launch smoke
```

- [ ] **Step 4: Commit**

```bash
git add Sources/Checks/E2EChecks.swift README.md
git commit -m "test: global-search E2E step + README"
```

---

## Self-review notes (vs the spec)

- Spec §2 targets/deps → Task 1 (+Task 5 HanjiApp dep). §3.1 schema → Task 1. §3.2 API incl. LIKE fallback, snippet semantics → Tasks 2–3. §4 AppState/background/debounce → Task 4 (serial-queue coalescing instead of a timer — same effect, simpler). §5 UI tabs/panel/⇧⌘F/caret jump → Task 5. §6 tests incl. Korean/mtime/incremental/E2E → Tasks 1–4, 6. §7 exclusions respected (no operators/regex/replace).
- Type consistency: `SearchIndex(vaultRoot:)`, `indexFileURL(forVault:)`, `reindexAll(vault:) -> Int`, `reindex(paths:vault:)`, `remove(paths:)`, `indexedCount()`, `search(_:limit:) -> [SearchHit]`, `SearchHit{path,title,snippet,matchRanges,firstMatchOffset,score}`, `AppState.searchIndex/searchIndexUpdatedAt/scheduleReindex()`, `UIState.sidebarMode/searchFocusToken` — used identically across tasks.
- Known risk called out: first build needs network for GRDB; `trigram` requires macOS 14's SQLite (report BLOCKED if missing).
