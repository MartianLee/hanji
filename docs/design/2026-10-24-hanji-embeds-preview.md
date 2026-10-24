# Note Embeds and Link Previews — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** per `2026-10-24-hanji-embeds-preview-design.md` — own-line
`![[Note]]` renders the note as a card; resting on a link (⌘ while editing)
shows a preview popover.

**Architecture:** `NoteEmbeds` (MarkdownCore) finds embeds and sections;
`RenderedText` (EditorEngine) turns Markdown into marker-free attributed text;
`NoteCardView` shows it in the embed widget and in an `NSPopover` driven by
pointer tracking in `ClickableTextView`. The app supplies notes through
`MarkdownEditorView.notePreview`.

**Tech Stack:** Swift 6.1, AppKit/TextKit 2, SwiftUI; checks via `swift run Checks <Group>`.

## Global Constraints

- Live Preview invariants hold (no synchronous restyle in selection callbacks,
  full-document layout stays) — embeds are ordinary widgets in the existing pass.
- No recursion: rendered text never contains widgets.
- Commits after 18:00 KST; no push unless asked.

---

### Task 1: `NoteEmbeds`

**Files:** Create `Sources/MarkdownCore/NoteEmbeds.swift`, `Sources/Checks/EmbedPreviewChecks.swift`; register groups in `main.swift`.

**Produces:**
```swift
public struct NoteEmbed: Equatable { public let target: String; public let heading: String?; public let line: Range<Int> }
public enum NoteEmbeds {
    public static func embeds(in text: String) -> [NoteEmbed]
    public static func section(_ heading: String, in text: String) -> String?
    public static func heading(inLink source: String) -> String?
}
```

- [ ] **Step 1: Failing check**

```swift
func noteEmbedChecks() {
    let text = "a\n![[Plan]]\n![[img.png]]\n  ![[Plan#Goals|g]]\n![alt](x.png)\n![[Note v1.2]]\n![[Doc.md]]"
    let e = NoteEmbeds.embeds(in: text)
    expectEqual(e.map(\.target), ["Plan", "Plan", "Note v1.2", "Doc.md"], "note embeds only, not images")
    expectEqual(e.map(\.heading), [nil, "Goals", nil, nil], "the #heading")
    expectEqual(e.first?.line, 2..<11, "the whole line")
    let note = "intro\n# Goals\nfirst\n## Sub\ndeeper\n# Next\nafter"
    expectEqual(NoteEmbeds.section("goals", in: note), "# Goals\nfirst\n## Sub\ndeeper", "to the next heading of its level")
    expectEqual(NoteEmbeds.section("Sub", in: note), "## Sub\ndeeper", "a subsection ends at a higher heading")
    expectEqual(NoteEmbeds.section("Missing", in: note), nil, "no such heading")
    expectEqual(NoteEmbeds.heading(inLink: "[[Plan#Goals|the plan]]"), "Goals", "wikilink heading")
    expectEqual(NoteEmbeds.heading(inLink: "[t](Plan.md#Goals)"), "Goals", "markdown link anchor")
    expectEqual(NoteEmbeds.heading(inLink: "[[Plan]]"), nil, "none")
}
```

- [ ] **Step 2: Run** `swift run Checks NoteEmbeds` — fails to compile.
- [ ] **Step 3: Implement**

```swift
import Foundation

/// An own-line `![[Note]]` that names a note (not an image or other file).
public struct NoteEmbed: Equatable {
    public let target: String      // without `#heading` or `|alias`
    public let heading: String?
    public let line: Range<Int>    // the whole line (UTF-16)
    public init(target: String, heading: String?, line: Range<Int>) {
        self.target = target; self.heading = heading; self.line = line
    }
}

public enum NoteEmbeds {
    /// Own-line `![[…]]` embeds whose target is a note: no extension, `.md`, or
    /// something after a dot that isn't a file extension (`Note v1.2`).
    public static func embeds(in text: String) -> [NoteEmbed] {
        let ns = text as NSString
        return ImageParser.images(in: text).compactMap { ref in
            let line = ns.substring(with: NSRange(location: ref.line.lowerBound, length: ref.line.count))
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("![[") else { return nil }
            var target = ref.path, heading: String?
            if let hash = target.firstIndex(of: "#") {
                heading = String(target[target.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
                target = String(target[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            let ext = (target as NSString).pathExtension.lowercased()
            let isFile = !ext.isEmpty && ext != "md" && ext.count <= 4 && ext.allSatisfy(\.isLetter)
            guard !target.isEmpty, !isFile else { return nil }
            return NoteEmbed(target: target, heading: heading?.isEmpty == true ? nil : heading, line: ref.line)
        }
    }

    /// The section a heading opens — its line through the line before the next
    /// heading of the same or a higher level — or nil when no heading has that
    /// title (ignoring case).
    public static func section(_ heading: String, in text: String) -> String? {
        let ns = text as NSString
        let headings = Outline.headings(in: text)
        guard let i = headings.firstIndex(where: { $0.title.caseInsensitiveCompare(heading) == .orderedSame }) else { return nil }
        let start = headings[i].offset
        let end = headings[(i + 1)...].first { $0.level <= headings[i].level }?.offset ?? ns.length
        return ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .newlines)
    }

    /// The `#heading` a link's source names: `[[Plan#Goals|x]]`, `[t](Plan.md#Goals)`.
    public static func heading(inLink source: String) -> String? {
        guard let hash = source.firstIndex(of: "#") else { return nil }
        let rest = source[source.index(after: hash)...]
        let end = rest.firstIndex { $0 == "|" || $0 == "]" || $0 == ")" } ?? rest.endIndex
        let heading = (rest[..<end].removingPercentEncoding ?? String(rest[..<end])).trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }
}
```

(`OutlineHeading.offset` is the heading line's start.)

- [ ] **Step 4: Run** `swift run Checks NoteEmbeds Outline ImageParser` — pass.

### Task 2: `RenderedText` and `NoteCardView`

**Files:** Create `Sources/EditorEngine/RenderedText.swift`, `Sources/EditorEngine/NoteCardView.swift`; checks.

**Produces:** `RenderedText.attributed(_:) -> NSAttributedString`;
`public struct NotePreview { title: String; text: String }`;
`struct NoteCardView: View { init(title: String, markdown: String?, heading: String?, width: CGFloat, maxHeight: CGFloat) }`
(`markdown == nil` → the not-found card).

- [ ] **Step 1: Failing check**

```swift
func renderedTextChecks() {
    let md = "---\ntags: [a]\n---\n# Title\nSome **bold** and [[Link|alias]].\n- item\n- [ ] todo\n- [x] done\n```swift\nlet x = 1\n```"
    let r = RenderedText.attributed(md)
    expectEqual(r.string, "Title\nSome bold and alias.\n• item\n☐ todo\n☑ done\nlet x = 1", "markers, fences and frontmatter gone; bullets and boxes drawn")
    let font = r.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    expect((font?.pointSize ?? 0) > LivePreviewStyler.baseFontSize, "the heading keeps its size")
    let bold = r.attribute(.font, at: (r.string as NSString).range(of: "bold").location, effectiveRange: nil) as? NSFont
    expect(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true, "bold stays bold")
}
```

- [ ] **Step 2: Run** `swift run Checks RenderedText` — fails to compile.
- [ ] **Step 3: Implement** `RenderedText.attributed`: drop frontmatter (and
  the newlines after it); tokenize; `LivePreviewStyler.apply(Decorator.decorations(spans:selection: nil))`
  on an `NSTextStorage`; collect edits — every hidden range → `""`; each
  `.listItem` span's `- ` (at its first non-blank) → `"• "`; each `.task(done)`
  `- [ ] ` → `"☐ "` / `"☑ "`; each `CodeBlockParser.regions` fence line (the
  opening line with its newline, the closing line) → `""`; apply back to
  front, skipping any edit overlapping one already applied. `NoteCardView`:
  a `VStack` of the title (`.headline`, secondary) and an `NSTextField`
  label (`RenderedLabel: NSViewRepresentable`, wrapping at `width - 24`,
  `maximumNumberOfLines = 0`) inside a 3 pt accent bar + faint fill, rounded
  6 pt; `.frame(maxHeight: maxHeight, alignment: .top).clipped()` with a
  bottom fade when the text's measured height exceeds it; for `nil` markdown
  a secondary "“title” isn't a note in this vault".
- [ ] **Step 4: Run** `swift run Checks RenderedText` — pass.

### Task 3: Embed widgets

**Files:** `Sources/EditorEngine/MarkdownEditorView.swift` (param, `noteEmbedWidgets`),
`Sources/Checks/EditorInputChecks.swift` (harness `notePreview`), `Sources/AppCore/AppState.swift`
(`notePreview(for:)`), `Sources/HanjiApp/ContentView.swift`; checks.

**Produces:** `MarkdownEditorView(…, notePreview: ((String) -> NotePreview?)? = nil)`;
`AppState.notePreview(for target: String) -> NotePreview?`.

- [ ] **Step 1: Failing check**

```swift
func editorEmbedChecks() {
    let note = "Top\n![[Plan]]\nBelow\n![[Gone]]\nEnd"
    let ns = note as NSString
    let previews = ["Plan": NotePreview(title: "Plan", text: "# Plan\nThe plan's body.")]
    guard let h = EditorHarness(note, cursorOffset: ns.length, notePreview: { previews[$0] }) else { expect(false, "editor"); return }
    defer { h.close() }
    h.pump(0.5)
    let cards = h.textView.subviews.filter { $0.fittingSize.height > 30 }
    expectEqual(cards.count, 2, "both embeds are cards (a missing note too)")
    let below = ns.range(of: "Below").location
    func top(_ offset: Int) -> CGFloat { h.textView.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil).minY }
    let withCard = top(below)
    h.caret(at: ns.range(of: "![[Plan]]").location + 3); h.pump(0.4)
    expect(abs(top(below) - withCard) > 20, "the caret on the line brings the source back")
}
```

- [ ] **Step 2: Run** `swift run Checks EditorEmbed` — fails to compile.
- [ ] **Step 3: Implement.** Parameter + `sync`; in the widget pass after images:

```swift
            specs.append(contentsOf: noteEmbedWidgets(caret: caret, nstext: nstext, width: width))
```

```swift
        /// Own-line `![[Note]]`: the note, rendered, as a card. Its text is part
        /// of the key, so an edit to the embedded note redraws the card.
        func noteEmbedWidgets(caret: Range<Int>?, nstext: NSString, width: CGFloat) -> [WidgetSpec] {
            guard let notePreview = parent.notePreview else { return [] }
            return NoteEmbeds.embeds(in: nstext as String).compactMap { embed in
                if intersects(embed.line, caret) { return nil }
                let preview = notePreview(embed.target)
                let view = AnyView(NoteCardView(title: preview?.title ?? embed.target, markdown: preview?.text,
                                                heading: embed.heading, width: width, maxHeight: 400))
                return WidgetSpec(key: "embed-\(preview?.text.hashValue ?? 0)", region: embed.line, view: view, maxHeight: 400)
            }
        }
```

(`width` moves above the widget-spec list in `updateWidgets`.) Harness:
`notePreview` init parameter, kept and passed by `rebuild()`. `AppState`:

```swift
    /// The note a link target names, for embeds and previews: its title and
    /// text — an open tab's, unsaved edits included.
    public func notePreview(for target: String) -> NotePreview? {
        let paths = files.map { relativePath(of: $0.url) }
        guard let path = LinkTarget.resolve(target, in: paths),
              let file = files.first(where: { relativePath(of: $0.url) == path }) else { return nil }
        let text = buffer(for: file)?.text ?? (try? vault?.read(file)) ?? nil
        return text.map { NotePreview(title: file.url.deletingPathExtension().lastPathComponent, text: $0) }
    }
```

(`NotePreview` lives in EditorEngine; AppCore already depends on it? —
if not, put `NotePreview` in ExtensionSDK, which both import.) `ContentView`
passes `notePreview: { appState.notePreview(for: $0) }`.

- [ ] **Step 4: Run** `swift run Checks EditorEmbed EditorReading EditorTable EditorScroll CodeSlabOnOpen` — pass.

### Task 4: Link previews

**Files:** `MarkdownEditorView.swift` (`ClickableTextView` tracking; `Coordinator.hover`), checks.

**Produces:** `public func hover(at offset: Int?, modifiers: NSEvent.ModifierFlags)`,
`public var isPreviewShown: Bool`, `static let previewDelay: TimeInterval = 0.5`.

- [ ] **Step 1: Failing check**

```swift
func editorLinkPreviewChecks() {
    let note = "See [[Plan]] and [[Gone]] here."
    let ns = note as NSString
    let at = ns.range(of: "Plan").location, gone = ns.range(of: "Gone").location
    let previews = ["Plan": NotePreview(title: "Plan", text: "Body")]
    guard let h = EditorHarness(note, cursorOffset: ns.length, notePreview: { previews[$0] }) else { expect(false, "editor"); return }
    defer { h.close() }
    guard let c = h.textView.delegate as? MarkdownEditorView.Coordinator else { expect(false, "coordinator"); return }
    c.hover(at: at, modifiers: []); h.pump(0.7)
    expect(!c.isPreviewShown, "editing: resting without ⌘ shows nothing")
    c.hover(at: at, modifiers: .command); h.pump(0.3)
    expect(!c.isPreviewShown, "not before the delay")
    h.pump(0.4)
    expect(c.isPreviewShown, "editing: ⌘ + rest shows the preview")
    c.hover(at: 0, modifiers: .command); h.pump(0.8)
    expect(!c.isPreviewShown, "leaving the link closes it")
    c.hover(at: gone, modifiers: .command); h.pump(0.7)
    expect(!c.isPreviewShown, "a missing note has no preview")
    h.isReading = true; h.rebuild()
    c.hover(at: at, modifiers: []); h.pump(0.7)
    expect(c.isPreviewShown, "reading: resting is enough")
    h.isReading = false; h.rebuild()
    expect(!c.isPreviewShown, "a mode switch closes it")
}
```

- [ ] **Step 2: Run** `swift run Checks EditorLinkPreview` — fails to compile.
- [ ] **Step 3: Implement.** `ClickableTextView`: `updateTrackingAreas` adds
  one `[.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]`
  area; `mouseMoved` → `onHover?(characterIndexForInsertion(at:) if the point
  is over text, event.modifierFlags)`; `flagsChanged` → `onHover` with the last
  offset; `mouseExited` → `onHover?(nil, [])`. `Coordinator`:
  - `hover(at:modifiers:)`: find the `LinkParser.links` ref containing the
    offset (links cached per text); allowed when `parent.isReading ||
    modifiers.contains(.command)`; if it's the link already shown, keep it;
    else cancel the pending timer, schedule `previewDelay` to show it, and if
    off any link, schedule a close after 0.3 s that re-checks while the pointer
    is inside the popover's window.
  - show: `notePreview(target)` (nil → nothing); content =
    `NoteEmbeds.section(heading)` when the link names one; `NSPopover`
    (`.semitransient`, `NSHostingController(rootView: NoteCardView(…, width: 360, maxHeight: 320))`
    wrapped in a `ScrollView`), shown relative to the link's first glyph rect
    (`firstRect(forCharacterRange:)` converted from screen) with `.maxY`.
  - close on `textDidChange`, `clipViewDidScroll`, `handleClick`, `setReading`.
- [ ] **Step 4: Run** `swift run Checks EditorLinkPreview EditorEmbed EditorBinding EditorSnapshotClick EditorTagClick` — pass.

### Task 5: Docs, full checks, a look

- [ ] README Editing bullets (embeds; previews with ⌘ / reading mode); CHANGELOG.
- [ ] `swift run Checks --changed --slow` — all pass.
- [ ] Screenshot a note with an embed in the debug app; kill it by PID.
- [ ] Commit `feat(editor): note embeds and link previews`.
