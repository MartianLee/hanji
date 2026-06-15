# hanji M2d (Fenced Code Blocks — styled) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans or subagent-driven-development. Checkbox steps.

**Goal:** Live Preview for fenced code blocks (` ``` … ``` `): render the whole block (fences + body) as a monospaced, background-shaded region. (Rendering code blocks as *interactive widgets* — mermaid diagrams, Dataview tables — is the separate attachments milestone using `NSTextAttachmentViewProvider` + the SDK `RendererRegistry`; this increment is pure text styling, no attachments.)

**Architecture:** Add `.codeBlock` to `SpanStyle`. `InlineTokenizer.spans(in:)` tracks an `inCodeBlock` state (open/close on lines starting with ` ``` `), emitting a `.codeBlock` span per line. `Decorator` unchanged. `LivePreviewStyler` styles `.codeBlock` as mono + background. Verified by `Checks`.

**Tech Stack:** Swift 5 / SPM; `Checks` runner.

**Reference spec:** `docs/2026-06-06-native-markdown-editor-design.md` (§10 M2, §5.3 notes the future widget path).

**Conventions:** `~/workspace/hanji` on `main`; UTF-16 offsets; check-groups in `Sources/Checks/`; commit trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Tokenizer + styler land together (SpanStyle coupling).

---

## Task 1: Tokenizer + Styler — fenced code blocks

**Files:** modify `MarkSpan.swift`, `InlineTokenizer.swift`, `LivePreviewStyler.swift`; create `CodeBlockTokenizerChecks.swift`, `CodeBlockStylerChecks.swift`; modify `Sources/Checks/main.swift`.

- [ ] **Step 1: Add `case codeBlock`** after `case task(Bool)` in `SpanStyle` (`MarkSpan.swift`).

- [ ] **Step 2: Track code-block state in `spans(in:)`** — replace the `else { parseLine(...) }` tail of the line loop with code-block branches. The full chain becomes:

```swift
            if lineIndex == 0 && lineText == "---" {
                inFrontmatter = true
                result.append(MarkSpan(style: .frontmatter, content: lineRange, markers: [], line: lineRange))
            } else if inFrontmatter {
                result.append(MarkSpan(style: .frontmatter, content: lineRange, markers: [], line: lineRange))
                if lineText == "---" { inFrontmatter = false }
            } else if inCodeBlock {
                result.append(MarkSpan(style: .codeBlock, content: lineRange, markers: [], line: lineRange))
                if lineText.hasPrefix("```") { inCodeBlock = false }
            } else if lineText.hasPrefix("```") {
                inCodeBlock = true
                result.append(MarkSpan(style: .codeBlock, content: lineRange, markers: [], line: lineRange))
            } else {
                parseLine(lineText as NSString, lineStart: lineStart, lineRange: lineRange, into: &result)
            }
```

And declare `var inCodeBlock = false` next to `var inFrontmatter = false`.

- [ ] **Step 3: Add styler case** in `LivePreviewStyler.attributes(for:)`:

```swift
        case .codeBlock:
            return [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .backgroundColor: NSColor.quaternaryLabelColor]
```

- [ ] **Step 4: Checks** — `Sources/Checks/CodeBlockTokenizerChecks.swift`:

```swift
import MarkdownCore

func codeBlockTokenizerChecks() {
    let spans = InlineTokenizer.spans(in: "before\n```swift\nlet x = 1\n```\nafter")
    expectEqual(spans.filter { $0.style == .codeBlock }.count, 3, "fence + body + fence = 3 codeBlock lines")
    expect(spans.contains { $0.style == .heading(1) } == false, "no heading parsing inside fences")

    let open = InlineTokenizer.spans(in: "```\nx")
    expectEqual(open.filter { $0.style == .codeBlock }.count, 2, "unclosed fence styles following lines")

    // '# H' inside a code block is NOT a heading
    let h = InlineTokenizer.spans(in: "```\n# H\n```")
    expect(h.contains { $0.style == .codeBlock }, "code block recognized")
    expect(h.contains { if case .heading = $0.style { return true } else { return false } } == false,
           "hash inside fence is code, not heading")
}
```

`Sources/Checks/CodeBlockStylerChecks.swift`:

```swift
import AppKit
import MarkdownCore
import EditorEngine

func codeBlockStylerChecks() {
    let text = "```\nlet x = 1\n```"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: 100..<100), to: storage)

    // 'let' at offset 4 -> background-shaded code region
    let a = storage.attributes(at: 4, effectiveRange: nil)
    expect(a[.backgroundColor] != nil, "code block has background")
    let f = a[.font] as? NSFont
    expect(f != nil && f!.pointSize == 13, "code block uses the mono code font size")
}
```

- [ ] **Step 5: Register** — add to `main.swift`:
```swift
    ("CodeBlockTokenizer", codeBlockTokenizerChecks),
    ("CodeBlockStyler", codeBlockStylerChecks),
```

- [ ] **Step 6: Run + build + commit**

`swift run Checks` (Expected: green), `swift build` (Expected: complete).
```bash
git add -A
git commit -m "feat: Live Preview for fenced code blocks (styled)"
```

---

## Task 2: Wrap

- [ ] Append "code blocks" to the README Live Preview bullet; `swift run Checks`; commit `docs: code blocks in Live Preview status`.

---

## Self-Review

**Spec coverage:** fenced code block (text styling) from §10 M2; widget rendering deferred to the attachments milestone (§5.3). ✓
**Placeholder scan:** none. ✓
**Type consistency:** `.codeBlock`; `inCodeBlock` toggled on ` ``` ` prefix; code-block lines bypass `parseLine` so inner `#`/`*` aren't parsed; `Decorator` unchanged; styler uses full-range run (markers empty → whole line). ✓
