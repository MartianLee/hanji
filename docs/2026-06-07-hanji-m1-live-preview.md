# hanji M1 (Live Preview Basics + Marker-Hiding Spike) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add incremental Live Preview to the hanji editor for the first element set — headings, bold, italic, inline code — where markdown is styled inline and syntax markers collapse except on the line containing the caret (the caret-aware reveal that defines the Obsidian feel).

**Architecture:** Pure logic lives in `MarkdownCore`: a line-based `InlineTokenizer` produces `MarkSpan`s (UTF-16 offset ranges for content + markers + enclosing line), and a pure `Decorator.decorations(spans:selection:)` turns spans + caret position into a `DecorationSet` (style runs + marker ranges to hide). `EditorEngine` applies the `DecorationSet` to the `NSTextView`'s `NSTextStorage` and recomputes it on every text/selection change. This isolates the testable heart (tokenize + decide) from the empirical part (apply to TextKit).

**Tech Stack:** Swift 5 mode / SPM, AppKit `NSTextView` (TextKit 2) + `NSTextStorage` attributes, the existing zero-dependency `Checks` runner (`swift run Checks`). Builds on M0; no new external dependencies.

**Reference spec:** `docs/superpowers/specs/2026-06-06-native-markdown-editor-design.md` (M1 in §10, decoration pipeline in §5.3, R1 in §11).

**Conventions for every task:**
- Work in `~/workspace/hanji` on `main` (continues M0).
- All offsets are **UTF-16 code units** (NSRange/`NSString`-compatible).
- Tests are check-group functions in `Sources/Checks/`, registered in `Sources/Checks/main.swift`, run with `swift run Checks [GroupName]`.
- **Every commit message ends with** (blank line before it): `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## Task 1: MarkdownCore — InlineTokenizer (headings, bold, italic, inline code)

**Files:**
- Create: `Sources/MarkdownCore/MarkSpan.swift`
- Create: `Sources/MarkdownCore/InlineTokenizer.swift`
- Create: `Sources/Checks/TokenizerChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Define the span model** `Sources/MarkdownCore/MarkSpan.swift`

```swift
import Foundation

public enum SpanStyle: Equatable {
    case heading(Int)   // 1...6
    case bold
    case italic
    case inlineCode
}

/// A recognized markdown construct, in UTF-16 code-unit offsets (NSRange-compatible).
public struct MarkSpan: Equatable {
    public let style: SpanStyle
    public let content: Range<Int>      // visible content
    public let markers: [Range<Int>]    // syntax marker ranges (candidates to hide)
    public let line: Range<Int>         // enclosing line (for caret-aware reveal)
    public init(style: SpanStyle, content: Range<Int>, markers: [Range<Int>], line: Range<Int>) {
        self.style = style
        self.content = content
        self.markers = markers
        self.line = line
    }
}
```

- [ ] **Step 2: Write the failing checks** `Sources/Checks/TokenizerChecks.swift`

```swift
import MarkdownCore

func tokenizerChecks() {
    // Heading
    let h = InlineTokenizer.spans(in: "# Hi")
    expectEqual(h.count, 1, "one heading span")
    expectEqual(h.first?.style, .heading(1), "heading level 1")
    expectEqual(h.first?.content, 2..<4, "heading content after '# '")
    expectEqual(h.first?.markers, [0..<2], "heading marker is '# '")

    // Bold inside a line
    let b = InlineTokenizer.spans(in: "a **b** c")
    expectEqual(b.count, 1, "one bold span")
    expectEqual(b.first?.style, .bold, "bold style")
    expectEqual(b.first?.content, 4..<5, "bold content 'b'")
    expectEqual(b.first?.markers, [2..<4, 5..<7], "bold markers '**' x2")

    // Italic (single star), not confused with bold
    let i = InlineTokenizer.spans(in: "*i*")
    expectEqual(i.first?.style, .italic, "italic style")
    expectEqual(i.first?.content, 1..<2, "italic content")
    expectEqual(i.first?.markers, [0..<1, 2..<3], "italic markers '*' x2")

    // Inline code
    let c = InlineTokenizer.spans(in: "x `y` z")
    expectEqual(c.first?.style, .inlineCode, "inline code style")
    expectEqual(c.first?.content, 3..<4, "code content 'y'")
    expectEqual(c.first?.markers, [2..<3, 4..<5], "code backtick markers")

    // Multi-line: line ranges track the second line
    let m = InlineTokenizer.spans(in: "x\n**b**")
    expectEqual(m.count, 1, "one span on line 2")
    expectEqual(m.first?.content, 4..<5, "content offset accounts for first line + newline")
    expectEqual(m.first?.line, 2..<7, "line range is the second line")
}
```

- [ ] **Step 3: Register and run (red)**

Add `("Tokenizer", tokenizerChecks),` to the array in `Sources/Checks/main.swift`.
Run: `swift run Checks Tokenizer`
Expected: FAIL to build — `cannot find 'InlineTokenizer' in scope`.

- [ ] **Step 4: Implement the tokenizer** `Sources/MarkdownCore/InlineTokenizer.swift`

```swift
import Foundation

public enum InlineTokenizer {
    /// Parse a document into spans. Line-based: headings consume a whole line;
    /// otherwise bold/italic/inline-code are scanned within each line.
    public static func spans(in text: String) -> [MarkSpan] {
        var result: [MarkSpan] = []
        let ns = text as NSString
        let length = ns.length
        let newline = UInt16(UnicodeScalar("\n").value)

        var lineStart = 0
        while lineStart <= length {
            var lineEnd = lineStart
            while lineEnd < length && ns.character(at: lineEnd) != newline { lineEnd += 1 }
            let lineRange = lineStart..<lineEnd
            let lineText = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            parseLine(lineText as NSString, lineStart: lineStart, lineRange: lineRange, into: &result)
            if lineEnd == length { break }
            lineStart = lineEnd + 1
        }
        return result
    }

    private static let hash = UInt16(UnicodeScalar("#").value)
    private static let space = UInt16(UnicodeScalar(" ").value)
    private static let star = UInt16(UnicodeScalar("*").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)

    private static func parseLine(_ ns: NSString, lineStart: Int, lineRange: Range<Int>,
                                  into result: inout [MarkSpan]) {
        if let heading = headingSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(heading)
            return
        }
        let n = ns.length
        var i = 0
        while i < n {
            let c = ns.character(at: i)
            if c == backtick, let (span, next) = codeSpan(ns, from: i, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
            if c == star {
                if i + 1 < n && ns.character(at: i + 1) == star {
                    if let (span, next) = pairSpan(ns, marker: "**", style: .bold, from: i, lineStart: lineStart, lineRange: lineRange) {
                        result.append(span); i = next; continue
                    }
                } else if let (span, next) = pairSpan(ns, marker: "*", style: .italic, from: i, lineStart: lineStart, lineRange: lineRange) {
                    result.append(span); i = next; continue
                }
            }
            i += 1
        }
    }

    private static func headingSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> MarkSpan? {
        let n = ns.length
        var hashes = 0
        while hashes < n && ns.character(at: hashes) == hash { hashes += 1 }
        guard hashes >= 1, hashes <= 6, hashes < n, ns.character(at: hashes) == space else { return nil }
        let markerEnd = hashes + 1 // include the space
        let markers = [(lineStart)..<(lineStart + markerEnd)]
        let content = (lineStart + markerEnd)..<(lineStart + n)
        return MarkSpan(style: .heading(hashes), content: content, markers: markers, line: lineRange)
    }

    private static func codeSpan(_ ns: NSString, from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        var j = start + 1
        while j < n && ns.character(at: j) != backtick { j += 1 }
        guard j < n, j > start + 1 else { return nil }
        let span = MarkSpan(
            style: .inlineCode,
            content: (lineStart + start + 1)..<(lineStart + j),
            markers: [(lineStart + start)..<(lineStart + start + 1), (lineStart + j)..<(lineStart + j + 1)],
            line: lineRange)
        return (span, j + 1)
    }

    private static func pairSpan(_ ns: NSString, marker: String, style: SpanStyle,
                                 from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let m = marker as NSString
        let mlen = m.length
        let n = ns.length
        let contentStart = start + mlen
        var j = contentStart
        while j <= n - mlen {
            if matches(ns, at: j, marker: m) {
                if marker == "*" && j + 1 < n && ns.character(at: j + 1) == star {
                    j += 1; continue   // a '**' is not an italic close
                }
                guard j > contentStart else { return nil }
                let span = MarkSpan(
                    style: style,
                    content: (lineStart + contentStart)..<(lineStart + j),
                    markers: [(lineStart + start)..<(lineStart + start + mlen),
                              (lineStart + j)..<(lineStart + j + mlen)],
                    line: lineRange)
                return (span, j + mlen)
            }
            j += 1
        }
        return nil
    }

    private static func matches(_ ns: NSString, at i: Int, marker: NSString) -> Bool {
        guard i + marker.length <= ns.length else { return false }
        for k in 0..<marker.length where ns.character(at: i + k) != marker.character(at: k) { return false }
        return true
    }
}
```

- [ ] **Step 5: Run (green)**

Run: `swift run Checks Tokenizer`
Expected: `✅ All checks passed`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(core): inline tokenizer for headings/bold/italic/code"
```

---

## Task 2: MarkdownCore — DecorationSet + caret-aware Decorator

**Files:**
- Create: `Sources/MarkdownCore/Decorations.swift`
- Create: `Sources/Checks/DecorationChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing checks** `Sources/Checks/DecorationChecks.swift`

```swift
import MarkdownCore

func decorationChecks() {
    let spans = InlineTokenizer.spans(in: "**b**")   // bold on a single line 0..<5

    // Caret far away -> markers hidden, content styled bold
    let away = Decorator.decorations(spans: spans, selection: 100..<100)
    expectEqual(away.hidden, [0..<2, 3..<5], "markers hidden when caret off the line")
    expectEqual(away.styles.count, 1, "one style run")
    expectEqual(away.styles.first?.style, .bold, "bold style run")
    expectEqual(away.styles.first?.range, 0..<5, "style covers whole span incl markers")

    // Caret on the line -> markers revealed (not hidden)
    let on = Decorator.decorations(spans: spans, selection: 2..<2)
    expectEqual(on.hidden, [], "no markers hidden when caret is on the line")
    expectEqual(on.styles.first?.style, .bold, "content still styled on active line")
}
```

- [ ] **Step 2: Register and run (red)**

Add `("Decoration", decorationChecks),` to `Sources/Checks/main.swift`.
Run: `swift run Checks Decoration`
Expected: FAIL — `cannot find 'Decorator' in scope`.

- [ ] **Step 3: Implement decorations** `Sources/MarkdownCore/Decorations.swift`

```swift
import Foundation

public struct StyleRun: Equatable {
    public let range: Range<Int>
    public let style: SpanStyle
    public init(range: Range<Int>, style: SpanStyle) { self.range = range; self.style = style }
}

public struct DecorationSet: Equatable {
    public var styles: [StyleRun]
    public var hidden: [Range<Int>]
    public init(styles: [StyleRun] = [], hidden: [Range<Int>] = []) {
        self.styles = styles; self.hidden = hidden
    }
}

public enum Decorator {
    /// Pure: spans + caret/selection (UTF-16 offsets) -> style runs + marker ranges to hide.
    /// A span's markers are hidden unless the selection intersects the span's line.
    public static func decorations(spans: [MarkSpan], selection: Range<Int>) -> DecorationSet {
        var styles: [StyleRun] = []
        var hidden: [Range<Int>] = []
        for span in spans {
            let lowers = span.markers.map(\.lowerBound) + [span.content.lowerBound]
            let uppers = span.markers.map(\.upperBound) + [span.content.upperBound]
            let full = lowers.min()! ..< uppers.max()!
            styles.append(StyleRun(range: full, style: span.style))
            if !intersects(span.line, selection) {
                hidden.append(contentsOf: span.markers)
            }
        }
        return DecorationSet(styles: styles, hidden: hidden)
    }

    /// Inclusive overlap so a caret resting at a line boundary counts as "on the line".
    static func intersects(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
    }
}
```

- [ ] **Step 4: Run (green)**

Run: `swift run Checks Decoration`
Expected: `✅ All checks passed`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): caret-aware decoration model"
```

---

## Task 3: EditorEngine — apply DecorationSet to NSTextStorage

**Files:**
- Create: `Sources/EditorEngine/LivePreviewStyler.swift`
- Modify: `Package.swift` (EditorEngine gains a MarkdownCore dependency)

- [ ] **Step 1: Add MarkdownCore to EditorEngine in `Package.swift`**

Replace the `EditorEngine` target line with:

```swift
        .target(name: "EditorEngine", dependencies: ["MarkdownCore"]),
```

- [ ] **Step 2: Implement the styler** `Sources/EditorEngine/LivePreviewStyler.swift`

```swift
import AppKit
import MarkdownCore

/// Applies a DecorationSet to an NSTextStorage. The marker-hiding technique
/// (M1 spike, R1) collapses marker glyphs with a near-zero font + clear color.
public enum LivePreviewStyler {
    public static let baseFont = NSFont.systemFont(ofSize: 14)

    public static func apply(_ deco: DecorationSet, to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.textColor], range: full)
        for run in deco.styles {
            let r = clamp(run.range, length: storage.length)
            if r.length > 0 { storage.addAttributes(attributes(for: run.style), range: r) }
        }
        for hiddenRange in deco.hidden {
            let r = clamp(hiddenRange, length: storage.length)
            if r.length > 0 {
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01),
                                       .foregroundColor: NSColor.clear], range: r)
            }
        }
        storage.endEditing()
    }

    static func attributes(for style: SpanStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case .heading(let level):
            let sizes: [Int: CGFloat] = [1: 28, 2: 24, 3: 20, 4: 18, 5: 16, 6: 15]
            return [.font: NSFont.boldSystemFont(ofSize: sizes[level] ?? 15)]
        case .bold:
            return [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)]
        case .italic:
            return [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)]
        case .inlineCode:
            return [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .backgroundColor: NSColor.quaternaryLabelColor]
        }
    }

    static func clamp(_ r: Range<Int>, length: Int) -> NSRange {
        let lo = max(0, min(r.lowerBound, length))
        let hi = max(lo, min(r.upperBound, length))
        return NSRange(location: lo, length: hi - lo)
    }
}
```

- [ ] **Step 3: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(editor): apply decoration set to text storage"
```

---

## Task 4: EditorEngine — integrate Live Preview into the editor (marker-hiding spike, R1)

Wire tokenize → decorate → apply into `MarkdownEditorView`, recomputing on every text and selection change so markers reveal on the caret's line. This is the R1 spike; success is judged visually.

**Files:**
- Modify (overwrite): `Sources/EditorEngine/MarkdownEditorView.swift`

- [ ] **Step 1: Overwrite the editor view** `Sources/EditorEngine/MarkdownEditorView.swift`

```swift
import SwiftUI
import AppKit
import MarkdownCore

/// Markdown editing surface (TextKit 2) with incremental Live Preview:
/// inline styling + caret-aware marker hiding for headings/bold/italic/code.
public struct MarkdownEditorView: NSViewRepresentable {
    @Binding public var text: String
    public init(text: Binding<String>) { self._text = text }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = LivePreviewStyler.baseFont
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        context.coordinator.textView = textView
        context.coordinator.restyle()
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.restyle()
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        weak var textView: NSTextView?
        init(_ parent: MarkdownEditorView) { self.parent = parent }

        /// Recompute spans + decorations for the current text and caret, then apply.
        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let spans = InlineTokenizer.spans(in: storage.string)
            let sel = textView.selectedRange()
            let selection = sel.location..<(sel.location + sel.length)
            let deco = Decorator.decorations(spans: spans, selection: selection)
            LivePreviewStyler.apply(deco, to: storage)
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            restyle()
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            restyle()
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Launch and observe the spike (visual success criteria)**

Run: `swift run hanji`, open any folder with a `.md` file, select it, and type:

```
# Title
This is **bold** and *italic* and `code`.
```

Verify (this is the R1 success check):
1. `# ` renders the line large/bold; `**bold**` shows **bold**, `*italic*` shows *italic*, `` `code` `` shows monospaced/highlighted.
2. When the caret is **not** on a line, that line's markers (`#`, `**`, `*`, `` ` ``) are visually hidden.
3. When you click into / arrow onto a line, that line's markers reappear (raw markdown) so you can edit them.
4. Moving the caret line to line updates which markers are hidden, with no flicker that makes editing unusable.

Record the result in the commit message. **If marker glyphs leave a visible sliver or line-height jumps badly**, note it — the fallback is a custom `NSTextLayoutFragment` that omits marker glyphs (deferred follow-up); the attribute technique is the M1 baseline.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(editor): incremental Live Preview with caret-aware marker hiding

R1 spike: markers collapse via near-zero font + clear color; reveal on caret line."
```

---

## Task 5: Wrap — status update + full check suite

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the status section** in `README.md`

Replace the `## Status: M0 — walking skeleton` section's body with:

```markdown
## Status: M1 — Live Preview basics

- Opens a vault folder, lists `.md` files
- **Live Preview** for headings, bold, italic, inline code: inline styling with
  caret-aware marker hiding (markers reveal on the line you're editing)
- Atomic save; in-memory metadata index (titles)
- Compile-time plugin SDK + bundled Word Count plugin
```

- [ ] **Step 2: Run the full check suite**

Run: `swift run Checks`
Expected: `✅ All checks passed` covering groups TitleExtractor, Vault, MetadataIndex, AppState, PluginLoop, WordCounter, Tokenizer, Decoration — no failures.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: mark M1 (Live Preview basics) status"
```

---

## Self-Review

**Spec coverage (M1 in spec §10 + §5.3):**
- "마커 숨김 스파이크" (R1) → Task 4 Step 3 (visual spike with explicit success criteria + fallback note). ✓
- "Live Preview 기초: heading·bold/italic·inline code" → Task 1 (tokenizer for exactly these) + Task 3/4 (styling + apply). ✓
- §5.3 "순수 함수 decorations(tokens, selection) → DecorationSet ... NSTextView와 분리 → 골든 테스트" → Task 2 (`Decorator.decorations`, pure, checked). ✓
- §5.3 "커서 인지 노출: 커서가 노드의 enclosing 줄/블록 안이면 마커 노출" → Task 2 (line-intersection rule) + Task 4 (selection-change restyle). ✓
- §5.3 "DecorationSet을 NSTextLayoutManager에 적용" → Task 3 (`LivePreviewStyler` via NSTextStorage attributes; TextKit 2 NSTextView). ✓

**Placeholder scan:** No "TBD"/"add error handling"/uncoded steps. Every code step is complete. The fallback (custom layout fragment) is explicitly a deferred follow-up, not an M1 step. ✓

**Type consistency:** `SpanStyle` (`.heading(Int)`/`.bold`/`.italic`/`.inlineCode`), `MarkSpan(style:content:markers:line:)`, `InlineTokenizer.spans(in:)`, `StyleRun(range:style:)`, `DecorationSet(styles:hidden:)`, `Decorator.decorations(spans:selection:)`, `LivePreviewStyler.apply(_:to:)`/`baseFont`, `MarkdownEditorView(text:)` — names/signatures consistent across Tasks 1–4. All offsets are UTF-16. ✓

**Scope:** Headings/bold/italic/inline code only (matches spec M1). Lists/tasks/quotes/callouts/code-blocks/images/frontmatter are M2. Viewport-scoped incremental re-tokenization is a later optimization (M1 re-tokenizes the whole document per change — fine for typical note sizes). ✓
