# hanji M2c (Lists & Tasks) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Live Preview for unordered list items (`- `/`* `/`+ `) and tasks (`- [ ] ` / `- [x] `): list items get a hanging indent; completed tasks get a strikethrough + muted text; the checkbox stays visible (interactive checkboxes are deferred to the attachment milestone).

**Architecture:** Add `.listItem` and `.task(Bool)` to `SpanStyle`. `InlineTokenizer.parseLine` recognizes task lines (before list lines) and list lines (after heading/blockquote). `Decorator` unchanged. `LivePreviewStyler` adds paragraph indent + (for done tasks) strikethrough. Verified by `Checks`.

**Tech Stack:** Swift 5 / SPM; `Checks` runner.

**Reference spec:** `docs/2026-06-06-native-markdown-editor-design.md` (M2 §10). Continues M2 increments.

**Conventions:** `~/workspace/hanji` on `main`; UTF-16 offsets; check-groups in `Sources/Checks/`; commit trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Tokenizer + styler land together (SpanStyle coupling).

---

## Task 1: Tokenizer + Styler — lists and tasks

**Files:**
- Modify: `Sources/MarkdownCore/MarkSpan.swift`
- Modify: `Sources/MarkdownCore/InlineTokenizer.swift`
- Modify: `Sources/EditorEngine/LivePreviewStyler.swift`
- Create: `Sources/Checks/ListTaskTokenizerChecks.swift`, `Sources/Checks/ListTaskStylerChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Add cases to `SpanStyle`** (`MarkSpan.swift`):

```swift
    case blockquote
    case frontmatter
    case listItem
    case task(Bool)   // done?
```

- [ ] **Step 2: Add constants** in `InlineTokenizer.swift` (next to the others):

```swift
    private static let dash = UInt16(UnicodeScalar("-").value)
    private static let plus = UInt16(UnicodeScalar("+").value)
    private static let xLower = UInt16(UnicodeScalar("x").value)
    private static let xUpper = UInt16(UnicodeScalar("X").value)
```

- [ ] **Step 3: Recognize tasks then lists** in `parseLine` — add after the blockquote block (before `let n = ns.length`):

```swift
        if let task = taskSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(task)
            return
        }
        if let list = listSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(list)
            return
        }
```

And add the helpers (next to `blockquoteSpan`):

```swift
    private static func taskSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> MarkSpan? {
        let n = ns.length
        guard n >= 6,
              ns.character(at: 0) == dash, ns.character(at: 1) == space,
              ns.character(at: 2) == openBracket, ns.character(at: 4) == closeBracket,
              ns.character(at: 5) == space else { return nil }
        let mark = ns.character(at: 3)
        let done: Bool
        if mark == space { done = false }
        else if mark == xLower || mark == xUpper { done = true }
        else { return nil }
        let content = (lineStart + 6)..<(lineStart + n)
        return MarkSpan(style: .task(done), content: content, markers: [], line: lineRange)
    }

    private static func listSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> MarkSpan? {
        let n = ns.length
        guard n >= 2, ns.character(at: 1) == space else { return nil }
        let c0 = ns.character(at: 0)
        guard c0 == dash || c0 == star || c0 == plus else { return nil }
        let content = (lineStart + 2)..<(lineStart + n)
        return MarkSpan(style: .listItem, content: content, markers: [], line: lineRange)
    }
```

- [ ] **Step 4: Add styler cases** in `LivePreviewStyler.swift` `attributes(for:)` (before the switch's closing `}`):

```swift
        case .listItem:
            let p = NSMutableParagraphStyle()
            p.headIndent = 20
            return [.paragraphStyle: p]
        case .task(let done):
            let p = NSMutableParagraphStyle()
            p.headIndent = 20
            if done {
                return [.paragraphStyle: p,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.secondaryLabelColor]
            }
            return [.paragraphStyle: p]
```

- [ ] **Step 5: Write the checks**

`Sources/Checks/ListTaskTokenizerChecks.swift`:
```swift
import MarkdownCore

func listTaskTokenizerChecks() {
    let u = InlineTokenizer.spans(in: "- item")
    expectEqual(u.first?.style, .listItem, "dash list item")
    expectEqual(u.first?.content, 2..<6, "list content after '- '")

    let s = InlineTokenizer.spans(in: "* bullet")
    expectEqual(s.first?.style, .listItem, "star list item")

    let open = InlineTokenizer.spans(in: "- [ ] todo")
    expectEqual(open.first?.style, .task(false), "open task")
    expectEqual(open.first?.content, 6..<10, "task content after '- [ ] '")

    let done = InlineTokenizer.spans(in: "- [x] done")
    expectEqual(done.first?.style, .task(true), "done task")

    // '*italic*' (no space) must NOT be a list item
    let it = InlineTokenizer.spans(in: "*italic*")
    expectEqual(it.first?.style, .italic, "no-space star is italic, not a list")
}
```

`Sources/Checks/ListTaskStylerChecks.swift`:
```swift
import AppKit
import MarkdownCore
import EditorEngine

func listTaskStylerChecks() {
    let text = "- [x] done\n- item"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: 100..<100), to: storage)

    // completed task text 'done' at offset 6 -> strikethrough
    let d = storage.attributes(at: 6, effectiveRange: nil)
    expect(d[.strikethroughStyle] != nil, "completed task text struck through")

    // list item 'item' at offset 13 -> hanging indent
    let l = storage.attributes(at: 13, effectiveRange: nil)
    let p = l[.paragraphStyle] as? NSParagraphStyle
    expect(p != nil && p!.headIndent > 0, "list item indented")
}
```

- [ ] **Step 6: Register** — add to `Sources/Checks/main.swift`:
```swift
    ("ListTaskTokenizer", listTaskTokenizerChecks),
    ("ListTaskStyler", listTaskStylerChecks),
```

- [ ] **Step 7: Run + build + commit**

Run: `swift run Checks` (Expected: `✅ All checks passed`), then `swift build` (Expected: `Build complete!`).
```bash
git add -A
git commit -m "feat: Live Preview for lists and tasks"
```

---

## Task 2: Wrap — status

- [ ] **Step 1:** In `README.md`, append "lists & tasks" to the Live Preview bullet.
- [ ] **Step 2:** `swift run Checks` (Expected: green, with `ListTaskTokenizer`/`ListTaskStyler`).
- [ ] **Step 3:** Commit:
```bash
git add -A
git commit -m "docs: lists & tasks in Live Preview status"
```

---

## Self-Review

**Spec coverage:** list/task from §10 M2 (as text styling; interactive checkboxes + bullets-as-glyphs deferred to the attachment milestone). ✓
**Placeholder scan:** none. ✓
**Type consistency:** `.listItem`, `.task(Bool)`; `taskSpan` checked before `listSpan`; `*italic*` (no space) still routes to inline italic. `Decorator` unchanged; styler uses full-range StyleRun so `NSParagraphStyle` covers the line. ✓
