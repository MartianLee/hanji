# hanji M2b (Blockquote & Frontmatter) Implementation Plan

**Goal:** Extend Live Preview to blockquotes (`> text`, with `> ` hidden off the caret line and an indented muted style) and YAML frontmatter (`---` … `---` at the top of a note, shown as a dimmed monospaced block).

**Architecture:** Add `.blockquote` and `.frontmatter` to `SpanStyle`. `InlineTokenizer` emits a line span for each blockquote line (marker `> `) and one span per frontmatter line (no markers; detected only at document start). `Decorator` is unchanged (generic). `LivePreviewStyler` adds the two styles, using `NSParagraphStyle` for the blockquote indent. Verified by `Checks` + screenshot E2E.

**Tech Stack:** Swift 5 / SPM; existing `Checks` runner + `screencapture` E2E hooks.

**Reference spec:** `docs/design/2026-06-06-native-markdown-editor-design.md` (M2 in §10). Continues the M2 increments after links/wikilinks.

**Conventions:** Work on `main`. UTF-16 offsets. Check-groups in `Sources/Checks/` registered in `main.swift`.

> Note: adding `SpanStyle` cases makes `LivePreviewStyler`'s switch non-exhaustive, so Task 1 and Task 2 are implemented together in one build (learned from the links increment).

---

## Task 1: Tokenizer — blockquote lines + frontmatter block

**Files:**
- Modify: `Sources/MarkdownCore/MarkSpan.swift` (add `.blockquote`, `.frontmatter`)
- Modify: `Sources/MarkdownCore/InlineTokenizer.swift`
- Create: `Sources/Checks/BlockTokenizerChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Add cases to `SpanStyle`** in `Sources/MarkdownCore/MarkSpan.swift`

The enum becomes:

```swift
public enum SpanStyle: Equatable {
    case heading(Int)   // 1...6
    case bold
    case italic
    case inlineCode
    case link
    case blockquote
    case frontmatter
}
```

- [ ] **Step 2: Add the `>` constant** in `Sources/MarkdownCore/InlineTokenizer.swift`

Next to the other `private static let` characters add:

```swift
    private static let gt = UInt16(UnicodeScalar(">").value)
```

- [ ] **Step 3: Detect frontmatter in `spans(in:)`** — replace the whole `spans(in:)` method with:

```swift
    public static func spans(in text: String) -> [MarkSpan] {
        var result: [MarkSpan] = []
        let ns = text as NSString
        let length = ns.length
        let newline = UInt16(UnicodeScalar("\n").value)

        var lineStart = 0
        var lineIndex = 0
        var inFrontmatter = false
        while lineStart <= length {
            var lineEnd = lineStart
            while lineEnd < length && ns.character(at: lineEnd) != newline { lineEnd += 1 }
            let lineRange = lineStart..<lineEnd
            let lineText = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))

            if lineIndex == 0 && lineText == "---" {
                inFrontmatter = true
                result.append(MarkSpan(style: .frontmatter, content: lineRange, markers: [], line: lineRange))
            } else if inFrontmatter {
                result.append(MarkSpan(style: .frontmatter, content: lineRange, markers: [], line: lineRange))
                if lineText == "---" { inFrontmatter = false }
            } else {
                parseLine(lineText as NSString, lineStart: lineStart, lineRange: lineRange, into: &result)
            }

            if lineEnd == length { break }
            lineStart = lineEnd + 1
            lineIndex += 1
        }
        return result
    }
```

- [ ] **Step 4: Detect blockquote in `parseLine`** — add this right after the heading check (before the inline `while` loop):

```swift
        if let quote = blockquoteSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(quote)
            return
        }
```

And add the helper (next to `headingSpan`):

```swift
    private static func blockquoteSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> MarkSpan? {
        let n = ns.length
        guard n >= 2, ns.character(at: 0) == gt, ns.character(at: 1) == space else { return nil }
        let markers = [(lineStart)..<(lineStart + 2)]   // "> "
        let content = (lineStart + 2)..<(lineStart + n)
        return MarkSpan(style: .blockquote, content: content, markers: markers, line: lineRange)
    }
```

- [ ] **Step 5: Write the checks** `Sources/Checks/BlockTokenizerChecks.swift`

```swift
import MarkdownCore

func blockTokenizerChecks() {
    let q = InlineTokenizer.spans(in: "> quote")
    expectEqual(q.count, 1, "one blockquote span")
    expectEqual(q.first?.style, .blockquote, "blockquote style")
    expectEqual(q.first?.content, 2..<7, "content after '> '")
    expectEqual(q.first?.markers, [0..<2], "marker '> '")

    let fm = InlineTokenizer.spans(in: "---\ntitle: x\n---\n# H")
    expectEqual(fm.filter { $0.style == .frontmatter }.count, 3, "three frontmatter lines incl fences")
    expectEqual(fm.contains { $0.style == .heading(1) }, true, "heading after frontmatter parsed normally")

    let notfm = InlineTokenizer.spans(in: "x\n---")
    expectEqual(notfm.contains { $0.style == .frontmatter }, false, "--- mid-doc is not frontmatter")
}
```

- [ ] **Step 6: Register** — add `("BlockTokenizer", blockTokenizerChecks),` to `Sources/Checks/main.swift`. (Build will fail until Task 2's styler cases exist — that's expected; do Task 2 next, then run.)

---

## Task 2: Styler — blockquote indent + frontmatter dim

**Files:**
- Modify: `Sources/EditorEngine/LivePreviewStyler.swift`
- Create: `Sources/Checks/BlockStylerChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Add the two cases** to `attributes(for:)` in `Sources/EditorEngine/LivePreviewStyler.swift` (before the closing `}` of the switch):

```swift
        case .blockquote:
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = 16
            p.headIndent = 16
            return [.foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]
        case .frontmatter:
            return [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor]
```

- [ ] **Step 2: Write the check** `Sources/Checks/BlockStylerChecks.swift`

```swift
import AppKit
import MarkdownCore
import EditorEngine

func blockStylerChecks() {
    let text = "---\nk: v\n---\n> quoted line"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: 0..<0), to: storage)

    // frontmatter 'k' at offset 4 -> tertiary color
    let fm = storage.attributes(at: 4, effectiveRange: nil)
    expect((fm[.foregroundColor] as? NSColor) == NSColor.tertiaryLabelColor, "frontmatter dimmed")

    // blockquote content 'quoted' at offset 15 -> indented paragraph style
    let bq = storage.attributes(at: 15, effectiveRange: nil)
    let p = bq[.paragraphStyle] as? NSParagraphStyle
    expect(p != nil && p!.headIndent > 0, "blockquote indented")
}
```

- [ ] **Step 3: Register and run (green)**

Add `("BlockStyler", blockStylerChecks),` to `Sources/Checks/main.swift`.
Run: `swift run Checks` — Expected: `✅ All checks passed` including `BlockTokenizer` and `BlockStyler`. Then `swift build` (Expected: `Build complete!`).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: Live Preview for blockquotes and frontmatter"
```

---

## Task 3: E2E — verify via screenshot

**Files:**
- Modify: `<demo-vault>/demo.md`

- [ ] **Step 1: Add a frontmatter header and a quote.** Prepend frontmatter to the very top of `<demo-vault>/demo.md` and add a blockquote section. The file must START with the `---` block (frontmatter is only recognized at line 0):

Top of file becomes:
```markdown
---
title: hanji demo
tags: [demo, live-preview]
---
# hanji Live Preview demo
```
And add before "## Links":
```markdown
## Quote

> This is a blockquote.
> It stays indented and muted off the caret line.
```

- [ ] **Step 2: Capture (caret at top — quote markers hidden)**

```bash
swift build >/dev/null 2>&1
HANJI_OPEN_VAULT="$HOME/workspace/hanji-demo-vault" HANJI_CARET=0 ./.build/debug/hanji >/tmp/mk.log 2>&1 &
A=$!; sleep 7; screencapture -x /tmp/hanji-m2b.png; kill $A 2>/dev/null; pkill -x hanji 2>/dev/null
```
Read `/tmp/hanji-m2b.png`. Expected: frontmatter shows as a dim monospaced block; the quote lines are indented and muted with no `>` visible.

- [ ] **Step 3: Capture (caret on a quote line — `>` revealed)**

```bash
OFF=$(python3 -c "print(open('$HOME/workspace/hanji-demo-vault/demo.md').read().find('This is a blockquote'))")
HANJI_OPEN_VAULT="$HOME/workspace/hanji-demo-vault" HANJI_CARET=$OFF ./.build/debug/hanji >/tmp/mk.log 2>&1 &
A=$!; sleep 7; screencapture -x /tmp/hanji-m2b-on.png; kill $A 2>/dev/null; pkill -x hanji 2>/dev/null
```
Read `/tmp/hanji-m2b-on.png`. Expected: the caret's quote line shows the raw `> ` prefix; other quote line stays hidden/indented.

---

## Task 4: Wrap — status + full suite

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the Live Preview status line** in `README.md` to append blockquotes & frontmatter:

Change the Live Preview bullet to:
```markdown
- **Live Preview** for headings, bold, italic, inline code, links & wikilinks,
  blockquotes & frontmatter: inline styling with caret-aware marker hiding
```

- [ ] **Step 2: Full suite** — `swift run Checks` (Expected: `✅ All checks passed`, groups now include `BlockTokenizer`, `BlockStyler`).

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: blockquotes & frontmatter in Live Preview status"
```

---

## Self-Review

**Spec coverage:** Adds blockquote + frontmatter from spec §10 M2. Lists and inline-view attachments (code blocks/images/callouts) remain deferred to their own increments. ✓

**Placeholder scan:** No TBD/uncoded steps; the caret offset in Task 3 Step 3 is computed concretely via `python3 ... .find(...)`. ✓

**Type consistency:** `SpanStyle.blockquote`/`.frontmatter`, `InlineTokenizer.spans(in:)` (frontmatter at doc start; `blockquoteSpan` in `parseLine`), `Decorator` unchanged (generic), `LivePreviewStyler.attributes(for:)` extended. Blockquote uses the existing full-range StyleRun so the `NSParagraphStyle` covers the whole line. ✓
