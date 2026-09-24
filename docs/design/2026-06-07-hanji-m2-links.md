# hanji M2 (Links & Wikilinks) Implementation Plan

**Goal:** Extend Live Preview to markdown links `[text](url)` and Obsidian wikilinks `[[Page]]` / `[[Page|Alias]]` — rendered as styled links with their syntax markers hidden off the caret line and revealed on it, reusing the M1 tokenize→decorate→apply pipeline.

**Architecture:** Add a `.link` case to `SpanStyle`, extend `InlineTokenizer` with bracket parsing (wikilink + markdown-link), add link attributes to `LivePreviewStyler`. `Decorator` is generic over spans and needs no change. Verified by `Checks` (offset unit checks + headless styling) and screenshot E2E.

**Tech Stack:** Swift 5 mode / SPM, existing `Checks` runner, `screencapture` E2E via `HANJI_OPEN_VAULT` / `HANJI_CARET` hooks (from M1).

**Reference spec:** `docs/design/2026-06-06-native-markdown-editor-design.md` (M2 in §10). This plan is the first M2 increment; remaining M2 elements are deferred (see end).

**Conventions:** Work on `main`. UTF-16 offsets. Tests are check-groups in `Sources/Checks/` registered in `main.swift`.

---

## Task 1: Tokenizer — links and wikilinks

**Files:**
- Modify: `Sources/MarkdownCore/MarkSpan.swift` (add `.link`)
- Modify: `Sources/MarkdownCore/InlineTokenizer.swift`
- Create: `Sources/Checks/LinkTokenizerChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Add `.link` to `SpanStyle`** in `Sources/MarkdownCore/MarkSpan.swift`

Add a case to the `SpanStyle` enum so it reads:

```swift
public enum SpanStyle: Equatable {
    case heading(Int)   // 1...6
    case bold
    case italic
    case inlineCode
    case link
}
```

- [ ] **Step 2: Write the failing checks** `Sources/Checks/LinkTokenizerChecks.swift`

```swift
import MarkdownCore

func linkTokenizerChecks() {
    let l = InlineTokenizer.spans(in: "[text](url)")
    expectEqual(l.count, 1, "one link span")
    expectEqual(l.first?.style, .link, "link style")
    expectEqual(l.first?.content, 1..<5, "link content 'text'")
    expectEqual(l.first?.markers, [0..<1, 5..<11], "link markers '[' and '](url)'")

    let w = InlineTokenizer.spans(in: "[[Page]]")
    expectEqual(w.first?.style, .link, "wikilink is a link")
    expectEqual(w.first?.content, 2..<6, "wikilink content 'Page'")
    expectEqual(w.first?.markers, [0..<2, 6..<8], "wikilink markers '[[' and ']]'")

    let a = InlineTokenizer.spans(in: "[[Page|Alias]]")
    expectEqual(a.first?.content, 7..<12, "aliased wikilink shows alias")
    expectEqual(a.first?.markers, [0..<2, 2..<7, 12..<14], "markers '[[', 'Page|', ']]'")

    // Bold still works alongside (no regression in scan order)
    let b = InlineTokenizer.spans(in: "**b** [x](y)")
    expectEqual(b.count, 2, "bold + link on one line")
    expectEqual(b.last?.style, .link, "second span is the link")
}
```

- [ ] **Step 3: Register and run (red)**

Add `("LinkTokenizer", linkTokenizerChecks),` to `Sources/Checks/main.swift`.
Run: `swift run Checks LinkTokenizer`
Expected: FAIL — assertions fail (no link spans produced yet).

- [ ] **Step 4: Extend the tokenizer** in `Sources/MarkdownCore/InlineTokenizer.swift`

Add these constants next to the existing `private static let` characters:

```swift
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)
    private static let pipeChar = UInt16(UnicodeScalar("|").value)
```

In `parseLine`, inside the `while i < n` loop, add a `[` branch immediately **before** the `if c == star {` block:

```swift
            if c == openBracket, let (span, next) = bracketSpan(ns, from: i, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
```

Add these helper methods to the enum:

```swift
    private static func bracketSpan(_ ns: NSString, from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        if start + 1 < ns.length && ns.character(at: start + 1) == openBracket {
            return wikilinkSpan(ns, from: start, lineStart: lineStart, lineRange: lineRange)
        }
        return markdownLinkSpan(ns, from: start, lineStart: lineStart, lineRange: lineRange)
    }

    private static func wikilinkSpan(_ ns: NSString, from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        let innerStart = start + 2
        var j = innerStart
        while j + 1 < n && !(ns.character(at: j) == closeBracket && ns.character(at: j + 1) == closeBracket) { j += 1 }
        guard j + 1 < n, ns.character(at: j) == closeBracket, ns.character(at: j + 1) == closeBracket, j > innerStart else { return nil }
        let closeStart = j
        var pipe = -1
        var k = innerStart
        while k < closeStart { if ns.character(at: k) == pipeChar { pipe = k; break }; k += 1 }
        let openMarker = (lineStart + start)..<(lineStart + start + 2)
        let closeMarker = (lineStart + closeStart)..<(lineStart + closeStart + 2)
        if pipe >= 0 {
            guard pipe + 1 < closeStart else { return nil }
            let targetPipeMarker = (lineStart + innerStart)..<(lineStart + pipe + 1)
            let content = (lineStart + pipe + 1)..<(lineStart + closeStart)
            return (MarkSpan(style: .link, content: content, markers: [openMarker, targetPipeMarker, closeMarker], line: lineRange), closeStart + 2)
        }
        let content = (lineStart + innerStart)..<(lineStart + closeStart)
        return (MarkSpan(style: .link, content: content, markers: [openMarker, closeMarker], line: lineRange), closeStart + 2)
    }

    private static func markdownLinkSpan(_ ns: NSString, from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        var j = start + 1
        while j < n && ns.character(at: j) != closeBracket { j += 1 }
        guard j < n, j > start + 1 else { return nil }
        guard j + 1 < n, ns.character(at: j + 1) == openParen else { return nil }
        var k = j + 2
        while k < n && ns.character(at: k) != closeParen { k += 1 }
        guard k < n else { return nil }
        let openMarker = (lineStart + start)..<(lineStart + start + 1)
        let tailMarker = (lineStart + j)..<(lineStart + k + 1)   // ](url)
        let content = (lineStart + start + 1)..<(lineStart + j)
        return (MarkSpan(style: .link, content: content, markers: [openMarker, tailMarker], line: lineRange), k + 1)
    }
```

- [ ] **Step 5: Run (green)**

Run: `swift run Checks LinkTokenizer`
Expected: `✅ All checks passed`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(core): tokenize markdown links and wikilinks"
```

---

## Task 2: Styler — link appearance

**Files:**
- Modify: `Sources/EditorEngine/LivePreviewStyler.swift`
- Create: `Sources/Checks/LinkStylerChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Add the `.link` case** to `attributes(for:)` in `Sources/EditorEngine/LivePreviewStyler.swift`

Add this case inside the `switch style` (before the closing brace):

```swift
        case .link:
            return [.foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue]
```

- [ ] **Step 2: Write the failing check** `Sources/Checks/LinkStylerChecks.swift`

```swift
import AppKit
import MarkdownCore
import EditorEngine

func linkStylerChecks() {
    let text = "see [docs](http://x) and [[Note]]"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    let end = (text as NSString).length
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: end..<end), to: storage)

    // 'd' of "docs" is at offset 5 -> link content, underlined
    let attrs = storage.attributes(at: 5, effectiveRange: nil)
    expect(attrs[.underlineStyle] != nil, "link content is underlined")
    expect((attrs[.foregroundColor] as? NSColor) == NSColor.linkColor, "link content uses link color")
}
```

- [ ] **Step 3: Register and run (red)**

Add `("LinkStyler", linkStylerChecks),` to `Sources/Checks/main.swift`.
Run: `swift run Checks LinkStyler`
Expected: FAIL (or build error) until Step 1's case is present; if Step 1 already added, it should pass — in that case run it to confirm green and skip to Step 4.

- [ ] **Step 4: Run (green) + build the app**

Run: `swift run Checks LinkStyler` (Expected: PASS), then `swift build` (Expected: `Build complete!`).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(editor): style links and wikilinks"
```

---

## Task 3: E2E — verify links hide/reveal via screenshot

**Files:**
- Modify: `<demo-vault>/demo.md`

- [ ] **Step 1: Add link examples** to the demo note (append to `<demo-vault>/demo.md`):

```markdown

## Links

A markdown link [the docs](https://example.com) and a wikilink [[Some Note]]
plus an aliased one [[Target Page|nice name]].
```

- [ ] **Step 2: Capture with caret OFF the links line (markers hidden)**

```bash
swift build >/dev/null 2>&1
HANJI_OPEN_VAULT="$HOME/workspace/hanji-demo-vault" HANJI_CARET=0 ./.build/debug/hanji >/tmp/mk.log 2>&1 &
APP=$!; sleep 6; screencapture -x /tmp/hanji-m2-off.png; sleep 1; kill $APP 2>/dev/null; pkill -x hanji 2>/dev/null
```
Read `/tmp/hanji-m2-off.png`. Expected: link text shows as styled link words ("the docs", "Some Note", "nice name") with **no** `[`, `]`, `(url)`, `[[`, `]]`, or `Target Page|` visible.

- [ ] **Step 3: Capture with caret ON the links line (markers revealed)**

Find the UTF-16 offset of the links paragraph (it follows the appended "## Links" heading). Use an offset within that paragraph (e.g., compute by trial: open the file length and target the `[the docs]` region; a value around the end of the document works since the links are last). Run:

```bash
HANJI_OPEN_VAULT="$HOME/workspace/hanji-demo-vault" HANJI_CARET=999 ./.build/debug/hanji >/tmp/mk.log 2>&1 &
APP=$!; sleep 6; screencapture -x /tmp/hanji-m2-on.png; sleep 1; kill $APP 2>/dev/null; pkill -x hanji 2>/dev/null
```
(`HANJI_CARET=999` clamps to end-of-document, placing the caret on the last line — the aliased wikilink line.) Read `/tmp/hanji-m2-on.png`. Expected: the caret's line shows raw markers (`[[Target Page|nice name]]`), while earlier link lines stay hidden/styled.

- [ ] **Step 4: Commit** (only the demo note change; screenshots are in /tmp and git-ignored)

```bash
git add -A
git commit -m "test(e2e): link examples in demo vault"
```

---

## Task 4: Wrap — status + full suite

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the status bullet** in `README.md` — change the Live Preview line to include links:

Replace:
```markdown
- **Live Preview** for headings, bold, italic, inline code: inline styling with
  caret-aware marker hiding (markers reveal on the line you're editing)
```
with:
```markdown
- **Live Preview** for headings, bold, italic, inline code, links & wikilinks:
  inline styling with caret-aware marker hiding (markers reveal on the line you're editing)
```

- [ ] **Step 2: Run the full check suite**

Run: `swift run Checks`
Expected: `✅ All checks passed` including new groups `LinkTokenizer` and `LinkStyler`, no failures.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: links & wikilinks in Live Preview status"
```

---

## Deferred (subsequent M2 increments)

These spec §10 M2 elements are **not** in this plan and each gets its own increment:
- **Block/paragraph styling:** blockquote `>`, frontmatter YAML block, unordered/ordered lists (need `NSParagraphStyle` handling).
- **Inline-view attachments** (need `NSTextAttachmentViewProvider` + the SDK's `RendererRegistry` surface ①): fenced code blocks, images (`![alt](url)` / `![[img]]`), callouts `> [!note]`, interactive task checkboxes.

---

## Self-Review

**Spec coverage:** This plan covers the link/wikilink portion of spec §10 M2. Remaining M2 elements are explicitly listed under "Deferred". ✓

**Placeholder scan:** No "TBD"/uncoded steps. Task 3 Step 3 gives a concrete clamping trick (`HANJI_CARET=999`) rather than a vague "find the offset". ✓

**Type consistency:** `SpanStyle.link`, `InlineTokenizer.spans(in:)` (extended), `MarkSpan(style:content:markers:line:)`, `Decorator.decorations(spans:selection:)` (unchanged, generic), `LivePreviewStyler.apply(_:to:)` / `attributes(for:)` — consistent with M1. Marker lists for links use the same `[Range<Int>]` shape the decorator already hides. ✓
