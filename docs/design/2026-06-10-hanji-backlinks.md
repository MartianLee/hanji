# Backlinks Panel (SDK ② MetadataQuerying) Implementation Plan

**Goal:** A right-sidebar Backlinks panel (first-party plugin over a new minimal SDK ② query surface) listing every note that links to the active note, with context snippets, updating live.

**Architecture:** Pure `LinkParser` (MarkdownCore) extracts wikilinks/markdown links; MKSearchKit migration v2 stores a `link(source, target, offset)` table refreshed on every reindex and answers `backlinks(of:)` with boundary-safe snippets (shared `SnippetWindow` helper, also adopted by `SearchHit`). The host exposes `MetadataQuerying` (backlinks + indexDidUpdate) and `EditorContext.activeNotePath`; `BacklinksPlugin` (ExtensionSDK-only) renders the panel — registering it restores the 3-column layout automatically.

**Tech Stack:** Swift 5.10/SPM, GRDB 7 (already in, MKSearchKit-only), NSRegularExpression, Combine, custom `Checks` runner.

**Spec:** `docs/design/2026-06-10-hanji-backlinks-design.md` (architecture diagram in §2)

**Conventions:** TDD via `Sources/Checks` (`expect`/`expectEqual`, register in main.swift, `swift run Checks <Group>`); red = build failure for new symbols; commits straight to main. ⚠️ The search module target/import is **`MKSearchKit`**.

---

## File structure

- Create `Sources/MarkdownCore/LinkParser.swift` — pure link extraction.
- Create `Sources/MKSearchKit/SnippetWindow.swift` — shared boundary-safe snippet builder (refactors `SearchHit.make` to use it).
- Modify `Sources/MKSearchKit/SearchIndex.swift` — migration v2, link upsert/remove, `backlinks(of:)`, `Backlink` type (in `SnippetWindow.swift` file? no — `Backlink` lives in `SearchIndex.swift` next to its query).
- Modify `Package.swift` — `MKSearchKit` gains `MarkdownCore` dep; new `BacklinksPlugin` target; app/Checks deps.
- Modify `Sources/ExtensionSDK/ExtensionSDK.swift` — `SDKBacklink`, `MetadataQuerying`, `PluginHost.query`, `EditorContext.activeNotePath`.
- Modify `Sources/AppCore/Host.swift` — conformances.
- Create `Sources/BacklinksPlugin/BacklinksPlugin.swift` — plugin + panel view.
- Modify `Sources/HanjiApp/HanjiApp.swift` — register the plugin.
- Tests: `Sources/Checks/LinkParserChecks.swift`, additions to `SearchIndexChecks.swift`, `Sources/Checks/BacklinksPluginChecks.swift`, E2E step; registrations in `main.swift`.

---

## Task 1: LinkParser (pure)

**Files:**
- Create: `Sources/MarkdownCore/LinkParser.swift`
- Create: `Sources/Checks/LinkParserChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — `Sources/Checks/LinkParserChecks.swift`

```swift
import Foundation
import MarkdownCore

func linkParserChecks() {
    func targets(_ s: String) -> [String] { LinkParser.links(in: s).map(\.target) }

    expectEqual(targets("A [[Plan]] B"), ["Plan"], "plain wikilink")
    expectEqual(targets("[[Plan|별칭]]"), ["Plan"], "alias cut at |")
    expectEqual(targets("[[Plan#섹션]]"), ["Plan"], "heading cut at #")
    expectEqual(targets("[[Projects/Plan]]"), ["Projects/Plan"], "path wikilink kept whole")
    expectEqual(targets("![[image.png]]"), [], "embed skipped")
    expectEqual(targets("[text](Projects/Plan.md)"), ["Projects/Plan.md"], "markdown link to .md")
    expectEqual(targets("[ext](https://example.com/a.md)"), [], "external link skipped")
    expectEqual(targets("![alt](note.md)"), [], "image markdown skipped")
    expectEqual(targets("[pic](photo.png)"), [], "non-md markdown link skipped")
    expectEqual(targets("```\n[[NotALink]]\n```\n[[Real]]"), ["Real"], "fenced code skipped")
    expectEqual(targets("[[A]] and [[B]]"), ["A", "B"], "multiple links in order")

    // Ranges are UTF-16 and cover the whole link token.
    let refs = LinkParser.links(in: "한글 [[Plan]] 끝")
    let ns = "한글 [[Plan]] 끝" as NSString
    expectEqual(refs.count, 1, "one link")
    if let r = refs.first {
        expectEqual(ns.substring(with: NSRange(location: r.range.lowerBound,
                                               length: r.range.upperBound - r.range.lowerBound)),
                    "[[Plan]]", "range covers the token")
    }
}
```

- [ ] **Step 2: Register** — add `("LinkParser", linkParserChecks),` to `Sources/Checks/main.swift` (after `("FontSetting", ...)`).

- [ ] **Step 3: Red** — `swift run Checks LinkParser` → build failure `cannot find 'LinkParser' in scope`.

- [ ] **Step 4: Implement `Sources/MarkdownCore/LinkParser.swift`**

```swift
import Foundation

/// A non-embed link found in a note body. `target` is the raw link target
/// (before `|` alias / `#` heading); `range` is the whole token in UTF-16.
public struct LinkRef: Equatable {
    public let target: String
    public let range: Range<Int>
    public init(target: String, range: Range<Int>) {
        self.target = target
        self.range = range
    }
}

/// Extracts wikilinks (`[[Target]]`, `[[Target|alias]]`, `[[Target#heading]]`)
/// and markdown links to `.md` files. Skips embeds/images (`![[…]]`, `![…](…)`),
/// external URLs, and anything inside fenced code blocks.
public enum LinkParser {
    private static let wiki = try! NSRegularExpression(pattern: #"(?<!\!)\[\[([^\[\]]+)\]\]"#)
    private static let md = try! NSRegularExpression(pattern: #"(?<!\!)\[[^\]]*\]\(([^)\s]+)\)"#)

    public static func links(in text: String) -> [LinkRef] {
        let ns = text as NSString
        let fenced = fencedRanges(ns)
        func inFence(_ r: NSRange) -> Bool { fenced.contains { NSIntersectionRange($0, r).length > 0 } }
        var out: [LinkRef] = []

        let full = NSRange(location: 0, length: ns.length)
        for m in wiki.matches(in: text, range: full) where !inFence(m.range) {
            var target = ns.substring(with: m.range(at: 1))
            if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
            if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
            target = target.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            out.append(LinkRef(target: target, range: m.range.location..<NSMaxRange(m.range)))
        }
        for m in md.matches(in: text, range: full) where !inFence(m.range) {
            var dest = ns.substring(with: m.range(at: 1))
            guard !dest.contains("://"), !dest.hasPrefix("#"), !dest.hasPrefix("mailto:") else { continue }
            if let hash = dest.firstIndex(of: "#") { dest = String(dest[..<hash]) }
            dest = dest.removingPercentEncoding ?? dest
            if dest.hasPrefix("./") { dest = String(dest.dropFirst(2)) }
            guard dest.lowercased().hasSuffix(".md") else { continue }
            out.append(LinkRef(target: dest, range: m.range.location..<NSMaxRange(m.range)))
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// UTF-16 ranges of fenced code blocks (``` … ```), line-based.
    private static func fencedRanges(_ ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var fenceStart: Int? = nil
        var pos = 0
        while pos < ns.length {
            let line = ns.lineRange(for: NSRange(location: pos, length: 0))
            var content = ns.substring(with: line)
            if content.hasSuffix("\n") { content.removeLast() }
            if content.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let start = fenceStart {
                    ranges.append(NSRange(location: start, length: NSMaxRange(line) - start))
                    fenceStart = nil
                } else {
                    fenceStart = line.location
                }
            }
            pos = NSMaxRange(line)
            if line.length == 0 { break }
        }
        if let start = fenceStart {   // unterminated fence runs to EOF
            ranges.append(NSRange(location: start, length: ns.length - start))
        }
        return ranges
    }
}
```

- [ ] **Step 5: Green** — `swift run Checks LinkParser` → `✅ All checks passed (13 assertions, 1 group(s))`.

- [ ] **Step 6: Commit**

```bash
git add Sources/MarkdownCore/LinkParser.swift Sources/Checks/LinkParserChecks.swift Sources/Checks/main.swift
git commit -m "feat(core): LinkParser — wikilinks + markdown links, embeds/fences excluded"
```

---

## Task 2: MKSearchKit v2 — link table + backlinks(of:) + shared SnippetWindow

**Files:**
- Create: `Sources/MKSearchKit/SnippetWindow.swift`
- Modify: `Sources/MKSearchKit/SearchIndex.swift`
- Modify: `Sources/MKSearchKit/SearchHit.swift` (use the shared helper)
- Modify: `Package.swift` (MKSearchKit deps: add `"MarkdownCore"`)
- Modify: `Sources/Checks/SearchIndexChecks.swift` (new group)
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — append to `Sources/Checks/SearchIndexChecks.swift`

```swift
func linkTableChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-lt-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault.appendingPathComponent("Projects"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "# Plan\ncontent".write(to: vault.appendingPathComponent("Projects/Plan.md"), atomically: true, encoding: .utf8)
    try? "허브 노트입니다. [[Plan]] 참고, 그리고 [[Plan|계획]]도."
        .write(to: vault.appendingPathComponent("Hub.md"), atomically: true, encoding: .utf8)
    try? "경로로 링크: [전체](Projects/Plan.md)"
        .write(to: vault.appendingPathComponent("Path.md"), atomically: true, encoding: .utf8)
    try? "무관한 노트".write(to: vault.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8)

    guard let index = try? SearchIndex(vaultRoot: vault) else { expect(false, "index opens"); return }
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    try? index.reindexAll(vault: vault)

    // Backlinks of Projects/Plan.md: Hub (wikilink, filename-base) + Path (full path md link).
    let back = (try? index.backlinks(of: "Projects/Plan.md")) ?? []
    expectEqual(back.map(\.sourcePath).sorted(), ["Hub.md", "Path.md"], "filename-base + full-path links found")
    expect(!back.contains { $0.sourcePath == "Other.md" }, "unrelated note absent")

    // One row per source (Hub links twice), snippet shows context with ranges.
    let hub = back.first { $0.sourcePath == "Hub.md" }
    expectEqual(hub?.sourceTitle, "Hub", "source title is filename base")
    expect(hub?.snippet.contains("[[Plan]]") ?? false, "snippet shows the link context")
    expect(!(hub?.matchRanges.isEmpty ?? true), "snippet highlight ranges present")

    // Editing the source away removes the backlink; deleting the file too.
    try? "이제 링크 없음".write(to: vault.appendingPathComponent("Hub.md"), atomically: true, encoding: .utf8)
    try? index.reindex(paths: ["Hub.md"], vault: vault)
    let afterEdit = (try? index.backlinks(of: "Projects/Plan.md")) ?? []
    expect(!afterEdit.contains { $0.sourcePath == "Hub.md" }, "edited-away link gone")
    try? index.remove(paths: ["Path.md"])
    let afterRemove = (try? index.backlinks(of: "Projects/Plan.md")) ?? []
    expect(afterRemove.isEmpty, "removed source drops its links")
}
```

- [ ] **Step 2: Register** — add `("LinkTable", linkTableChecks),` after `("AppStateSearch", ...)` in `main.swift`.

- [ ] **Step 3: Package.swift** — change the MKSearchKit target to:
```swift
        .target(name: "MKSearchKit", dependencies: ["MarkdownCore", .product(name: "GRDB", package: "GRDB.swift")]),
```

- [ ] **Step 4: Red** — `swift run Checks LinkTable` → build failure (`no member 'backlinks'`).

- [ ] **Step 5: Create `Sources/MKSearchKit/SnippetWindow.swift`** (shared by SearchHit + Backlink)

```swift
import Foundation

/// Builds a context snippet around a position in a body: ±40 UTF-16 units,
/// snapped to composed-character boundaries (surrogate-pair safe), newlines
/// flattened, ellipses added, with highlight ranges for a needle (cap 5).
enum SnippetWindow {
    static func make(body: String, around center: NSRange, highlight needle: String)
        -> (text: String, ranges: [Range<Int>]) {
        let ns = body as NSString
        let start = max(0, center.location - 40)
        let end = min(ns.length, NSMaxRange(center) + 40)
        guard end > start else { return ("", []) }
        let window = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        var snippet = ns.substring(with: window).replacingOccurrences(of: "\n", with: " ")
        if window.location > 0 { snippet = "…" + snippet }
        if NSMaxRange(window) < ns.length { snippet += "…" }

        let sns = snippet as NSString
        var ranges: [Range<Int>] = []
        var cursor = 0
        while ranges.count < 5, !needle.isEmpty {
            let r = sns.range(of: needle, options: [.caseInsensitive],
                              range: NSRange(location: cursor, length: sns.length - cursor))
            guard r.location != NSNotFound else { break }
            ranges.append(r.location..<NSMaxRange(r))
            cursor = NSMaxRange(r)
        }
        return (snippet, ranges)
    }
}
```

- [ ] **Step 6: Refactor `SearchHit.make`** (in `Sources/MKSearchKit/SearchHit.swift`) — replace the window/highlight section with the helper, keeping behavior identical:

```swift
    static func make(path: String, title: String, body: String, query: String, score: Double) -> SearchHit {
        let ns = body as NSString
        let match = ns.range(of: query, options: [.caseInsensitive])
        guard match.location != NSNotFound else {
            let headRange = ns.length == 0 ? NSRange(location: 0, length: 0)
                : ns.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: min(80, ns.length)))
            return SearchHit(path: path, title: title, snippet: ns.substring(with: headRange),
                             matchRanges: [], firstMatchOffset: nil, score: score)
        }
        let (snippet, ranges) = SnippetWindow.make(body: body, around: match, highlight: query)
        return SearchHit(path: path, title: title, snippet: snippet,
                         matchRanges: ranges, firstMatchOffset: match.location, score: score)
    }
```

- [ ] **Step 7: Migration v2 + link maintenance + backlinks query** — in `Sources/MKSearchKit/SearchIndex.swift`:

Add `import MarkdownCore` at the top. In `init`, AFTER the existing `registerMigration("v1")` block, add:
```swift
        migrator.registerMigration("v2") { db in
            try db.create(table: "link") { t in
                t.column("source", .text).notNull()   // vault-relative path of the linking note
                t.column("target", .text).notNull()   // normalized: lowercased, .md stripped
                t.column("offset", .integer).notNull() // UTF-16 offset of the link in source body
            }
            try db.create(indexOn: "link", columns: ["target"])
        }
```
In `upsert(path:url:mtime:)`, inside the `dbQueue.write` closure, append after the `note_fts` INSERT:
```swift
            try db.execute(sql: "DELETE FROM link WHERE source = ?", arguments: [path])
            for ref in LinkParser.links(in: body) {
                try db.execute(sql: "INSERT INTO link (source, target, offset) VALUES (?, ?, ?)",
                               arguments: [path, Self.normalizeTarget(ref.target), ref.range.lowerBound])
            }
```
In `remove(paths:)`, inside the write loop, append:
```swift
                try db.execute(sql: "DELETE FROM link WHERE source = ?", arguments: [path])
```
Append to the class:
```swift
    // MARK: - Backlinks

    /// Notes whose links resolve to the note at `relativePath` (filename base
    /// or full relative path, Obsidian-style), one entry per source, with a
    /// context snippet around the first link.
    public func backlinks(of relativePath: String) throws -> [Backlink] {
        let url = URL(fileURLWithPath: "/" + relativePath)   // path math only
        let base = Self.normalizeTarget(url.deletingPathExtension().lastPathComponent)
        let full = Self.normalizeTarget(relativePath)
        let targets = base == full ? [base] : [base, full]
        let placeholders = targets.map { _ in "?" }.joined(separator: ", ")
        struct Row0 { let source: String; let title: String; let body: String; let offset: Int }
        let rows: [Row0] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.source AS source, n.title AS title, f.body AS body, MIN(l.offset) AS offset
                FROM link l
                JOIN note n ON n.path = l.source
                JOIN note_fts f ON f.path = l.source
                WHERE l.target IN (\(placeholders))
                GROUP BY l.source
                ORDER BY n.title COLLATE NOCASE
                """, arguments: StatementArguments(targets))
            .map { Row0(source: $0["source"], title: $0["title"], body: $0["body"], offset: $0["offset"]) }
        }
        return rows.map { row in
            let ns = row.body as NSString
            let loc = min(max(0, row.offset), max(0, ns.length - 1))
            let linkRange = NSRange(location: loc, length: 0)
            let (snippet, ranges) = SnippetWindow.make(body: row.body, around: linkRange,
                                                       highlight: base)
            return Backlink(sourcePath: row.source, sourceTitle: row.title,
                            snippet: snippet, matchRanges: ranges)
        }
    }

    static func normalizeTarget(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix(".md") { t = String(t.dropLast(3)) }
        if t.hasPrefix("./") { t = String(t.dropFirst(2)) }
        return t
    }
```
And the result type (top level, same file):
```swift
/// One backlink: a note whose body links to the queried note.
public struct Backlink: Identifiable {
    public let sourcePath: String
    public let sourceTitle: String
    public let snippet: String
    public let matchRanges: [Range<Int>]
    public var id: String { sourcePath }
}
```

- [ ] **Step 8: Green** — `swift run Checks LinkTable && swift run Checks SearchQuery && swift run Checks SearchReindex` → all ✅ (the refactored SnippetWindow must keep SearchQuery green). Then full `swift run Checks`.

Note: existing DBs created by v1-only builds migrate forward automatically (GRDB applies "v2" on next open); the checks always use fresh temp DBs.

- [ ] **Step 9: Commit**

```bash
git add Package.swift Sources/MKSearchKit Sources/Checks/SearchIndexChecks.swift Sources/Checks/main.swift
git commit -m "feat(search): link table (schema v2) + backlinks(of:) with shared snippet window"
```

---

## Task 3: SDK ② surface + Host conformance

**Files:**
- Modify: `Sources/ExtensionSDK/ExtensionSDK.swift`
- Modify: `Sources/AppCore/Host.swift`
- Create: `Sources/Checks/BacklinksPluginChecks.swift` (first group: SDK surface via Host)
- Modify: `Sources/Checks/main.swift`

> Interlocking change: extending `PluginHost`/`EditorContext` breaks `Host` until it conforms — edit all source files, then build.

- [ ] **Step 1: Failing test** — `Sources/Checks/BacklinksPluginChecks.swift`

```swift
import Foundation
import Combine
import ExtensionSDK
import AppCore

func metadataQueryingChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-mq-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "# Target\nbody".write(to: vault.appendingPathComponent("Target.md"), atomically: true, encoding: .utf8)
    try? "링크: [[Target]]".write(to: vault.appendingPathComponent("Source.md"), atomically: true, encoding: .utf8)

    let appState = AppState(defaults: UserDefaults(suiteName: "mk-mq-\(UUID().uuidString)")!)
    appState.openVault(at: vault)
    defer {
        if let idx = appState.searchIndex {
            _ = idx   // index file cleanup below
        }
        try? fm.removeItem(at: MKSearchKitIndexURL(vault))
    }
    let pm = PluginManager()
    let host = Host(appState: appState, pluginManager: pm)

    // Synchronous reindex so the query is deterministic.
    try? appState.searchIndex?.reindexAll(vault: vault)
    let backs = host.query.backlinks(toNoteAt: "Target.md")
    expectEqual(backs.map(\.sourcePath), ["Source.md"], "SDK query surfaces backlinks")
    expectEqual(backs.first?.sourceTitle, "Source", "SDK backlink carries the title")

    // activeNotePath publishes the vault-relative path of the open note.
    var received: [String?] = []
    let sub = host.editor.activeNotePath.sink { received.append($0) }
    appState.open(appState.files.first(where: { $0.name == "Source.md" })!)
    expect(received.contains("Source.md"), "activeNotePath publishes the open note's relative path")
    sub.cancel()
}

// Helper: the per-vault index file (mirror of SearchIndex.indexFileURL without importing MKSearchKit here).
import MKSearchKit
private func MKSearchKitIndexURL(_ vault: URL) -> URL { SearchIndex.indexFileURL(forVault: vault) }
```

- [ ] **Step 2: Register** — `("MetadataQuerying", metadataQueryingChecks),` in main.swift (before E2E).

- [ ] **Step 3: Red** — `swift run Checks MetadataQuerying` → build failure (`no member 'query'`).

- [ ] **Step 4: ExtensionSDK additions** — append to `Sources/ExtensionSDK/ExtensionSDK.swift`:

```swift
/// One backlink (SDK-owned type — the index implementation stays hidden).
public struct SDKBacklink: Identifiable {
    public let sourcePath: String
    public let sourceTitle: String
    public let snippet: String
    public let matchRanges: [Range<Int>]   // UTF-16 ranges inside `snippet`
    public var id: String { sourcePath }
    public init(sourcePath: String, sourceTitle: String, snippet: String, matchRanges: [Range<Int>]) {
        self.sourcePath = sourcePath
        self.sourceTitle = sourceTitle
        self.snippet = snippet
        self.matchRanges = matchRanges
    }
}

/// Surface ② (metadata queries): read access to the vault index.
public protocol MetadataQuerying: AnyObject {
    func backlinks(toNoteAt relativePath: String) -> [SDKBacklink]
    /// Fires after the index absorbs changes (debounced upstream).
    var indexDidUpdate: AnyPublisher<Void, Never> { get }
}
```
Extend the existing `EditorContext` protocol with one member:
```swift
public protocol EditorContext {
    var activeText: AnyPublisher<String, Never> { get }
    /// Vault-relative path of the open note (nil when none).
    var activeNotePath: AnyPublisher<String?, Never> { get }
}
```
Extend `PluginHost` with:
```swift
    var query: MetadataQuerying { get }
```
(keeping ui/editor/renderers/commands/workspace).

- [ ] **Step 5: Host conformance** — in `Sources/AppCore/Host.swift`:

Add `import MKSearchKit` to the imports. Add `MetadataQuerying` to the conformance list:
```swift
public final class Host: PluginHost, UIRegistry, EditorContext, CommandRegistry, WorkspaceActions, MetadataQuerying {
```
Add under `// PluginHost`:
```swift
    public var query: MetadataQuerying { self }
```
Add under `// EditorContext`:
```swift
    public var activeNotePath: AnyPublisher<String?, Never> {
        appState.$selectedFile.combineLatest(appState.$vaultRoot)
            .map { file, root -> String? in
                guard let file, let root else { return nil }
                let prefix = root.standardizedFileURL.path + "/"
                let path = file.url.standardizedFileURL.path
                return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : file.name
            }
            .eraseToAnyPublisher()
    }
```
Add a new section:
```swift
    // MARK: - MetadataQuerying

    public func backlinks(toNoteAt relativePath: String) -> [SDKBacklink] {
        let hits = (try? appState.searchIndex?.backlinks(of: relativePath)) ?? []
        return hits.map {
            SDKBacklink(sourcePath: $0.sourcePath, sourceTitle: $0.sourceTitle,
                        snippet: $0.snippet, matchRanges: $0.matchRanges)
        }
    }

    public var indexDidUpdate: AnyPublisher<Void, Never> {
        appState.$searchIndexUpdatedAt.map { _ in () }.eraseToAnyPublisher()
    }
```

- [ ] **Step 6: Green** — `swift run Checks MetadataQuerying && swift run Checks PluginLoop && swift run Checks CommandRegistry2` → ✅ (existing surfaces unbroken).

- [ ] **Step 7: Commit**

```bash
git add Sources/ExtensionSDK/ExtensionSDK.swift Sources/AppCore/Host.swift Sources/Checks/BacklinksPluginChecks.swift Sources/Checks/main.swift
git commit -m "feat(sdk): surface ② MetadataQuerying (backlinks + index updates) and activeNotePath"
```

---

## Task 4: BacklinksPlugin + registration

**Files:**
- Create: `Sources/BacklinksPlugin/BacklinksPlugin.swift`
- Modify: `Package.swift` (new target; HanjiApp + Checks deps)
- Modify: `Sources/HanjiApp/HanjiApp.swift` (import + register)
- Modify: `Sources/Checks/BacklinksPluginChecks.swift` (second group)
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Package.swift** — add target:
```swift
        .target(name: "BacklinksPlugin", dependencies: ["ExtensionSDK"]),
```
Append `"BacklinksPlugin"` to HanjiApp deps AND Checks deps.

- [ ] **Step 2: Failing test** — append to `Sources/Checks/BacklinksPluginChecks.swift` (add `import BacklinksPlugin` at top):

```swift
func backlinksPluginChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-bp-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "# Target\nbody".write(to: vault.appendingPathComponent("Target.md"), atomically: true, encoding: .utf8)
    try? "보라 [[Target]] 링크".write(to: vault.appendingPathComponent("Source.md"), atomically: true, encoding: .utf8)

    let appState = AppState(defaults: UserDefaults(suiteName: "mk-bp-\(UUID().uuidString)")!)
    appState.openVault(at: vault)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    let pm = PluginManager()
    let host = Host(appState: appState, pluginManager: pm)
    pm.activate([BacklinksPlugin()], host: host)

    expectEqual(pm.sidebar.count, 1, "backlinks sidebar contribution registered")
    expectEqual(pm.sidebar.first?.title ?? "", "Backlinks", "panel title")
    _ = pm.sidebar.first?.makeView()   // view factory doesn't crash without a window

    // The same query path the view uses returns the linking note.
    try? appState.searchIndex?.reindexAll(vault: vault)
    let backs = host.query.backlinks(toNoteAt: "Target.md")
    expectEqual(backs.first?.sourcePath, "Source.md", "panel's data source finds the backlink")
}
```

- [ ] **Step 3: Register** — `("BacklinksPlugin", backlinksPluginChecks),` in main.swift.

- [ ] **Step 4: Red** — `swift run Checks BacklinksPlugin` → `no such module 'BacklinksPlugin'`.

- [ ] **Step 5: Implement `Sources/BacklinksPlugin/BacklinksPlugin.swift`**

```swift
import SwiftUI
import Combine
import ExtensionSDK

/// First-party backlinks panel: lists notes linking to the active note, with
/// context snippets; updates when the note changes or the index refreshes.
public struct BacklinksPlugin: Plugin {
    public static let id = "io.hanji.backlinks"
    public init() {}

    public func activate(host: PluginHost) {
        // Weak: the sidebar registry lives in PluginManager, which the host
        // retains — a strong capture here would be a retain cycle.
        host.ui.addSidebarView(id: "backlinks", title: "Backlinks") { [weak host] in
            guard let host else { return AnyView(EmptyView()) }
            return AnyView(BacklinksView(query: host.query,
                                         workspace: host.workspace,
                                         activePath: host.editor.activeNotePath,
                                         indexUpdates: host.query.indexDidUpdate))
        }
    }
}

struct BacklinksView: View {
    let query: MetadataQuerying
    let workspace: WorkspaceActions
    let activePath: AnyPublisher<String?, Never>
    let indexUpdates: AnyPublisher<Void, Never>

    @State private var currentPath: String?
    @State private var backlinks: [SDKBacklink] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if currentPath == nil {
                Text("Open a note to see its backlinks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if backlinks.isEmpty {
                Text("No backlinks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(backlinks) { link in
                    Button {
                        workspace.openNote(relativePath: link.sourcePath)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.sourceTitle).fontWeight(.medium).lineLimit(1)
                            Text(highlighted(link))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(activePath) { path in
            currentPath = path
            refresh()
        }
        .onReceive(indexUpdates) { refresh() }
    }

    private func refresh() {
        guard let path = currentPath else { backlinks = []; return }
        backlinks = query.backlinks(toNoteAt: path)
    }

    /// Slice the snippet by UTF-16 ranges, bolding each match.
    private func highlighted(_ link: SDKBacklink) -> AttributedString {
        let ns = link.snippet as NSString
        var out = AttributedString()
        var cursor = 0
        for range in link.matchRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
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
}
```

- [ ] **Step 6: Register the plugin** — in `Sources/HanjiApp/HanjiApp.swift`, add `import BacklinksPlugin` and change the plugins array to:
```swift
                    let plugins: [Plugin] = [WordCountPlugin(), PeriodicNotesPlugin(), TemplaterPlugin(), BacklinksPlugin()]
```

- [ ] **Step 7: Green** — `swift run Checks BacklinksPlugin` ✅, then full `swift run Checks` ✅, then `swift build` ✅.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/BacklinksPlugin Sources/HanjiApp/HanjiApp.swift Sources/Checks/BacklinksPluginChecks.swift Sources/Checks/main.swift
git commit -m "feat(backlinks): first-party Backlinks panel over SDK ② (right sidebar returns)"
```

---

## Task 5: E2E step + README + full verification

**Files:**
- Modify: `Sources/Checks/E2EChecks.swift`
- Modify: `README.md`

- [ ] **Step 1: E2E step** — in `Sources/Checks/E2EChecks.swift`, right after the "4b. Global search" block, insert:

```swift
    // 4c. Backlinks: a hub note linking [[Plan]] shows up as Plan's backlink.
    try? "허브: [[Plan]] 참고".write(to: root.appendingPathComponent("Hub.md"), atomically: true, encoding: .utf8)
    try? appState.searchIndex?.reindexAll(vault: root)
    let planBacklinks = (try? appState.searchIndex?.backlinks(of: "Projects/Plan.md")) ?? []
    expectEqual(planBacklinks.map(\.sourcePath), ["Hub.md"], "E2E: backlink found via link table")
```

- [ ] **Step 2: README** — add to the status list:
```markdown
- **Backlinks panel** — right sidebar lists notes linking to the active note
  (wikilinks + markdown links) with context snippets, live-updating; built as a
  first-party plugin on the SDK's `MetadataQuerying` surface
```

- [ ] **Step 3: Verify** — `swift run Checks` all green; `./Scripts/e2e.sh` green.

- [ ] **Step 4: Commit**

```bash
git add Sources/Checks/E2EChecks.swift README.md
git commit -m "test: backlinks E2E step + README"
```

---

## Self-review notes (vs spec)

- §3.1 LinkParser → Task 1 (incl. all skip rules + UTF-16 ranges). §3.2 v2 schema/upsert/remove/backlinks/normalize + snippet sharing → Task 2. §3.3 SDK types/protocols/Host (incl. activeNotePath via combineLatest with vaultRoot) → Task 3. §3.4 plugin + weak-host sidebar factory + 3-column auto-return (existing shell rule, no shell change needed) → Task 4. §4 tests → Tasks 1–4 + E2E in Task 5. §5 exclusions respected.
- Type consistency: `LinkRef{target,range}`, `LinkParser.links(in:)`, `SnippetWindow.make(body:around:highlight:)`, `Backlink{sourcePath,sourceTitle,snippet,matchRanges}`, `backlinks(of:) throws -> [Backlink]`, `normalizeTarget`, `SDKBacklink`, `MetadataQuerying.backlinks(toNoteAt:)/indexDidUpdate`, `EditorContext.activeNotePath`, `Host.query` — consistent across tasks.
- Known risks: `EditorContext` gains a member (only Host conforms — verified); MKSearchKit gains MarkdownCore dep (pure, no cycle: MarkdownCore depends on nothing).
