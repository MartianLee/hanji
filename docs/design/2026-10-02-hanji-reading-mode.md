# Reading Mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a per-tab reading mode (⌘E) that shows the note with no Markdown marker on any line and takes no typing — checkbox toggles excepted (issue #1).

**Architecture:** the tab carries `isReading`; the editor runs its existing Live Preview pipeline with "no line holds the caret" for every decision about revealing source, and sets `NSTextView.isEditable = false`. Change tracking (which paragraphs to restyle) keeps following the real caret — restyling a paragraph that renders the same is harmless, and it keeps the incremental restyle untouched.

**Tech Stack:** Swift 5.10 / SPM, SwiftUI + AppKit + TextKit 2, the zero-dependency `Checks` runner (`swift run Checks <Group>`).

**Spec:** `docs/design/2026-10-02-hanji-reading-mode-design.md`

## Global Constraints

- Every reveal decision reads `nil` in reading mode; nothing else in the restyle/widget pipeline changes.
- The TextKit 2 invariants hold: the full-document `ensureLayout` in `layOutNote` stays; no restyle while `hasMarkedText()`.
- New tabs open in editing. The mode is stored for pinned tabs only, under `io.hanji.reading.<vault path>`.
- `swift run Checks` (all groups) passes at the end of every task.
- Comments match the surrounding code: full sentences explaining *why*, no change-log comments.

## Files

| File | Change |
|---|---|
| `Sources/MarkdownCore/Decorations.swift` | `Decorator.decorations(spans:selection:)` takes `Range<Int>?`; nil hides every marker |
| `Sources/AppCore/OpenTab.swift` | `isReading`, included in `==` |
| `Sources/AppCore/AppState.swift` | `toggleReading`, `isActiveTabReading`, persistence beside the pins, mode kept when a move merges tabs |
| `Sources/EditorEngine/MarkdownEditorView.swift` | `isReading` parameter, `revealSelection`, `setReading`, scroll anchor, checkbox toggle while read-only |
| `Sources/HanjiApp/HanjiApp.swift` | View ▸ Reading Mode (⌘E), `tab.toggleReading` command |
| `Sources/HanjiApp/ContentView.swift` | passes `isReading`; inline title read-only while reading |
| `Sources/HanjiApp/TabBarView.swift` | `book` icon on reading tabs |
| `Sources/Checks/ReadingModeChecks.swift` | new: all reading-mode checks |
| `Sources/Checks/EditorInputChecks.swift` | `EditorHarness` gains `isReading`, `scrollToTop(of:)`, `topLineOffset` |
| `Sources/Checks/DecorationChecks.swift`, `Sources/Checks/main.swift` | nil-selection assertion; new groups |
| `README.md`, `CHANGELOG.md` | feature line, known gaps, Unreleased entry |

---

### Task 1: Decorator accepts "no caret"

**Files:**
- Modify: `Sources/MarkdownCore/Decorations.swift` (`Decorator.decorations`)
- Test: `Sources/Checks/DecorationChecks.swift`

**Interfaces:**
- Produces: `Decorator.decorations(spans: [MarkSpan], selection: Range<Int>?) -> DecorationSet` — nil hides every span's markers. Existing callers passing a `Range<Int>` compile unchanged.

- [ ] **Step 1: Write the failing test** — append to `decorationChecks()`:

```swift
    // No caret at all (reading mode) -> every line hides its markers
    let none = Decorator.decorations(spans: spans, selection: nil)
    expectEqual(none.hidden, [0..<2, 3..<5], "no selection hides the markers on every line")
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift run Checks Decoration`
Expected: compile error — `'nil' is not compatible with expected argument type 'Range<Int>'`.

- [ ] **Step 3: Implement** — in `Decorations.swift` replace the signature and the hide test:

```swift
    /// Pure: spans + caret/selection (UTF-16 offsets) -> style runs + marker ranges to hide.
    /// A span's markers are hidden unless the selection intersects the span's line;
    /// with no selection (reading mode) every line hides them.
    public static func decorations(spans: [MarkSpan], selection: Range<Int>?) -> DecorationSet {
```

```swift
            if !(selection.map { intersects(span.line, $0) } ?? false) {
                hidden.append(contentsOf: span.markers)
            }
```

- [ ] **Step 4: Run and pass**

Run: `swift run Checks Decoration` → `✅ All checks passed`. Then `swift build` (every other caller still compiles).

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownCore/Decorations.swift Sources/Checks/DecorationChecks.swift
git commit -m "feat(core): decorations with no caret hide every line's markers"
```

---

### Task 2: A tab's reading mode, and remembering it

**Files:**
- Modify: `Sources/AppCore/OpenTab.swift`, `Sources/AppCore/AppState.swift`
- Create: `Sources/Checks/ReadingModeChecks.swift`
- Modify: `Sources/Checks/main.swift`

**Interfaces:**
- Produces: `OpenTab.isReading: Bool` (default false; `init(sharing:)` leaves it false); `AppState.toggleReading(_ tabID: UUID)`; `AppState.isActiveTabReading: Bool`. Task 6 binds the menu to these.

- [ ] **Step 1: Write the failing test** — create `Sources/Checks/ReadingModeChecks.swift`:

```swift
import AppKit
import SwiftUI
import AppCore
import EditorEngine
import MKSearchKit

/// Reading mode belongs to the tab: it survives navigating in the tab and moving
/// it to the other pane, new tabs start in editing, and a pinned tab brings it
/// back when the vault reopens.
func readingTabChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-read-\(UUID().uuidString)")
    let other = fm.temporaryDirectory.appendingPathComponent("mk-read-other-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    try? fm.createDirectory(at: other, withIntermediateDirectories: true)
    defer {
        for v in [vault, other] {
            try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: v)); try? fm.removeItem(at: v)
        }
    }
    for name in ["A.md", "B.md", "C.md"] {
        try? name.write(to: vault.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let suite = "mk-read-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let s = AppState(defaults: defaults)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    s.openVault(at: vault)
    func tab(_ name: String) -> OpenTab? { s.panes.flatMap(\.tabs).first { $0.file.name == name } }
    func file(_ name: String) -> MarkdownFile { s.files.first { $0.name == name }! }

    s.openNote(relativePath: "A.md", newTab: true)
    s.openNote(relativePath: "C.md", newTab: true)
    s.toggleReading(tab("A.md")!.id)
    expect(tab("A.md")?.isReading == true, "a tab can be put in reading mode")
    expect(tab("C.md")?.isReading == false, "the other tab stays in editing")
    expect(!s.isActiveTabReading, "the active tab (C) is editing")
    s.switchTab(tab("A.md")!.id)
    expect(s.isActiveTabReading, "the active tab (A) is reading")

    s.open(file("B.md"))                       // a link followed in the same tab
    expect(tab("B.md")?.isReading == true, "following a link keeps the tab reading")
    s.goBack()
    expect(tab("A.md")?.isReading == true, "and so does going back")

    s.openNote(relativePath: "B.md", newTab: true)
    expect(tab("B.md")?.isReading == false, "a new tab opens in editing")

    s.moveTabToSide(tab("A.md")!.id, .right)
    expect(s.panes.count == 2 && s.panes[1].tabs.first?.isReading == true, "moving a tab to the other pane keeps it reading")

    // Remembered for pinned tabs only.
    s.togglePin(tab("A.md")!.id)
    s.togglePin(tab("C.md")!.id)
    s.toggleReading(tab("B.md")!.id)           // reading, but not pinned
    let key = "io.hanji.reading.\(vault.standardizedFileURL.path)"
    expectEqual(defaults.stringArray(forKey: key), ["A.md"], "only pinned reading tabs are stored")
    s.openVault(at: other); s.openVault(at: vault)
    expect(tab("A.md")?.isReading == true, "a pinned reading tab comes back reading")
    expect(tab("C.md")?.isReading == false, "a pinned editing tab comes back editing")

    _ = try? s.rename(vault.appendingPathComponent("A.md"), to: "Renamed")
    s.openVault(at: other); s.openVault(at: vault)
    expect(tab("Renamed.md")?.isReading == true, "a rename carries the mode along")
}
```

Register it in `Sources/Checks/main.swift`, after `("Pin", pinChecks),`:

```swift
    ("ReadingTabs", readingTabChecks),
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift run Checks ReadingTabs`
Expected: compile errors — `value of type 'OpenTab' has no member 'isReading'`, `no member 'toggleReading'`.

- [ ] **Step 3: Implement `OpenTab`** — in `OpenTab.swift`, under `isPinned`:

```swift
    /// Reading mode: the note shown fully rendered, not editable (checkbox
    /// toggles aside). Per tab — another tab on the same note keeps its own.
    public var isReading = false
```

and include it in `==` (SwiftUI compares tabs with it; left out, flipping the mode wouldn't redraw):

```swift
    public static func == (a: OpenTab, b: OpenTab) -> Bool {
        a.id == b.id && a.buffer === b.buffer && a.isPinned == b.isPinned && a.isReading == b.isReading
    }
```

- [ ] **Step 4: Implement `AppState`**

Beside `pinsKey`:

```swift
    private static func readingKey(_ root: URL) -> String { "io.hanji.reading.\(root.standardizedFileURL.path)" }
```

Replace `persistPins()` with:

```swift
    /// The vault's pinned notes, vault-relative, in tab order (left pane first),
    /// and which of them are in reading mode.
    private func persistPins() {
        guard let root = vaultRoot else { return }
        defaults.set(pinnedPaths(root) { _ in true }, forKey: Self.pinsKey(root))
        defaults.set(pinnedPaths(root) { $0.isReading }, forKey: Self.readingKey(root))
    }

    private func pinnedPaths(_ root: URL, where include: (OpenTab) -> Bool) -> [String] {
        let prefix = root.standardizedFileURL.path + "/"
        var seen = Set<String>()
        return panes.flatMap(\.tabs).filter { $0.isPinned && include($0) }.compactMap { tab -> String? in
            let path = tab.file.url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return nil }
            let rel = String(path.dropFirst(prefix.count))
            return seen.insert(rel).inserted ? rel : nil
        }
    }
```

In `restorePins()`, read the set before the loop and apply it beside the pin (before the closing `persistPins()`, which would otherwise store an empty list):

```swift
        let reading = Set(defaults.stringArray(forKey: Self.readingKey(root)) ?? [])
        for rel in paths {
            guard let url = urlInsideVault(rel), FileManager.default.fileExists(atPath: url.path) else { continue }
            openNote(relativePath: rel, newTab: true)
            if let idx = pane.tabs.firstIndex(where: { $0.file.url.standardizedFileURL == url.standardizedFileURL }) {
                pane.tabs[idx].isPinned = true
                pane.tabs[idx].isReading = reading.contains(rel)
            }
        }
```

After `togglePin`, under `// MARK: - Pinned tabs`:

```swift
    // MARK: - Reading mode

    /// Reading mode on or off for a tab (in any pane); remembered for pinned tabs.
    public func toggleReading(_ tabID: UUID) {
        guard let pane = panes.first(where: { $0.tabs.contains { $0.id == tabID } }),
              let idx = pane.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        objectWillChange.send()
        pane.tabs[idx].isReading.toggle()
        persistPins()
    }

    /// Whether the active tab is in reading mode (View ▸ Reading Mode's check).
    public var isActiveTabReading: Bool {
        activeTabIndex.map { activePane!.tabs[$0].isReading } ?? false
    }
```

In `moveTabToSide`, where the moved tab merges into a tab already showing its buffer, the moved tab's mode wins — it is the one the user just moved and is looking at:

```swift
                if snapshot.isPinned { target.tabs[existing].isPinned = true }
                target.tabs[existing].isReading = snapshot.isReading
```

- [ ] **Step 5: Run and pass**

Run: `swift run Checks ReadingTabs` → passes. Then `swift run Checks` → all pass (Pin and Tabs included).

- [ ] **Step 6: Commit**

```bash
git add Sources/AppCore/OpenTab.swift Sources/AppCore/AppState.swift Sources/Checks/ReadingModeChecks.swift Sources/Checks/main.swift
git commit -m "feat(tabs): a tab's reading mode, kept through navigation and remembered with pins"
```

---

### Task 3: The editor renders every line and takes no typing

**Files:**
- Modify: `Sources/EditorEngine/MarkdownEditorView.swift`
- Modify: `Sources/Checks/EditorInputChecks.swift` (`EditorHarness`)
- Test: `Sources/Checks/ReadingModeChecks.swift`, `Sources/Checks/main.swift`

**Interfaces:**
- Consumes: `Decorator.decorations(spans:selection: Range<Int>?)` (Task 1).
- Produces: `MarkdownEditorView(..., isReading: Bool = false)` as the last init parameter; `Coordinator.appliedReading: Bool`; `Coordinator.setReading(_ reading: Bool)` (Task 5 extends it); `EditorHarness.isReading: Bool`.

- [ ] **Step 1: Give the harness a mode** — in `EditorHarness` (`EditorInputChecks.swift`):

Add a property beside `linkTargets`:

```swift
    var isReading = false
```

add `isReading: Bool = false` as the init's last parameter, set `self.isReading = isReading` with the other properties, and pass it to both `MarkdownEditorView(...)` calls — in `init`:

```swift
        let host = NSHostingView(rootView: MarkdownEditorView(text: binding, cursorOffset: offset,
                                                              lineHeight: lineHeight, maxLineWidth: maxLineWidth,
                                                              linkTargets: { linkTargets }, isReading: isReading))
```

and in `rebuild()`:

```swift
                                               linkTargets: { self.linkTargets }, isReading: isReading)
```

- [ ] **Step 2: Write the failing test** — append to `ReadingModeChecks.swift`:

```swift
/// Reading mode draws the caret's line like every other line — markers hidden,
/// widgets drawn — and the text view takes no typing. Back in editing, the
/// caret's line shows its source again.
func editorReadingChecks() {
    let note = "Intro\n\nSome **bold** text\n\n---\n\nAfter"
    let bold = (note as NSString).range(of: "**bold**").location
    let rule = (note as NSString).range(of: "---").location
    guard let h = EditorHarness(note) else { expect(false, "editor found"); return }
    defer { h.close() }
    let tv = h.textView
    func markerSize() -> CGFloat {
        (tv.textStorage?.attribute(.font, at: bold, effectiveRange: nil) as? NSFont)?.pointSize ?? -1
    }
    func overlays() -> Int { tv.subviews.filter { $0 is NSHostingView<AnyView> }.count }

    h.caret(at: bold + 3); h.pump(0.3)
    expect(markerSize() > 5, "editing: the caret's line shows its ** (\(markerSize())pt)")

    h.isReading = true; h.rebuild()
    expect(markerSize() < 1, "reading: the caret's line hides them too (\(markerSize())pt)")
    expect(!tv.isEditable, "reading: the text view isn't editable")
    h.caret(at: rule); h.pump(0.3)
    expectEqual(overlays(), 1, "reading: the rule under the caret is still drawn")
    h.type("x\n"); h.key("\t", 48); h.pump()
    expectEqual(h.text, note, "reading: keys don't change the note")

    h.isReading = false; h.rebuild()
    h.caret(at: rule); h.pump(0.3)
    expectEqual(overlays(), 0, "editing: the rule under the caret shows its source")
    expect(tv.isEditable, "editing: typing works again")
}
```

Register after `("ReadingTabs", readingTabChecks),`:

```swift
    ("EditorReading", editorReadingChecks),
```

- [ ] **Step 3: Run it to see it fail**

Run: `swift run Checks EditorReading`
Expected: compile error — `extra argument 'isReading' in call`.

- [ ] **Step 4: The view's parameter** — in `MarkdownEditorView`, after `isLive`:

```swift
    /// Reading mode: no line shows its Markdown source, and only checkbox
    /// toggles change the note.
    public var isReading: Bool
```

Add `isReading: Bool = false` after `onCaretMove` in `init(...)`, and `self.isReading = isReading` in its body.

In `makeNSView`, after `textView.isIncrementalSearchingEnabled = true`:

```swift
        textView.isEditable = !isReading
```

and just before the closing `context.coordinator.refresh()`:

```swift
        context.coordinator.appliedReading = isReading
```

In `updateNSView`, right after `context.coordinator.sync(with: self)`:

```swift
        if context.coordinator.appliedReading != isReading { context.coordinator.setReading(isReading) }
```

- [ ] **Step 5: The coordinator** — add beside `needsFullRestyle`:

```swift
        /// The mode the text view was last set up for (see `setReading`).
        var appliedReading = false
        /// The selection whose lines show their source: the text view's, or nil in
        /// reading mode, where no line does. Change tracking (`dirtyParagraphs`,
        /// `isStyledAsShown`) keeps following the real caret.
        private var revealSelection: NSRange? { parent.isReading ? nil : textView?.selectedRange() }

        /// Reading mode on or off: every line rendered, and the text view read-only.
        func setReading(_ reading: Bool) {
            guard let textView else { return }
            appliedReading = reading
            textView.isEditable = !reading
            closeLinkCompletion()
            needsFullRestyle = true
            refresh()
        }
```

In `restyle(also:)` replace

```swift
            let sel = textView.selectedRange()
            let selection = sel.location..<(sel.location + sel.length)
            let deco = Decorator.decorations(spans: spans, selection: selection)
```

with

```swift
            let sel = textView.selectedRange()
            let reveal = revealSelection
            let selection = reveal.map { $0.location..<NSMaxRange($0) }
            let deco = Decorator.decorations(spans: spans, selection: selection)
```

and in the same function pass `reveal` where the reveal is decided:

```swift
                restyle(scope, of: storage, text: text, deco: deco, regions: regions,
                        spans: spans, sel: reveal, caret: selection)
```

```swift
            markerLines = markerPlacements(spans: spans, sel: reveal, text: text)
```

(`caretParagraph` stays `text.paragraphRange(for: sel)`.)

Make the reveal parameters optional:

```swift
        private func restyle(_ scope: NSRange, of storage: NSTextStorage, text: NSString, deco: DecorationSet,
                             regions: [CodeBlockRegion], spans: [MarkSpan], sel: NSRange?, caret: Range<Int>?) {
```

```swift
        private func reapplyReservations(in storage: NSTextStorage, text: NSString, caret: Range<Int>?, offset: Int) {
```

In `hideMarkers`, change the parameter to `sel: NSRange?` and:

```swift
            let caretLine = sel.map { text.paragraphRange(for: $0) }
```

```swift
                if let caretLine, Self.onCaret(span.line, caretLine) { continue }
```

(replacing `guard !Self.onCaret(span.line, caretLine) else { continue }`). In `markerPlacements`, `sel: NSRange?` and:

```swift
            let caretLine = sel.map { text.paragraphRange(for: $0) }
            var marks: [Int: MarkerPlacement] = [:]
            for span in spans where !(caretLine.map { Self.onCaret(span.line, $0) } ?? false) {
```

Replace the coordinator's `intersects`:

```swift
        /// Inclusive overlap; no caret (reading mode) overlaps nothing.
        private func intersects(_ a: Range<Int>, _ b: Range<Int>?) -> Bool {
            guard let b else { return false }
            return a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
        }
```

In `updateWidgets` replace

```swift
            let sel = textView.selectedRange()
            let caret = sel.location..<(sel.location + sel.length)
```

with

```swift
            let caret = revealSelection.map { $0.location..<NSMaxRange($0) }
```

and change `caret: Range<Int>` to `caret: Range<Int>?` in `imageWidgets`, `hrWidgets` and `tableWidgets` (their bodies already go through `intersects`).

In `handleClick`, a widget click doesn't reveal its source while reading:

```swift
            if !parent.isReading,
               let region = widgetRegions.first(where: { $0.lowerBound <= index && index < $0.upperBound }),
               let textView {
```

In `textViewDidChangeSelection`, after the `onCaretMove` line:

```swift
            // Reading mode reveals no line, so a caret move changes nothing on screen.
            if parent.isReading { return }
```

In `updateLinkCompletion`, so placing the caret after a `[[` while reading doesn't open the suggestion list, change the start of its opening `guard` from `guard let textView, parent.isLive,` to:

```swift
            guard let textView, parent.isLive, !parent.isReading,
```

- [ ] **Step 6: Run and pass**

Run: `swift run Checks EditorReading` → passes.
If "keys don't change the note" fails, a `ClickableTextView` override (`insertNewline`, `insertTab`) wrote through `insertText` despite `isEditable == false`: add `guard isEditable else { return }` as the first line of each override that inserts text, and run again.

Then `swift run Checks` → all pass (IncrementalRestyle, KeystrokeWork, EditorTable and EditorScroll guard the paths changed here).

- [ ] **Step 7: Commit**

```bash
git add Sources/EditorEngine/MarkdownEditorView.swift Sources/Checks/EditorInputChecks.swift Sources/Checks/ReadingModeChecks.swift Sources/Checks/main.swift
git commit -m "feat(editor): reading mode renders every line and takes no typing"
```

---

### Task 4: Checkboxes still toggle, and ⌘Z takes it back

**Files:**
- Modify: `Sources/EditorEngine/MarkdownEditorView.swift` (`toggleCheckbox`, `Coordinator.init`, `undoRedoDidChange`)
- Test: `Sources/Checks/ReadingModeChecks.swift`, `Sources/Checks/main.swift`

**Interfaces:**
- Consumes: `MarkdownEditorView(text:isReading:)` (Task 3).

- [ ] **Step 1: Write the failing test** — append:

```swift
/// In reading mode a checkbox is the one thing a click changes; ⌘Z takes it
/// back, and the text view is read-only again after both.
func editorReadingCheckboxChecks() {
    var text = "- [ ] task"
    let view = MarkdownEditorView(text: Binding(get: { text }, set: { text = $0 }), isReading: true)
    let coordinator = view.makeCoordinator()
    let textView = NSTextView()
    textView.allowsUndo = true
    textView.isEditable = false            // as makeNSView sets it up for reading
    textView.delegate = coordinator
    textView.string = text
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = textView
    coordinator.textView = textView
    coordinator.sync(with: view)

    expect(coordinator.handleClick(at: 2), "reading: a checkbox click is handled")
    expectEqual(text, "- [x] task", "and saved to the note")
    expect(!textView.isEditable, "read-only again after the toggle")
    expect(textView.undoManager?.canUndo == true, "the toggle registered an undo")
    textView.undoManager?.undo()
    expectEqual(textView.string, "- [ ] task", "⌘Z takes it back while reading")
    expectEqual(text, "- [ ] task", "and the note follows")
    expect(!textView.isEditable, "read-only again after the undo")
}
```

Register after `("EditorReading", editorReadingChecks),`:

```swift
    ("EditorReadingCheckbox", editorReadingCheckboxChecks),
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift run Checks EditorReadingCheckbox`
Expected: FAIL — "reading: a checkbox click is handled" (`shouldChangeText` refuses a non-editable view).

- [ ] **Step 3: Implement the toggle** — in `toggleCheckbox`, around the edit:

```swift
            let range = NSRange(location: t.offset, length: 1)
            // Reading mode: the view is read-only, and a checkbox is the one edit it
            // allows. Editable for just this change, so it is an ordinary edit with
            // an undo entry.
            let wasEditable = textView.isEditable
            textView.isEditable = true
            defer { textView.isEditable = wasEditable }
            guard textView.shouldChangeText(in: range, replacementString: t.replacement) else { return false }
```

- [ ] **Step 4: Run**

Run: `swift run Checks EditorReadingCheckbox`.
If every assertion passes, go to Step 6.
If "⌘Z takes it back while reading" fails (the undo is refused on a read-only view), do Step 5.

- [ ] **Step 5 (only if Step 4's undo failed): editable for the undo too** — in `Coordinator.init`, beside the did-undo observers:

```swift
            for name in [Notification.Name.NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoRedoWillChange(_:)),
                                                       name: name, object: nil)
            }
```

and next to `undoRedoDidChange`:

```swift
        /// A checkbox toggled in reading mode is undone on a read-only view; let the
        /// undo through, and `undoRedoDidChange` makes it read-only again.
        @objc private func undoRedoWillChange(_ notification: Notification) {
            guard let textView, parent.isReading,
                  let manager = notification.object as? UndoManager, manager === textView.undoManager else { return }
            textView.isEditable = true
        }
```

with, as the first line of `undoRedoDidChange` (before its `guard`):

```swift
            if let textView, parent.isReading { textView.isEditable = false }
```

Run `swift run Checks EditorReadingCheckbox` → passes.

- [ ] **Step 6: Full run** — `swift run Checks` → all pass (EditorCheckboxEdit, EditorSnapshotClick unchanged).

- [ ] **Step 7: Commit**

```bash
git add Sources/EditorEngine/MarkdownEditorView.swift Sources/Checks/ReadingModeChecks.swift Sources/Checks/main.swift
git commit -m "feat(editor): checkboxes toggle in reading mode, and undo"
```

---

### Task 5: Switching keeps the composition and the view

**Files:**
- Modify: `Sources/EditorEngine/MarkdownEditorView.swift` (`setReading`, `updateWidgets`)
- Modify: `Sources/Checks/EditorInputChecks.swift` (`EditorHarness` helpers)
- Test: `Sources/Checks/ReadingModeChecks.swift`, `Sources/Checks/main.swift`

**Interfaces:**
- Consumes: `Coordinator.setReading` (Task 3), `EditorHarness.isReading` (Task 3).
- Produces: `EditorHarness.scrollToTop(of: Int)`, `EditorHarness.topLineOffset: Int?`.

- [ ] **Step 1: Harness helpers** — in `EditorHarness`, after `caretInView`:

```swift
    /// Scroll so the line holding `offset` is at the top of the view.
    func scrollToTop(of offset: Int) {
        guard let tlm = textView.textLayoutManager, let tcs = tlm.textContentManager,
              let loc = tcs.location(tcs.documentRange.location, offsetBy: offset),
              let frag = tlm.textLayoutFragment(for: loc) else { return }
        textView.scroll(NSPoint(x: 0, y: frag.layoutFragmentFrame.minY + textView.textContainerOrigin.y))
        pump()
    }

    /// Where the line at the top of the view starts.
    var topLineOffset: Int? {
        guard let tlm = textView.textLayoutManager, let tcs = tlm.textContentManager else { return nil }
        let y = textView.visibleRect.minY - textView.textContainerOrigin.y
        guard let frag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y) + 1)) else { return nil }
        return tcs.offset(from: tcs.documentRange.location, to: frag.rangeInElement.location)
    }
```

- [ ] **Step 2: Write the failing test** — append:

```swift
/// Switching mid-composition commits the composed text first. Switching keeps
/// the line at the top of the view there, although the lines above it change
/// height (a table under the caret is source rows in editing, a grid in reading).
func editorReadingSwitchChecks() {
    guard let h = EditorHarness("first line\nsecond line") else { expect(false, "editor found"); return }
    h.caret(at: 6)
    h.textView.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    h.pump(0.05)
    h.isReading = true; h.rebuild()
    expect(!h.textView.hasMarkedText(), "switching commits the composition")
    expectEqual(h.text, "first 한line\nsecond line", "and the note holds the committed text")
    h.close()

    let rows = (0..<30).map { "| r\($0) | v |" }.joined(separator: "\n")
    let body = (0..<300).map { "Line \($0) with **bold**" }.joined(separator: "\n")
    let note = "| a | b |\n|---|---|\n" + rows + "\n\n" + body
    guard let s = EditorHarness(note, cursorOffset: 3) else { expect(false, "editor found"); return }
    defer { s.close() }
    s.pump(0.4)
    s.scrollToTop(of: (note as NSString).range(of: "Line 150 ").location)
    let before = s.topLineOffset
    expect(before != nil, "a line is at the top")
    s.isReading = true; s.rebuild()
    expectEqual(s.topLineOffset, before, "reading: the same line stays at the top")
    s.isReading = false; s.rebuild()
    expectEqual(s.topLineOffset, before, "editing again: still the same line")
}
```

Register after `("EditorReadingCheckbox", editorReadingCheckboxChecks),`:

```swift
    ("EditorReadingSwitch", editorReadingSwitchChecks),
```

- [ ] **Step 3: Run it to see it fail**

Run: `swift run Checks EditorReadingSwitch`
Expected: FAIL — "switching commits the composition", and "the same line stays at the top" (the table collapsing into a grid pulls the text up).

- [ ] **Step 4: Implement** — in the coordinator, beside `appliedReading`:

```swift
        /// The line at the top of the view, and how far past its top the view is
        /// scrolled, taken before a mode switch restyles the note; the next widget
        /// pass puts it back once the lines above have their new heights.
        private var pendingScrollAnchor: (offset: Int, delta: CGFloat)?

        private func scrollAnchor() -> (offset: Int, delta: CGFloat)? {
            guard let tv = textView, let tlm = tv.textLayoutManager, let tcs = tlm.textContentManager else { return nil }
            let y = tv.visibleRect.minY - tv.textContainerOrigin.y
            guard let frag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y) + 1)) else { return nil }
            return (tcs.offset(from: tcs.documentRange.location, to: frag.rangeInElement.location),
                    y - frag.layoutFragmentFrame.minY)
        }

        private func restore(_ anchor: (offset: Int, delta: CGFloat), _ tlm: NSTextLayoutManager, _ tcs: NSTextContentStorage) {
            guard let tv = textView, let loc = tcs.location(tcs.documentRange.location, offsetBy: anchor.offset),
                  let frag = tlm.textLayoutFragment(for: loc) else { return }
            let delta = min(anchor.delta, frag.layoutFragmentFrame.height)
            tv.scroll(NSPoint(x: 0, y: frag.layoutFragmentFrame.minY + delta + tv.textContainerOrigin.y))
        }
```

`setReading` becomes:

```swift
        /// Reading mode on or off: every line rendered, and the text view read-only.
        /// A composition in progress is committed first — the full restyle below
        /// must never run over marked text — and the top line stays where it is.
        func setReading(_ reading: Bool) {
            guard let textView else { return }
            appliedReading = reading
            if textView.hasMarkedText() {
                textView.unmarkText()
                // Out of the SwiftUI update this runs in.
                let committed = textView.string
                DispatchQueue.main.async { [weak self] in
                    if let self, self.parent.text != committed { self.parent.text = committed }
                }
            }
            pendingScrollAnchor = scrollAnchor()
            textView.isEditable = !reading
            closeLinkCompletion()
            needsFullRestyle = true
            refresh()
        }
```

In `updateWidgets`, replace the caret-reveal `if` after `lastWidgetPassSelection = textView.selectedRange()` with:

```swift
            if let anchor = pendingScrollAnchor {
                pendingScrollAnchor = nil
                revealCaret = false
                restore(anchor, tlm, tcs)
            } else if revealCaret || (moved && textView.window?.firstResponder === textView && !caretVisible(tlm, tcs)) {
                revealCaret = false
                textView.scrollRangeToVisible(textView.selectedRange())
            }
```

- [ ] **Step 5: Run and pass**

Run: `swift run Checks EditorReadingSwitch` → passes. Then `swift run Checks IMEComposition` and `swift run Checks` → all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/EditorEngine/MarkdownEditorView.swift Sources/Checks/EditorInputChecks.swift Sources/Checks/ReadingModeChecks.swift Sources/Checks/main.swift
git commit -m "feat(editor): switching to reading commits a composition and holds the view"
```

---

### Task 6: ⌘E, the palette, the tab icon, the title — and the docs

**Files:**
- Modify: `Sources/HanjiApp/HanjiApp.swift`, `Sources/HanjiApp/ContentView.swift`, `Sources/HanjiApp/TabBarView.swift`
- Modify: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: `AppState.toggleReading(_:)`, `AppState.isActiveTabReading` (Task 2); `MarkdownEditorView(..., isReading:)` (Task 3).

- [ ] **Step 1: The editor gets the tab's mode** — in `ContentView.paneView`, add the argument after `onCaretMove:`:

```swift
                    onCaretMove: { appState.caretMoved(to: $0) },
                    isReading: tab.isReading)
```

- [ ] **Step 2: The title is read-only while reading** — in `paneView`, pass the mode:

```swift
                InlineTitleView(fileURL: fileURL, maxLineWidth: readableWidth,
                                font: EditorFonts.boldText(appState.textFont, size: 28),
                                isReadOnly: tab.isReading, rename: { newName in
```

In `InlineTitleView` add `let isReadOnly: Bool` after `font`, and make `body` show plain text while reading (same font and padding, so the page doesn't shift):

```swift
    var body: some View {
        Group {
            if isReadOnly {
                Text(base).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Untitled", text: $title)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .focused($focused)
                    .onAppear { title = base }
                    .onChange(of: fileURL) { _, _ in title = base }     // switched notes → resync
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                    // Enter drops into the editor body. Space must NOT: titles have spaces
                    // in them, and stealing the first one made multi-word titles unwritable.
                    .onKeyPress(.return) { commit(); enterBody(); return .handled }
            }
        }
        .font(Font(font as CTFont))
        .frame(maxWidth: maxLineWidth ?? .infinity, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .background(Color(nsColor: .textBackgroundColor))   // match the editor body
    }
```

- [ ] **Step 3: View ▸ Reading Mode (⌘E)** — in `HanjiApp.swift`, inside `CommandGroup(after: .sidebar) {`, first:

```swift
                Toggle("Reading Mode", isOn: Binding(
                    get: { appState.isActiveTabReading },
                    set: { _ in if let id = appState.activeTabID { appState.toggleReading(id) } }))
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(appState.activeTabID == nil)
                Divider()
```

- [ ] **Step 4: The palette command** — after the `tab.togglePin` registration:

```swift
                    h.commands.register(Command(id: "tab.toggleReading", title: "Toggle reading mode",
                                                isAvailable: { [weak appState] in appState?.activeTabID != nil }) { [weak appState] in
                        if let id = appState?.activeTabID { appState?.toggleReading(id) }
                    })
```

- [ ] **Step 5: The tab icon** — in `TabBarView.tabItem`, before the title `Text`:

```swift
            if tab.isReading {
                Image(systemName: "book").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Reading mode (⌘E)")
            }
```

- [ ] **Step 6: Build and run every check**

Run: `swift build` → succeeds. `swift run Checks` → all pass.

- [ ] **Step 7: Docs** — `README.md`, in the editor feature list after the "Editable inline file title" bullet:

```markdown
- **Reading mode (⌘E)** per tab: the note fully rendered, the caret's line
  included, and not editable — checkboxes still toggle. Kept through links
  and Back/Forward in the tab, and remembered for pinned tabs.
```

and in "Status & known gaps" change the first bullet to:

```markdown
- **Not built yet**: export / print, and an outline / table-of-contents panel.
```

`CHANGELOG.md`, under `## [Unreleased]`:

```markdown
### Editor
- Reading mode (⌘E, View ▸ Reading Mode, or the command palette): a tab shows
  its note fully rendered and takes no typing; checkboxes still toggle (#1).
```

- [ ] **Step 8: Check it in the running app** — `./Scripts/bundle-app.sh && open Hanji.app`, note the PID (`pgrep -n -x Hanji`), and on a scratch vault:

1. ⌘E on a note with bold text, a list, a task, a table, a rule and a mermaid block: no `**`, `- [ ]` or `|` anywhere, the caret's line included; the tab shows the book icon; View ▸ Reading Mode is checked.
2. Typing and ⌘V do nothing; ⌘C copies the selected Markdown; ⌘F finds, with no Replace row.
3. Click a checkbox (a real mouse click — synthetic clicks land at offset 0): it toggles; ⌘Z untoggles.
4. Click a `[[link]]`: the note opens in the same tab, still reading; ⌥⌘← comes back, still reading.
5. Split right (⌘\) and move the reading tab across: still reading. The inline title can't be edited.
6. Pin the reading tab, quit, relaunch: it comes back reading.
7. ⌘E again: back to editing, the scroll position unchanged.

Quit the app by its PID (`kill <pid>`) and confirm `pgrep -x Hanji` prints nothing.

- [ ] **Step 9: Commit**

```bash
git add Sources/HanjiApp/HanjiApp.swift Sources/HanjiApp/ContentView.swift Sources/HanjiApp/TabBarView.swift README.md CHANGELOG.md
git commit -m "feat: reading mode — ⌘E, View menu, palette command, tab icon (#1)"
```

---

### Task 7: Prove the checks guard every reveal site

**Files:** none committed (temporary edits only).

- [ ] **Step 1: Mutate each site in turn**, run `swift run Checks EditorReading`, confirm it goes red, and revert (`git checkout Sources/EditorEngine/MarkdownEditorView.swift`):

| Mutation | Assertion that must fail |
|---|---|
| `restyle(also:)`: `let reveal = textView.selectedRange() as NSRange?` | "reading: the caret's line hides them too" |
| `updateWidgets`: `let caret = Optional(textView.selectedRange()).map { $0.location..<NSMaxRange($0) }` | "reading: the rule under the caret is still drawn" |
| `setReading`: delete `textView.isEditable = !reading` | "reading: the text view isn't editable" |
| `toggleCheckbox`: delete `textView.isEditable = true` | (`EditorReadingCheckbox`) "reading: a checkbox click is handled" |
| `setReading`: delete `pendingScrollAnchor = scrollAnchor()` | (`EditorReadingSwitch`) "reading: the same line stays at the top" |
| `persistPins`: delete the `readingKey` line | (`ReadingTabs`) "only pinned reading tabs are stored" |

A mutation that stays green means its check doesn't test what it claims: strengthen that check (commit the fix with the task it belongs to) before going on.

- [ ] **Step 2: Final run** — `git status` shows a clean tree; `swift run Checks` → `✅ All checks passed`.

## Notes

- ⌘Z in a reading tab undoes whatever is on top of the text view's undo stack — a checkbox toggled while reading, or the last edit typed before switching. That is the same undo the note had before the switch.
- Out of scope (spec): copying without markers, a default-mode setting for new tabs, export / print (#2).
