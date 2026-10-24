# Links Follow Renames, and Unlinked Mentions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** #12 per `2026-10-24-hanji-link-rename-design.md` — rename/move
rewrites links (undoable, announced in the status bar); the backlinks panel
lists unlinked mentions with a Link button.

**Architecture:** pure `LinkTarget` / `LinkRewrite` / `Mentions` in
MarkdownCore; `AppState` runs them over the vault on rename/move and records
the rewritten texts in the existing file-operation undo; SDK gains a mention
query and a link action that the Backlinks plugin uses.

**Tech Stack:** Swift 6.1, SwiftUI, GRDB (search index only); checks via `swift run Checks <Group>`.

## Global Constraints

- No new dependencies; macOS 14+.
- One resolution rule: `LinkTarget.resolve` (path or file name, no `.md`, ignoring case, first in file order).
- Writes go through `Vault.write` after `settleSaves()`, then `reloadTree()`.
- Undo restores only notes whose text is still exactly what Hanji wrote.
- Commits after 18:00 KST; no push unless asked.

---

### Task 1: `LinkTarget` and `openLink`

**Files:** Create `Sources/MarkdownCore/LinkTarget.swift`; modify
`Sources/AppCore/AppState.swift` (`openLink`, new `relativePath(of:)`);
create `Sources/Checks/LinkRenameChecks.swift`; register in `main.swift`.

**Produces:** `LinkTarget.resolve(_ target: String, in paths: [String]) -> String?`,
`LinkTarget.key(_:) -> String`, `AppState.relativePath(of: URL) -> String` (internal helper).

- [ ] **Step 1: Failing check**

```swift
func linkTargetChecks() {
    let paths = ["Inbox/Plan.md", "Projects/Plan.md", "Projects/Roadmap.md", "한지.md"]
    expectEqual(LinkTarget.resolve("Plan", in: paths), "Inbox/Plan.md", "a shared name goes to the first note in file order")
    expectEqual(LinkTarget.resolve("projects/plan", in: paths), "Projects/Plan.md", "a path, ignoring case")
    expectEqual(LinkTarget.resolve("Roadmap.md#Goals", in: paths), "Projects/Roadmap.md", "`.md` and the anchor are ignored")
    expectEqual(LinkTarget.resolve("한지", in: paths), "한지.md", "Korean names")
    expectEqual(LinkTarget.resolve("Nope", in: paths), nil, "no such note")
}
```

- [ ] **Step 2: Run** `swift run Checks LinkTarget` — fails to compile.
- [ ] **Step 3: Implement**

```swift
import Foundation

/// Which note a link names — the one rule link clicks, rename rewrites and
/// mention links share.
public enum LinkTarget {
    /// The note `target` names among `paths` (vault-relative, with `.md`, in
    /// file order): by path or by file name, without `.md`, ignoring case; the
    /// first match wins. A `#heading` is ignored.
    public static func resolve(_ target: String, in paths: [String]) -> String? {
        let wanted = key(target)
        guard !wanted.isEmpty else { return nil }
        return paths.first { path in
            let k = key(path)
            return k == wanted || (k as NSString).lastPathComponent == wanted
        }
    }

    /// `raw` as `resolve` compares it: trimmed, without `#…` or `.md`, lowercased.
    public static func key(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        if t.lowercased().hasSuffix(".md") { t = String(t.dropLast(3)) }
        return t.lowercased()
    }
}
```

`openLink` becomes:

```swift
    public func openLink(_ target: String, newTab: Bool = false) {
        guard vaultRoot != nil else { return }
        let paths = files.map { relativePath(of: $0.url) }
        guard let path = LinkTarget.resolve(target, in: paths),
              let match = files.first(where: { relativePath(of: $0.url) == path }) else { return }
        open(match, newTab: newTab)
    }

    /// `url` relative to the vault root (its file name when outside it).
    func relativePath(of url: URL) -> String {
        guard let root = vaultRoot?.standardizedFileURL.path else { return url.lastPathComponent }
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
    }
```

(`linkTargets` uses `relativePath(of:)` too.)

- [ ] **Step 4: Run** `swift run Checks LinkTarget AppState E2E TabHistory` — pass.

### Task 2: `LinkRewrite`

**Files:** Create `Sources/MarkdownCore/LinkRewrite.swift`; `LinkParser.markdownLinks` private → internal; checks in `LinkRenameChecks.swift`.

**Produces:** `LinkRewrite.rewrite(_ text: String, moves: [String: String], before: [String], after: [String]) -> (text: String, count: Int)`.

- [ ] **Step 1: Failing check**

```swift
func linkRewriteChecks() {
    let before = ["Archive/Roadmap.md", "Other.md", "Projects/Plan.md"]
    let after = ["Archive/Roadmap.md", "Other.md", "Projects/Roadmap.md"]
    let moves = ["Projects/Plan.md": "Projects/Roadmap.md"]
    func rw(_ t: String, _ m: [String: String] = moves, _ b: [String] = before, _ a: [String] = after) -> String {
        LinkRewrite.rewrite(t, moves: m, before: b, after: a).text
    }
    // Archive/Roadmap.md shares the new name, so a bare link goes to path form.
    expectEqual(rw("see [[Plan]]"), "see [[Projects/Roadmap]]", "a clash writes the path")
    let noClash = ["Projects/Roadmap.md", "Other.md"]
    let b2 = ["Projects/Plan.md", "Other.md"]
    expectEqual(rw("[[Plan]] [[plan#Goals|the plan]] ![[Plan]]", moves, b2, noClash),
                "[[Roadmap]] [[Roadmap#Goals|the plan]] ![[Roadmap]]", "bare names, anchor, alias, embed")
    expectEqual(rw("[[Projects/Plan]] [[Projects/Plan.md]]", moves, b2, noClash),
                "[[Projects/Roadmap]] [[Projects/Roadmap.md]]", "path form and a written .md are kept")
    expectEqual(rw("[t](Projects/Plan.md#x) [u](./Plan.md)", moves, b2, noClash),
                "[t](Projects/Roadmap.md#x) [u](./Roadmap.md)", "markdown links keep their form")
    expectEqual(rw("[[Other]] `[[Plan]]`\n```\n[[Plan]]\n```", moves, b2, noClash),
                "[[Other]] `[[Plan]]`\n```\n[[Plan]]\n```", "other notes and code are untouched")
    let moved = ["Projects/Plan.md": "Archive/Plan.md"]
    expectEqual(rw("[[Plan]] [[Projects/Plan]]", moved, b2, ["Archive/Plan.md", "Other.md"]),
                "[[Plan]] [[Archive/Plan]]", "a move leaves a bare name and fixes a path")
    expectEqual(rw("[a](Projects/Plan.md)", ["Projects/Plan.md": "My Notes/Plan.md"], b2, ["My Notes/Plan.md", "Other.md"]),
                "[a](My%20Notes/Plan.md)", "spaces in a new destination are %20")
    let shared = ["A/Plan.md", "B/Plan.md"]
    expectEqual(rw("[[Plan]]", ["B/Plan.md": "B/Next.md"], shared, ["A/Plan.md", "B/Next.md"]), "[[Plan]]",
                "a link to the other Plan isn't this rename's")
    expectEqual(LinkRewrite.rewrite("[[Plan]] and [[Plan]]", moves: moves, before: b2, after: noClash).count, 2, "count")
}
```

- [ ] **Step 2: Run** `swift run Checks LinkRewrite` — fails to compile.
- [ ] **Step 3: Implement**

```swift
import Foundation

/// Links rewritten for notes that moved: every wikilink, embed and markdown
/// link that named a moved note gets its new place, in the form it was
/// written (a bare name stays a bare name unless that would now name another
/// note; a path stays a path; `#anchor`, `|alias` and `.md` are kept).
public enum LinkRewrite {
    private static let wiki = try! NSRegularExpression(pattern: #"!?\[\[([^\[\]]+)\]\]"#)

    /// `moves`: old → new vault-relative paths. `before` / `after`: every
    /// note's path, in file order, before and after the move — what links
    /// resolved against then, and will now.
    public static func rewrite(_ text: String, moves: [String: String],
                               before: [String], after: [String]) -> (text: String, count: Int) {
        let ns = text as NSString
        let code = CodeBlockParser.allCodeRanges(in: text)
        func inCode(_ r: NSRange) -> Bool { code.contains { $0.overlaps(r.location..<NSMaxRange(r)) } }
        var edits: [(range: NSRange, text: String)] = []

        for m in wiki.matches(in: text, range: NSRange(location: 0, length: ns.length)) where !inCode(m.range) {
            let inner = m.range(at: 1)
            let innerText = ns.substring(with: inner)
            let cut = innerText.firstIndex { $0 == "|" || $0 == "#" } ?? innerText.endIndex
            let raw = String(innerText[..<cut])
            let written = raw.trimmingCharacters(in: .whitespaces)
            guard let new = moved(written, moves, before),
                  let replacement = target(for: written, at: new, after: after) else { continue }
            let lead = (raw.prefix { $0 == " " || $0 == "\t" } as Substring).utf16.count
            edits.append((NSRange(location: inner.location + lead, length: written.utf16.count), replacement))
        }
        for m in LinkParser.markdownLinks(ns) where !inCode(m.whole) {
            var dest = ns.substring(with: m.dest)
            guard !dest.contains("://"), !dest.hasPrefix("#"), !dest.hasPrefix("mailto:") else { continue }
            var anchor = ""
            if let hash = dest.firstIndex(of: "#") { anchor = String(dest[hash...]); dest = String(dest[..<hash]) }
            var path = dest.removingPercentEncoding ?? dest
            let dotSlash = path.hasPrefix("./")
            if dotSlash { path = String(path.dropFirst(2)) }
            guard path.lowercased().hasSuffix(".md"), let new = moved(path, moves, before),
                  let replacement = target(for: path, at: new, after: after) else { continue }
            let encoded = replacement.replacingOccurrences(of: " ", with: "%20")
            edits.append((m.dest, (dotSlash ? "./" : "") + encoded + anchor))
        }

        guard !edits.isEmpty else { return (text, 0) }
        let out = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            out.replaceCharacters(in: edit.range, with: edit.text)
        }
        return (out as String, edits.count)
    }

    /// Where the note `written` named before the move now lives, if it moved.
    private static func moved(_ written: String, _ moves: [String: String], _ before: [String]) -> String? {
        guard !written.isEmpty, let old = LinkTarget.resolve(written, in: before) else { return nil }
        return moves[old]
    }

    /// What to write for a link that said `written`, now naming `new` — or nil
    /// when `written` still names it as it is.
    private static func target(for written: String, at new: String, after: [String]) -> String? {
        let keepsExtension = written.lowercased().hasSuffix(".md")
        let path = String(new.dropLast(3))                     // `new` ends in .md
        var candidate = written.contains("/") ? path : (path as NSString).lastPathComponent
        if !written.contains("/"), LinkTarget.resolve(candidate, in: after) != new { candidate = path }
        guard LinkTarget.key(candidate) != LinkTarget.key(written) else { return nil }
        return keepsExtension ? candidate + ".md" : candidate
    }
}
```

- [ ] **Step 4: Run** `swift run Checks LinkRewrite LinkParser` — pass.

### Task 3: Rename/move rewrite links, status, undo

**Files:** `Sources/AppCore/AppState.swift`, `Sources/HanjiApp/ContentView.swift` (`statusBar`), checks.

**Produces:** `AppState.status: String?`; `FileOperation.renamed(from:to:links:)`,
`.moved(from:to:links:)` with `links: [RewrittenNote]`, `public typealias RewrittenNote = (url: URL, previous: String, replaced: String)`.

- [ ] **Step 1: Failing check**

```swift
func renameRewriteChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-rrw-\(UUID().uuidString)")
    try? fm.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func put(_ p: String, _ t: String) { try? t.write(to: root.appendingPathComponent(p), atomically: true, encoding: .utf8) }
    func read(_ p: String) -> String? { try? String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }
    put("Projects/Plan.md", "# Plan\nself: [[Plan]]"); put("Hub.md", "see [[Plan]] and [[Projects/Plan|p]]"); put("Other.md", "no links")
    let s = AppState(defaults: UserDefaults(suiteName: "mk-rrw-\(UUID().uuidString)")!)
    s.openVault(at: root)

    _ = try? s.rename(root.appendingPathComponent("Projects/Plan.md"), to: "Roadmap")
    expectEqual(read("Hub.md"), "see [[Roadmap]] and [[Projects/Roadmap|p]]", "links in other notes follow the rename")
    expectEqual(read("Projects/Roadmap.md"), "# Plan\nself: [[Roadmap]]", "and the note's links to itself")
    expectEqual(read("Other.md"), "no links", "notes without links are left alone")
    expectEqual(s.status, "Updated 3 links in 2 notes", "the status bar says what changed")

    put("Hub.md", "edited since")
    s.undoLastFileOperation()
    expect(fm.fileExists(atPath: root.appendingPathComponent("Projects/Plan.md").path), "undo moves the note back")
    expectEqual(read("Projects/Plan.md"), "# Plan\nself: [[Plan]]", "undo restores its text")
    expectEqual(read("Hub.md"), "edited since", "a note edited since keeps its newer text")
    s.notice = nil

    put("Hub.md", "see [[Projects/Plan]]")
    try? fm.createDirectory(at: root.appendingPathComponent("Archive"), withIntermediateDirectories: true)
    s.reloadTree()
    _ = try? s.move(root.appendingPathComponent("Projects"), into: root.appendingPathComponent("Archive"))
    expectEqual(read("Hub.md"), "see [[Archive/Projects/Plan]]", "moving a folder rewrites the paths under it")
}
```

- [ ] **Step 2: Run** `swift run Checks RenameRewrite` — fails (`status` unknown).
- [ ] **Step 3: Implement.** In `AppState`:

```swift
    /// A file's text before and after Hanji rewrote it (a replace, a rename's links).
    public typealias RewrittenNote = (url: URL, previous: String, replaced: String)

    /// A short message for the status bar ("Updated 3 links in 2 notes"),
    /// cleared after a few seconds.
    @Published public private(set) var status: String?
    private var statusClear: DispatchWorkItem?

    private func announce(_ message: String) {
        status = message
        statusClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in self?.status = nil }
        statusClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: clear)
    }
```

`FileOperation`: `case renamed(from: URL, to: URL, links: [RewrittenNote])`,
`case moved(from: URL, to: URL, links: [RewrittenNote])`, `case replaced([RewrittenNote])`.
In `rename` (and the same in `move`), capture `let before = files.map { relativePath(of: $0.url) }`
before the vault call, then inside the `if newURL != url` branch:

```swift
            let links = rewriteLinks(from: url, to: newURL, before: before)
            record(.renamed(from: url, to: newURL, links: links))
```

```swift
    /// Rewrite every link to the notes `url` → `newURL` moved (one note, or every
    /// note under a folder) and say how many changed.
    private func rewriteLinks(from url: URL, to newURL: URL, before: [String]) -> [RewrittenNote] {
        guard let v = vault else { return [] }
        let afterFiles = (try? v.markdownFiles()) ?? []
        let after = afterFiles.map { relativePath(of: $0.url) }
        let oldRel = relativePath(of: url), newRel = relativePath(of: newURL)
        var moves: [String: String] = [:]
        for path in after {
            if path == newRel { moves[oldRel] = path }
            else if path.hasPrefix(newRel + "/") { moves[oldRel + path.dropFirst(newRel.count)] = path }
        }
        guard !moves.isEmpty else { return [] }
        // Every form of link to a note contains its file name, so a note without
        // one of the names can't link to them — skip it without parsing.
        let names = Set(moves.keys.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension })
        var rewritten: [RewrittenNote] = []
        var count = 0
        for file in afterFiles {
            guard let text = try? v.read(file),
                  names.contains(where: { text.range(of: $0, options: .caseInsensitive) != nil }) else { continue }
            let result = LinkRewrite.rewrite(text, moves: moves, before: before, after: after)
            guard result.count > 0, (try? v.write(result.text, to: file)) != nil else { continue }
            rewritten.append((file.url, text, result.text))
            count += result.count
        }
        if count > 0 {
            announce("Updated \(count) link\(count == 1 ? "" : "s") in \(rewritten.count) note\(rewritten.count == 1 ? "" : "s")")
        }
        return rewritten
    }
```

Undo: factor the `.replaced` loop into `restore(_ notes: [RewrittenNote]) -> [String]`
(returns skipped names) plus the notice; `.renamed` / `.moved` restore first,
then move the file back (the restored URLs are the post-move ones):

```swift
        case .renamed(let from, let to, let links), .moved(let from, let to, let links):
            reportUnrestored(restore(links), after: "the rename")
            let followers = tabsFollowing(to)
            if (try? fm.moveItem(at: to, to: from)) != nil { retarget(followers, to: from) }
        case .replaced(let entries):
            reportUnrestored(restore(entries), after: "the replace")
```

`ContentView.statusBar`: show the bar when `appState.status != nil` too, with
`Text(status).font(.caption).foregroundStyle(.secondary)` before the `Spacer()`.

- [ ] **Step 4: Run** `swift run Checks RenameRewrite ReplaceUndo AppStateUndo VaultOps VaultMove RenameName AppStateTree E2E` — pass.

### Task 4: Mentions, the index query, the SDK, the panel

**Files:** Create `Sources/MarkdownCore/Mentions.swift`; `Sources/MKSearchKit/SearchIndex.swift`
(`notes(containing:limit:)`), `SnippetWindow.make` public; `Sources/ExtensionSDK/ExtensionSDK.swift`;
`Sources/AppCore/Host.swift`; `Sources/AppCore/AppState.swift` (`linkMention`);
`Sources/BacklinksPlugin/BacklinksPlugin.swift`; checks.

**Produces:** `Mentions.unlinked(of:in:) -> [Range<Int>]`; `SearchIndex.notes(containing: String, limit: Int) throws -> [String]` (paths);
`SDKMention`; `MetadataQuerying.unlinkedMentions(ofNoteAt:)`; `WorkspaceActions.linkMention(sourcePath:range:targetPath:) -> Bool`;
`AppState.linkMention(sourcePath:range:targetPath:) -> Bool`.

- [ ] **Step 1: Failing checks**

```swift
func mentionChecks() {
    func found(_ name: String, _ text: String) -> [String] {
        Mentions.unlinked(of: name, in: text).map { (text as NSString).substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
    }
    expectEqual(found("Plan", "The plan, a Plan; Planning, unplanned."), ["plan", "Plan"], "whole words, any case")
    expectEqual(found("한지", "한지는 종이다. 닥나무한지 아님"), ["한지"], "a particle may follow, a letter may not precede")
    expectEqual(found("Plan", "[[Plan]] `Plan` [p](Plan.md)\n```\nPlan\n```"), [], "not in links or code")
    expectEqual(found("Plan", "---\ntitle: Plan\n---\nPlan"), ["Plan"], "not in frontmatter")
}

func linkMentionChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-lm-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func put(_ p: String, _ t: String) { try? t.write(to: root.appendingPathComponent(p), atomically: true, encoding: .utf8) }
    func read(_ p: String) -> String? { try? String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }
    put("Plan.md", "x"); put("Hub.md", "the plan and Plan")
    let s = AppState(defaults: UserDefaults(suiteName: "mk-lm-\(UUID().uuidString)")!)
    s.openVault(at: root)
    expect(s.linkMention(sourcePath: "Hub.md", range: 4..<8, targetPath: "Plan.md"), "a mention is linked")
    expectEqual(read("Hub.md"), "the [[Plan|plan]] and Plan", "different case keeps the text as an alias")
    expect(!s.linkMention(sourcePath: "Hub.md", range: 4..<8, targetPath: "Plan.md"), "a stale range writes nothing")
    s.undoLastFileOperation()
    expectEqual(read("Hub.md"), "the plan and Plan", "⌥⌘Z undoes it")
    expect(s.linkMention(sourcePath: "Hub.md", range: 13..<17, targetPath: "Plan.md"), "same case")
    expectEqual(read("Hub.md"), "the plan and [[Plan]]", "is a plain link")
}
```

- [ ] **Step 2: Run** `swift run Checks Mentions LinkMention` — fails to compile.
- [ ] **Step 3: Implement.** `Mentions.swift`:

```swift
import Foundation

/// Where a note's name appears in another note's text without a link — the
/// backlinks panel's "Unlinked mentions".
public enum Mentions {
    private static let wiki = try! NSRegularExpression(pattern: #"!?\[\[[^\[\]]+\]\]"#)

    /// Ranges of `name` in `text`, ignoring case, outside code, frontmatter and
    /// links. No letter or digit may come before it, and no ASCII letter or digit
    /// after — "Plan" isn't in "Planning", but "한지" is in "한지는".
    public static func unlinked(of name: String, in text: String) -> [Range<Int>] {
        let ns = text as NSString
        let needle = name.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var excluded = CodeBlockParser.allCodeRanges(in: text)
        if let front = Frontmatter.range(in: text) { excluded.append(front) }
        excluded += wiki.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range.location..<NSMaxRange($0.range) }
        excluded += LinkParser.markdownLinks(ns).map { $0.whole.location..<NSMaxRange($0.whole) }
        var out: [Range<Int>] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: needle, options: .caseInsensitive, range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            from = NSMaxRange(r)
            let range = r.location..<NSMaxRange(r)
            guard !excluded.contains(where: { $0.overlaps(range) }) else { continue }
            if r.location > 0 {
                let prev = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: r.location - 1))
                if prev.first.map({ $0.isLetter || $0.isNumber || $0 == "_" }) == true { continue }
            }
            if NSMaxRange(r) < ns.length {
                let next = ns.character(at: NSMaxRange(r))
                if next < 0x80, let scalar = Unicode.Scalar(next),
                   scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) || next == 0x5F { continue }
            }
            out.append(range)
        }
        return out
    }
}
```

`SearchIndex.notes(containing:limit:)` — the paths of notes whose body holds
`text` (FTS trigram MATCH for 3+ characters, the LIKE scan otherwise, same
escaping as `search`). `SnippetWindow` and `make` become `public`.

ExtensionSDK:

```swift
/// A note naming another without linking to it (SDK-owned type).
public struct SDKMention: Identifiable {
    public let sourcePath: String
    public let sourceTitle: String
    public let snippet: String
    public let matchRanges: [Range<Int>]   // UTF-16 ranges inside `snippet`
    public let range: Range<Int>           // the mention, in the source note's text
    public var id: String { "\(sourcePath):\(range.lowerBound)" }
    public init(sourcePath: String, sourceTitle: String, snippet: String, matchRanges: [Range<Int>], range: Range<Int>) { … }
}
```

`MetadataQuerying.unlinkedMentions(ofNoteAt:) -> [SDKMention]` and
`WorkspaceActions.linkMention(sourcePath:range:targetPath:) -> Bool`, each
with a default in a protocol extension (`[]` / `false`) so other conformers
keep compiling. `Host`:

```swift
    public func unlinkedMentions(ofNoteAt relativePath: String) -> [SDKMention] {
        let name = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let candidates = (try? appState.searchIndex?.notes(containing: name, limit: 200)) ?? []
        var out: [SDKMention] = []
        for path in candidates where path != relativePath {
            guard let text = appState.readNote(relativePath: path) else { continue }
            let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            for range in Mentions.unlinked(of: name, in: text) {
                let (snippet, ranges) = SnippetWindow.make(body: text, around: NSRange(location: range.lowerBound, length: range.count), highlight: name)
                out.append(SDKMention(sourcePath: path, sourceTitle: title, snippet: snippet, matchRanges: ranges, range: range))
                if out.count == 50 { return out }
            }
        }
        return out
    }

    public func linkMention(sourcePath: String, range: Range<Int>, targetPath: String) -> Bool {
        appState.linkMention(sourcePath: sourcePath, range: range, targetPath: targetPath)
    }
```

`AppState.linkMention`:

```swift
    /// Turn the unlinked mention at `range` in `sourcePath` into a link to
    /// `targetPath` — `[[Name|text]]` when the text's case differs, path form
    /// when another note shares the name. Writes nothing (false) when that
    /// range no longer holds such a mention. Undoable like a replace.
    public func linkMention(sourcePath: String, range: Range<Int>, targetPath: String) -> Bool {
        guard let v = vault, let url = urlInsideVault(sourcePath) else { return false }
        settleSaves()
        let file = MarkdownFile(url: url)
        let name = ((targetPath as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let text = try? v.read(file), Mentions.unlinked(of: name, in: text).contains(range) else { return false }
        let ns = text as NSString
        let nsRange = NSRange(location: range.lowerBound, length: range.count)
        let shown = ns.substring(with: nsRange)
        let paths = files.map { relativePath(of: $0.url) }
        let target = LinkTarget.resolve(name, in: paths) == targetPath ? name : String(targetPath.dropLast(3))
        let updated = ns.replacingCharacters(in: nsRange, with: shown == target ? "[[\(target)]]" : "[[\(target)|\(shown)]]")
        guard (try? v.write(updated, to: file)) != nil else { return false }
        record(.replaced([(url, text, updated)]))
        reloadTree()
        return true
    }
```

`BacklinksView`: `@State mentions: [SDKMention]`, `@State showMentions = false`;
`refresh()` also loads `query.unlinkedMentions(ofNoteAt:)`; below the
backlinks a `DisclosureGroup("Unlinked mentions (\(mentions.count))", isExpanded: $showMentions)`
listing each mention like a backlink row plus a `Button("Link")` that calls
`workspace.linkMention(…)` and then `refresh()`. `highlighted(_:)` takes
`(snippet, matchRanges)` so both row kinds share it.

- [ ] **Step 4: Run** `swift build && swift run Checks Mentions LinkMention BacklinksPlugin SearchIndex SearchQuery MetadataQuerying` — pass.

### Task 5: Docs and a look at the app

- [ ] README: Workspace bullet for link updates on rename/move and unlinked
  mentions; CHANGELOG `[Unreleased]` › Workspace lines; README "Status" no change.
- [ ] `swift run Checks --changed --slow` — all pass.
- [ ] Launch the debug app on a scratch vault (a note `Plan.md`, a hub
  linking `[[Plan]]`, a note mentioning "plan"), screenshot the backlinks panel
  with the mentions group; rename `Plan` → `Roadmap` through AppState from a
  check rather than synthetic clicks, and confirm the hub's text on disk.
  Kill the app by PID.
- [ ] Commit `feat(links): rename and move rewrite links; unlinked mentions (#12)`.
