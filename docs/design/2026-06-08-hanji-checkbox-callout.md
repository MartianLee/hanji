# hanji — Interactive Checkboxes & Callouts Plan

**Goal:** (1) Make task checkboxes **interactive** — clicking `[ ]`/`[x]` toggles the source and saves. (2) Render **callouts** (`> [!type] …`) as a tinted, indented box.

**Architecture:** `MarkdownCore` gets a pure `TaskToggle` (click offset → which char to flip) and callout parsing (`.callout` span via multi-line state in `spans(in:)`). `EditorEngine` uses an `NSTextView` subclass whose `mouseDown` asks a callback to toggle a checkbox (minimal `replaceCharacters`, preserving caret/undo). `LivePreviewStyler` styles `.callout`. Verified by `Checks` + screenshot E2E.

**Conventions:** UTF-16 offsets; check-groups in `Sources/Checks/`.

---

## Task 1: MarkdownCore — TaskToggle (pure)

**Files:** Create `Sources/MarkdownCore/TaskToggle.swift`, `Sources/Checks/TaskToggleChecks.swift`; modify `main.swift`.

- [ ] **Step 1:** `Sources/MarkdownCore/TaskToggle.swift`

```swift
import Foundation

public enum TaskToggle {
    /// If `clickOffset` lands on a task line's checkbox brackets (`[ ]`/`[x]`),
    /// returns the UTF-16 offset of the state char and its replacement; else nil.
    public static func toggle(in text: String, at clickOffset: Int) -> (offset: Int, replacement: String)? {
        let ns = text as NSString
        let len = ns.length
        guard clickOffset >= 0, clickOffset <= len else { return nil }
        // line start
        var lineStart = clickOffset
        while lineStart > 0 && ns.character(at: lineStart - 1) != 0x0A { lineStart -= 1 }
        // must look like "- [ ] " or "- [x] "
        guard lineStart + 6 <= len else { return nil }
        let dash = UInt16(UnicodeScalar("-").value), sp = UInt16(UnicodeScalar(" ").value)
        let lb = UInt16(UnicodeScalar("[").value), rb = UInt16(UnicodeScalar("]").value)
        guard ns.character(at: lineStart) == dash, ns.character(at: lineStart + 1) == sp,
              ns.character(at: lineStart + 2) == lb, ns.character(at: lineStart + 4) == rb,
              ns.character(at: lineStart + 5) == sp else { return nil }
        // click must be on the brackets region [2..4]
        guard clickOffset >= lineStart + 2, clickOffset <= lineStart + 4 else { return nil }
        let state = ns.character(at: lineStart + 3)
        let x = UInt16(UnicodeScalar("x").value), X = UInt16(UnicodeScalar("X").value)
        let isDone = (state == x || state == X)
        return (offset: lineStart + 3, replacement: isDone ? " " : "x")
    }
}
```

- [ ] **Step 2:** `Sources/Checks/TaskToggleChecks.swift`

```swift
import MarkdownCore

func taskToggleChecks() {
    let open = TaskToggle.toggle(in: "- [ ] todo", at: 3)
    expectEqual(open?.offset, 3, "toggles state char")
    expectEqual(open?.replacement, "x", "open -> x")

    let done = TaskToggle.toggle(in: "- [x] todo", at: 2)
    expectEqual(done?.replacement, " ", "done -> space (click on '[')")

    expect(TaskToggle.toggle(in: "- [ ] todo", at: 8) == nil, "click on text is not a toggle")
    expect(TaskToggle.toggle(in: "plain line", at: 1) == nil, "non-task is nil")

    // second line task
    let second = TaskToggle.toggle(in: "x\n- [ ] a", at: 5)   // offset 5 -> '[' of line 2
    expectEqual(second?.offset, 5, "line-2 checkbox offset")
}
```

- [ ] **Step 3:** Register `("TaskToggle", taskToggleChecks)`; `swift run Checks TaskToggle` (green); commit `feat(core): TaskToggle for interactive checkboxes`.

---

## Task 2: EditorEngine — clickable checkboxes

**Files:** modify `Sources/EditorEngine/MarkdownEditorView.swift`.

- [ ] **Step 1:** Add an `NSTextView` subclass at the top of the file:

```swift
final class ClickableTextView: NSTextView {
    var onClick: ((Int) -> Bool)?   // returns true if the click was handled
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: p)
        if onClick?(idx) == true { return }
        super.mouseDown(with: event)
    }
}
```

- [ ] **Step 2:** Use it in `makeNSView`: change `NSTextView(usingTextLayoutManager: true)` to `ClickableTextView(usingTextLayoutManager: true)` (keep the `let textView`), and after creating the coordinator wiring set:

```swift
        (textView as? ClickableTextView)?.onClick = { [weak coordinator = context.coordinator] idx in
            coordinator?.toggleCheckbox(at: idx) ?? false
        }
```

- [ ] **Step 3:** Add to `Coordinator`:

```swift
        func toggleCheckbox(at index: Int) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            guard let t = TaskToggle.toggle(in: storage.string, at: index) else { return false }
            storage.replaceCharacters(in: NSRange(location: t.offset, length: 1), with: t.replacement)
            parent.text = textView.string
            refresh()
            return true
        }
```

(import already includes MarkdownCore.)

- [ ] **Step 4:** `swift build`; E2E — open a vault note with `- [ ] task`, screenshot, then launch with caret elsewhere and confirm clicking toggles (manual/secondary — primary check is build + the pure TaskToggle). Commit `feat(editor): clickable task checkboxes`.

---

## Task 3: MarkdownCore — callout parsing

**Files:** modify `MarkSpan.swift` (add `.callout`), `InlineTokenizer.swift` (callout state in `spans`); create `Sources/Checks/CalloutTokenizerChecks.swift`; modify `main.swift`.

- [ ] **Step 1:** Add `case callout` to `SpanStyle`.

- [ ] **Step 2:** In `spans(in:)`, add an `inCallout` state. Replace the `else { parseLine(...) }` tail with:

```swift
            } else if line.hasPrefix("> ") && (inCallout || String(line.dropFirst(2)).hasPrefix("[!")) {
                inCallout = true
                let markers = [lineStart..<(lineStart + 2)]   // "> "
                let content = (lineStart + 2)..<(lineStart + (line as NSString).length)
                result.append(MarkSpan(style: .callout, content: content, markers: markers, line: lineRange))
            } else {
                inCallout = false
                parseLine(lineText as NSString, lineStart: lineStart, lineRange: lineRange, into: &result)
            }
```

And declare `var inCallout = false` with the other state vars.

- [ ] **Step 3:** `Sources/Checks/CalloutTokenizerChecks.swift`

```swift
import MarkdownCore

func calloutTokenizerChecks() {
    let c = InlineTokenizer.spans(in: "> [!note] Title\n> body\nplain")
    let callouts = c.filter { $0.style == .callout }
    expectEqual(callouts.count, 2, "header + body line are callout")
    expectEqual(callouts.first?.markers, [0..<2], "'> ' marker hidden off-line")
    // a plain blockquote (no [!) is NOT a callout
    let bq = InlineTokenizer.spans(in: "> just a quote")
    expect(bq.contains { $0.style == .callout } == false, "plain blockquote is not a callout")
    expect(bq.contains { $0.style == .blockquote }, "it's a blockquote")
}
```

- [ ] **Step 4:** Register `("CalloutTokenizer", calloutTokenizerChecks)`; `swift run Checks CalloutTokenizer` (green).

---

## Task 4: Styler — callout box

**Files:** modify `LivePreviewStyler.swift`; create `Sources/Checks/CalloutStylerChecks.swift`; modify `main.swift`.

- [ ] **Step 1:** Add the case (before the switch's closing `}`):

```swift
        case .callout:
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = 16
            p.headIndent = 16
            return [.backgroundColor: NSColor.systemBlue.withAlphaComponent(0.12),
                    .paragraphStyle: p]
```

- [ ] **Step 2:** `Sources/Checks/CalloutStylerChecks.swift`

```swift
import AppKit
import MarkdownCore
import EditorEngine

func calloutStylerChecks() {
    let text = "> [!note] Hi\n> body"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: 100..<100), to: storage)
    // header content 'Hi' region offset 10 -> has callout background
    let a = storage.attributes(at: 10, effectiveRange: nil)
    expect(a[.backgroundColor] != nil, "callout has background tint")
}
```

- [ ] **Step 3:** Register `("CalloutStyler", calloutStylerChecks)`; `swift run Checks` (full, green); `swift build`; commit `feat: callouts (> [!type]) rendered as tinted boxes`.

---

## Task 5: Wrap + finish

- [ ] README: add "interactive checkboxes" and "callouts" to the Live Preview line.
- [ ] `swift run Checks` (green); copy this plan into repo `docs/`; commit.
- [ ] Merge `checkbox-callout` → `main`.

---

## Self-Review

**Spec coverage:** interactive tasks + callouts from §10 M2. ✓
**Placeholder scan:** none. ✓
**Type consistency:** `TaskToggle.toggle(in:at:)->(offset:,replacement:)?`, `ClickableTextView.onClick`, `Coordinator.toggleCheckbox(at:)`, `SpanStyle.callout`, callout span (marker `> `, content after). Callout detection precedes plain blockquote (parseLine) because it's handled in `spans()` before the `else`. ✓
