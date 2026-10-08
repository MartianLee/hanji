# Outline Panel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a right-sidebar Outline panel (issue #3): the open note's headings, a click jumps to one with its line at the top, and the current section's heading is highlighted.

**Architecture:** `Outline` (MarkdownCore) derives headings from `InlineTokenizer` spans. Two SDK additions — `EditorContext.focusOffset`, `WorkspaceActions.reveal(offset:)` — are backed by `AppState` and the editor (a top-placed jump reusing `pendingScrollAnchor`, and a viewport-top callback). A first-party `OutlinePlugin` renders the panel.

**Tech Stack:** Swift 5.10 / SPM, SwiftUI + AppKit + TextKit 2, Combine, the `Checks` runner (`swift run Checks <Group>`).

**Spec:** `docs/design/2026-10-09-hanji-outline-design.md`

## Global Constraints

- Headings come only from `InlineTokenizer.spans(in:)` `.heading` spans — no second heading parser.
- `focusOffset` must not go through `objectWillChange` (no `@Published`): it changes on every caret move.
- Existing jumps (search results, Back/Forward, tab switch) keep their placement; only `reveal(offset:)` places the line at the top.
- TextKit 2 invariants hold: the full-document `ensureLayout` in `layOutNote` stays; never restyle while `hasMarkedText()`.
- `swift run Checks` (all groups) passes at the end of every task; `swift build` adds no warnings.
- Comments match the surrounding code: full sentences explaining *why*, no change-log comments.

## Files

| File | Change |
|---|---|
| `Sources/MarkdownCore/Outline.swift` | new: `OutlineHeading`, `Outline.headings(in:)`, `Outline.current(in:at:)` |
| `Sources/ExtensionSDK/ExtensionSDK.swift` | `EditorContext.focusOffset`, `WorkspaceActions.reveal(offset:)` |
| `Sources/AppCore/AppState.swift` | focus subject, `viewportMoved(top:)`, `reveal(offset:)`, `pendingJumpToTop` |
| `Sources/AppCore/Host.swift` | forwards the two SDK members |
| `Sources/EditorEngine/MarkdownEditorView.swift` | `jumpsToTop`, `onViewportTopChange` |
| `Sources/OutlinePlugin/OutlinePlugin.swift` | new target |
| `Package.swift`, `Sources/HanjiApp/HanjiApp.swift`, `Sources/HanjiApp/ContentView.swift` | wiring |
| `Sources/Checks/OutlineChecks.swift` | new: all outline checks |
| `Sources/Checks/EditorInputChecks.swift` | `EditorHarness` gains `jumpsToTop`, `viewportTops` |
| `Sources/Checks/main.swift` | new groups |
| `README.md`, `CHANGELOG.md` | feature line, known gaps, Unreleased |

---

### Task 1: `Outline` — the note's headings

**Files:**
- Create: `Sources/MarkdownCore/Outline.swift`, `Sources/Checks/OutlineChecks.swift`
- Modify: `Sources/Checks/main.swift`

**Interfaces:**
- Produces: `public struct OutlineHeading: Equatable { level: Int; title: String; offset: Int; init(level:title:offset:) }`; `Outline.headings(in: String) -> [OutlineHeading]`; `Outline.current(in: [OutlineHeading], at: Int) -> Int?`.

- [ ] **Step 1: Write the failing test** — create `Sources/Checks/OutlineChecks.swift`:

```swift
import Foundation
import MarkdownCore

/// The outline lists the headings the editor styles as headings — none from
/// fenced code or frontmatter — with their visible text.
func outlineChecks() {
    let note = """
    ---
    title: x
    ---
    # Top
    intro #tag
    ## **Bold** and [[Target|Alias]] and `code` ##
    ```md
    # not a heading
    ```
    #nospace
    ### Third
    """
    let h = Outline.headings(in: note)
    expectEqual(h.map(\.level), [1, 2, 3], "levels, in order; none from frontmatter, code or #tag")
    expectEqual(h.map(\.title), ["Top", "Bold and Alias and code", "Third"],
                "titles keep the visible text and drop a closing ## run")
    let ns = note as NSString
    expectEqual(h.map(\.offset), [ns.range(of: "# Top").location, ns.range(of: "## **Bold**").location,
                                  ns.range(of: "### Third").location], "offsets are the heading lines' starts")

    expect(Outline.headings(in: "```\n# inside an unclosed fence").isEmpty, "an unclosed fence holds no headings")
    expect(Outline.headings(in: "plain text\n").isEmpty, "a note without headings has none")

    expectEqual(Outline.current(in: h, at: 0), nil, "before the first heading: none current")
    expectEqual(Outline.current(in: h, at: h[1].offset), 1, "on a heading line: that heading")
    expectEqual(Outline.current(in: h, at: h[1].offset + 3), 1, "inside its section: still that heading")
    expectEqual(Outline.current(in: h, at: ns.length), 2, "at the end: the last heading")

    // Recomputed (throttled) while typing, so a long note must stay cheap.
    let long = (0..<1000).map { "## Section \($0)\nSome **bold** text and a [[link]].\n- item\n\n" }.joined()
    let t0 = Date()
    let many = Outline.headings(in: long)
    let elapsed = Date().timeIntervalSince(t0)
    expectEqual(many.count, 1000, "every heading of a 4,000-line note")
    expect(elapsed < 0.25 * Check.timeSlack, "a 4,000-line note's outline in \(elapsed)s")
}
```

Register in `Sources/Checks/main.swift` after `("Decoration", decorationChecks),`:

```swift
    ("Outline", outlineChecks),
```

- [ ] **Step 2: Run to see it fail** — `swift run Checks Outline` → compile error `cannot find 'Outline' in scope`.

- [ ] **Step 3: Implement** — create `Sources/MarkdownCore/Outline.swift`:

```swift
import Foundation

/// A heading as the outline lists it.
public struct OutlineHeading: Equatable {
    /// 1...6, the number of `#`.
    public let level: Int
    /// The visible text: inline markers removed, a closing `#` run dropped.
    public let title: String
    /// UTF-16 offset of the heading line's start.
    public let offset: Int

    public init(level: Int, title: String, offset: Int) {
        self.level = level; self.title = title; self.offset = offset
    }
}

/// A note's headings, taken from the editor's own tokenizer so the outline
/// can't disagree with what the editor styles as a heading: fenced code
/// (unclosed fences too) and frontmatter hold none.
public enum Outline {
    public static func headings(in text: String) -> [OutlineHeading] {
        let ns = text as NSString
        let spans = InlineTokenizer.spans(in: text)
        return spans.compactMap { span in
            guard case .heading(let level) = span.style else { return nil }
            return OutlineHeading(level: level, title: title(of: span, among: spans, in: ns),
                                  offset: span.line.lowerBound)
        }
    }

    /// The index of the heading whose section holds `offset` — the last one at
    /// or before it; nil before the first heading.
    public static func current(in headings: [OutlineHeading], at offset: Int) -> Int? {
        headings.lastIndex { $0.offset <= offset }
    }

    /// The heading's content without the markers of the other spans on its line
    /// (`**`, `[[target|`, backticks), trimmed, and without a closing `#` run.
    private static func title(of heading: MarkSpan, among spans: [MarkSpan], in ns: NSString) -> String {
        let content = heading.content
        let text = NSMutableString(string: ns.substring(with: NSRange(location: content.lowerBound,
                                                                      length: content.count)))
        let markers = spans.filter { $0.line == heading.line && $0 != heading }.flatMap(\.markers)
            .compactMap { m -> Range<Int>? in
                let lo = max(m.lowerBound, content.lowerBound), hi = min(m.upperBound, content.upperBound)
                return lo < hi ? (lo - content.lowerBound)..<(hi - content.lowerBound) : nil
            }
            .sorted { $0.lowerBound > $1.lowerBound }
        for m in markers { text.deleteCharacters(in: NSRange(location: m.lowerBound, length: m.count)) }
        var title = (text as String).trimmingCharacters(in: .whitespaces)
        if let closing = title.range(of: #"(^|\s+)#+$"#, options: .regularExpression) {
            title.removeSubrange(closing)
        }
        return title
    }
}
```

- [ ] **Step 4: Run and pass** — `swift run Checks Outline` → passes. If a title assertion fails because a span's markers differ from what the comment assumes (e.g. inline code markers), report the actual spans for that line (NEEDS_CONTEXT) rather than special-casing the title. Then `swift run Checks` → all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownCore/Outline.swift Sources/Checks/OutlineChecks.swift Sources/Checks/main.swift
git commit -m "feat(core): a note's outline, from the editor's own headings"
```

---

### Task 2: Where the reader is, and jumping there

**Files:**
- Modify: `Sources/ExtensionSDK/ExtensionSDK.swift`, `Sources/AppCore/AppState.swift`, `Sources/AppCore/Host.swift`
- Test: `Sources/Checks/OutlineChecks.swift`, `Sources/Checks/main.swift`

**Interfaces:**
- Produces: SDK `EditorContext.focusOffset: AnyPublisher<Int, Never>`, `WorkspaceActions.reveal(offset: Int)`; `AppState.focusOffset: AnyPublisher<Int, Never>`, `AppState.viewportMoved(top: Int)`, `AppState.reveal(offset: Int)`, `@Published AppState.pendingJumpToTop: Bool`. Task 3 passes `pendingJumpToTop` and `viewportMoved` to the editor.

- [ ] **Step 1: Write the failing test** — append to `OutlineChecks.swift` (add `import AppCore` and `import Combine` at the top):

```swift
/// The outline's current heading follows the caret while editing and the top
/// visible line while reading; a click's jump asks for the line at the top,
/// and only that jump does.
func outlineFocusChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-outline-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    for name in ["A.md", "B.md"] {
        try? "# \(name)\ntext\n## Two\nmore\n".write(to: vault.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let suite = "mk-outline-\(UUID().uuidString)"
    let s = AppState(defaults: UserDefaults(suiteName: suite)!)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    s.openVault(at: vault)
    s.openNote(relativePath: "A.md", newTab: true)

    var seen: [Int] = []
    let token = s.focusOffset.sink { seen.append($0) }
    defer { token.cancel() }

    s.caretMoved(to: 12)
    expectEqual(seen.last, 12, "editing: the caret")
    s.viewportMoved(top: 30)
    expectEqual(seen.last, 12, "editing: scrolling doesn't move it")
    s.toggleReading(s.activeTabID!)
    expectEqual(seen.last, 30, "reading: the top visible line")
    s.caretMoved(to: 5)
    expectEqual(seen.last, 30, "reading: a caret move doesn't move it")
    s.toggleReading(s.activeTabID!)
    expectEqual(seen.last, 5, "editing again: the caret")

    s.openNote(relativePath: "B.md", newTab: true)
    expectEqual(seen.last, 0, "another tab starts at its top")

    s.reveal(offset: 9)
    expectEqual(s.pendingCursorOffset, 9, "reveal jumps the editor")
    expect(s.pendingJumpToTop, "with the line at the top")
    s.pendingCursorOffset = nil                 // the editor applied the jump
    expect(!s.pendingJumpToTop, "the placement goes with the jump")
    s.pendingCursorOffset = 3                   // a search result's jump
    expect(!s.pendingJumpToTop, "other jumps keep their placement")
}
```

Register after `("Outline", outlineChecks),`:

```swift
    ("OutlineFocus", outlineFocusChecks),
```

- [ ] **Step 2: Run to see it fail** — `swift run Checks OutlineFocus` → compile errors (`focusOffset`, `viewportMoved`, `reveal`, `pendingJumpToTop`).

- [ ] **Step 3: SDK** — in `ExtensionSDK.swift`, add to `EditorContext` after `activeNotePath`:

```swift
    /// Where the reader is in the open note (UTF-16 offset): the caret while
    /// editing, the top visible line in reading mode.
    var focusOffset: AnyPublisher<Int, Never> { get }
```

and to `WorkspaceActions` after `openNote(relativePath:)`:

```swift
    /// Move the open note's caret to `offset`, its line scrolled to the top.
    func reveal(offset: Int)
```

- [ ] **Step 4: AppState** — beside `pendingCursorOffset`, replace its declaration with:

```swift
    @Published public var pendingCursorOffset: Int? {
        didSet { if pendingCursorOffset == nil { pendingJumpToTop = false } }
    }
    /// The pending jump puts its line at the top of the editor (an outline
    /// click), not merely in view. Cleared with the jump.
    @Published public var pendingJumpToTop = false
```

Replace `public func caretMoved(to offset: Int) { liveCaret = offset }` with:

```swift
    public func caretMoved(to offset: Int) { liveCaret = offset; sendFocus() }

    /// The start of the editor's top visible line, as it scrolls.
    public func viewportMoved(top offset: Int) { viewportTop = offset; sendFocus() }
    private var viewportTop = 0

    /// Where the reader is (see EditorContext.focusOffset). A subject, not
    /// @Published: it changes on every caret move, and objectWillChange would
    /// redraw the window each time.
    public var focusOffset: AnyPublisher<Int, Never> { focus.removeDuplicates().eraseToAnyPublisher() }
    private let focus = CurrentValueSubject<Int, Never>(0)
    private func sendFocus() { focus.send(isActiveTabReading ? viewportTop : liveCaret) }

    /// Jump the editor to `offset` with its line at the top.
    public func reveal(offset: Int) {
        pendingJumpToTop = true
        pendingCursorOffset = offset
    }
```

In `hydrate(from:)`, after `liveCaret = 0`:

```swift
        viewportTop = 0
        sendFocus()
```

In `toggleReading(_:)`, after `persistPins()`:

```swift
        sendFocus()
```

- [ ] **Step 5: Host** — in `Host.swift`, after `activeNotePath`:

```swift
    public var focusOffset: AnyPublisher<Int, Never> { appState.focusOffset }
```

and after `openNote(relativePath:)`:

```swift
    public func reveal(offset: Int) { appState.reveal(offset: offset) }
```

- [ ] **Step 6: Run and pass** — `swift run Checks OutlineFocus`, then `swift run Checks` → all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/ExtensionSDK/ExtensionSDK.swift Sources/AppCore/AppState.swift Sources/AppCore/Host.swift Sources/Checks/OutlineChecks.swift Sources/Checks/main.swift
git commit -m "feat(sdk): where the reader is, and revealing an offset at the top"
```

---

### Task 3: The editor jumps a line to the top and reports its top line

**Files:**
- Modify: `Sources/EditorEngine/MarkdownEditorView.swift`, `Sources/Checks/EditorInputChecks.swift` (`EditorHarness`)
- Test: `Sources/Checks/OutlineChecks.swift`, `Sources/Checks/main.swift`

**Interfaces:**
- Consumes: the coordinator's `pendingScrollAnchor: (offset: Int, delta: CGFloat)?`, `scrollAnchor()`, `scheduleWidgetUpdate()`, `revealCaretAfterLayout()` (existing).
- Produces: `MarkdownEditorView(..., jumpsToTop: Bool = false, onViewportTopChange: ((Int) -> Void)? = nil)` — appended after the existing last parameter; `EditorHarness.jumpsToTop: Bool`, `EditorHarness.viewportTops: [Int]`.

- [ ] **Step 1: Harness** — in `EditorHarness`, add properties beside `isReading`:

```swift
    var jumpsToTop = false
    /// Top-line offsets the editor reported as it scrolled.
    var viewportTops: [Int] = []
```

and pass, in both `MarkdownEditorView(...)` constructions (init and `rebuild()`), after the existing last argument:

```swift
, jumpsToTop: jumpsToTop, onViewportTopChange: { [weak self] in self?.viewportTops.append($0) }
```

(In `init`, where `self` isn't available yet, use the `box` pattern the init already uses for the text binding: `onViewportTopChange: { box?.viewportTops.append($0) }`, and `jumpsToTop: false`.)

- [ ] **Step 2: Write the failing test** — append to `OutlineChecks.swift`:

```swift
/// An outline click's jump puts the heading's line at the top of the view —
/// even with a table above it whose height changes once laid out — and the
/// editor reports its top line as it scrolls.
func editorOutlineJumpChecks() {
    let rows = (0..<30).map { "| r\($0) | v |" }.joined(separator: "\n")
    let body = (0..<200).map { "## Heading \($0)\ntext under \($0)\n" }.joined()
    let note = "| a | b |\n|---|---|\n" + rows + "\n\n" + body
    guard let h = EditorHarness(note) else { expect(false, "editor found"); return }
    defer { h.close() }
    h.pump(0.4)
    let target = (note as NSString).range(of: "## Heading 120").location

    h.jumpsToTop = true
    h.jump(to: target)
    h.pump(0.3)
    expectEqual(h.topLineOffset, target, "the heading's line is at the top")
    expect(h.viewportTops.last == target, "and the editor reported that top line (\(String(describing: h.viewportTops.last)))")

    h.viewportTops = []
    h.scrollToTop(of: (note as NSString).range(of: "## Heading 40").location)
    h.pump(0.2)
    expectEqual(h.viewportTops.last, (note as NSString).range(of: "## Heading 40").location,
                "scrolling reports the new top line")
}
```

Register after `("OutlineFocus", outlineFocusChecks),`:

```swift
    ("EditorOutlineJump", editorOutlineJumpChecks),
```

- [ ] **Step 3: Run to see it fail** — `swift run Checks EditorOutlineJump` → compile error (`extra arguments 'jumpsToTop', 'onViewportTopChange'`).

- [ ] **Step 4: Implement** — in `MarkdownEditorView`, after `isReading`:

```swift
    /// The `cursorOffset` jump puts its line at the top of the view (an outline
    /// click) instead of just bringing the caret into view.
    public var jumpsToTop: Bool
    /// Called with the start offset of the top visible line as the view scrolls
    /// (live editor only), at most once per runloop turn.
    public var onViewportTopChange: ((Int) -> Void)?
```

Add `jumpsToTop: Bool = false, onViewportTopChange: ((Int) -> Void)? = nil` as the init's last parameters, assigned in the body.

In `updateNSView`'s `cursorOffset` block, replace

```swift
            tv.scrollRangeToVisible(NSRange(location: clamped, length: 0))
            tv.window?.makeFirstResponder(tv)
            context.coordinator.revealCaretAfterLayout()
```

with

```swift
            if jumpsToTop {
                context.coordinator.scrollLineToTop(at: clamped)
            } else {
                tv.scrollRangeToVisible(NSRange(location: clamped, length: 0))
                context.coordinator.revealCaretAfterLayout()
            }
            tv.window?.makeFirstResponder(tv)
```

In the coordinator, next to `scrollAnchor()`:

```swift
        /// Put the line holding `offset` at the top of the view. Through the scroll
        /// anchor the widget pass restores, so it lands right even while the lines
        /// above still have estimated heights.
        func scrollLineToTop(at offset: Int) {
            guard let textView else { return }
            let line = (textView.string as NSString).lineRange(for: NSRange(location: offset, length: 0)).location
            pendingScrollAnchor = (offset: line, delta: 0)
            scheduleWidgetUpdate()
        }
```

Extend `clipViewDidScroll` — keep its link-popup code, and report the top line first:

```swift
        @objc func clipViewDidScroll() {
            reportViewportTop()
            guard let linkContext, linkPopup.isOpen, let window = textView?.window else { return }
            linkPopup.show(linkPopup.model.items, below: linkAnchor(linkContext), in: window)
        }

        private var viewportReportScheduled = false
        /// One report per runloop turn: a scroll gesture sends many bounds changes.
        private func reportViewportTop() {
            guard parent.isLive, parent.onViewportTopChange != nil, !viewportReportScheduled else { return }
            viewportReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewportReportScheduled = false
                if let top = self.scrollAnchor()?.offset { self.parent.onViewportTopChange?(top) }
            }
        }
```

(`scrollAnchor()` is `private` today — make it `fileprivate` or internal if needed; keep `restore` as is.)

- [ ] **Step 5: Run and pass** — `swift run Checks EditorOutlineJump`; also `EditorReveal`, `EditorReadingSwitch`, `EditorReadingTabSwitch` (if present), `EditorScroll`, `EditorBottomTyping`, `KeystrokeWork`. Then `swift run Checks` → all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/EditorEngine/MarkdownEditorView.swift Sources/Checks/EditorInputChecks.swift Sources/Checks/OutlineChecks.swift Sources/Checks/main.swift
git commit -m "feat(editor): a jump can put its line at the top; the editor reports its top line"
```

---

### Task 4: The Outline panel

**Files:**
- Create: `Sources/OutlinePlugin/OutlinePlugin.swift`
- Modify: `Package.swift`, `Sources/HanjiApp/HanjiApp.swift`, `Sources/HanjiApp/ContentView.swift`, `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: `Outline` (Task 1); `EditorContext.focusOffset`, `WorkspaceActions.reveal(offset:)`, `AppState.pendingJumpToTop`, `AppState.viewportMoved(top:)` (Task 2); `MarkdownEditorView(..., jumpsToTop:, onViewportTopChange:)` (Task 3).

- [ ] **Step 1: Package** — in `Package.swift`, after the `BacklinksPlugin` target:

```swift
        .target(name: "OutlinePlugin", dependencies: ["ExtensionSDK", "MarkdownCore"]),
```

and add `"OutlinePlugin"` to the `HanjiApp` and `Checks` dependency lists.

- [ ] **Step 2: The plugin** — create `Sources/OutlinePlugin/OutlinePlugin.swift`:

```swift
import SwiftUI
import Combine
import ExtensionSDK
import MarkdownCore

/// First-party outline panel: the open note's headings; a click jumps to one,
/// and the heading of the section being read is highlighted.
public struct OutlinePlugin: Plugin {
    public static let id = "io.hanji.outline"
    public init() {}

    public func activate(host: PluginHost) {
        // Weak: the sidebar registry lives in PluginManager, which the host
        // retains — a strong capture here would be a retain cycle.
        host.ui.addSidebarView(id: "outline", title: "Outline") { [weak host] in
            guard let host else { return AnyView(EmptyView()) }
            // At most every 0.15s while typing; the first change after a pause
            // (a note switch included) shows at once.
            let notes = host.editor.activeNotePath.combineLatest(host.editor.activeText)
                .throttle(for: .seconds(0.15), scheduler: DispatchQueue.main, latest: true)
                .map { path, text in path == nil ? nil : Outline.headings(in: text) }
                .eraseToAnyPublisher()
            return AnyView(OutlineView(headings: notes, focus: host.editor.focusOffset,
                                       workspace: host.workspace))
        }
    }
}

struct OutlineView: View {
    /// nil: no note open.
    let headings: AnyPublisher<[OutlineHeading]?, Never>
    let focus: AnyPublisher<Int, Never>
    let workspace: WorkspaceActions

    @State private var items: [OutlineHeading]?
    @State private var focusOffset = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let items {
                if items.isEmpty {
                    Text("No headings").font(.caption).foregroundStyle(.secondary)
                } else {
                    let top = items.map(\.level).min() ?? 1
                    let current = Outline.current(in: items, at: focusOffset)
                    ForEach(Array(items.enumerated()), id: \.element.offset) { index, heading in
                        Button { workspace.reveal(offset: heading.offset) } label: {
                            Text(heading.title.isEmpty ? "Untitled" : heading.title)
                                .lineLimit(1)
                                .fontWeight(heading.level == top ? .medium : .regular)
                                .padding(.leading, CGFloat(heading.level - top) * 12)
                                .padding(.vertical, 2).padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(index == current ? Color.accentColor.opacity(0.18) : .clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Open a note to see its outline").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(headings) { items = $0 }
        .onReceive(focus) { focusOffset = $0 }
    }
}
```

- [ ] **Step 3: Register it first** — in `Sources/HanjiApp/HanjiApp.swift` add `import OutlinePlugin` beside `import BacklinksPlugin`, and put `OutlinePlugin()` before `BacklinksPlugin()` in the `plugins` array.

- [ ] **Step 4: Editor wiring** — in `ContentView.paneView`, after `isReading: tab.isReading`:

```swift
                    isReading: tab.isReading,
                    jumpsToTop: isActivePane && appState.pendingJumpToTop,
                    onViewportTopChange: { appState.viewportMoved(top: $0) })
```

- [ ] **Step 5: Build and run every check** — `swift build` (no new warnings), `swift run Checks` → all pass.

- [ ] **Step 6: Docs** — `README.md`: after the "Reading mode" bullet add

```markdown
- **Outline** panel (right sidebar): the note's headings, indented by level;
  click one to jump there (its line at the top), and the section you're
  reading is highlighted.
```

and change the "Not built yet" known-gaps bullet to `- **Not built yet**: export / print.`
`CHANGELOG.md` under `## [Unreleased]` › `### Editor`, add:

```markdown
- Outline panel in the right sidebar: headings indented by level, a click
  jumps there, the current section highlighted (#3).
```

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/OutlinePlugin/OutlinePlugin.swift Sources/HanjiApp/HanjiApp.swift Sources/HanjiApp/ContentView.swift README.md CHANGELOG.md
git commit -m "feat: Outline panel — headings, click to jump, current section (#3)"
```

(The live-app check is the controller's, after this task.)
