# Strikethrough, Highlight, Footnotes, Math — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `~~strike~~`, `==highlight==`, footnotes and LaTeX math in Live
Preview and reading mode, per `2026-10-24-hanji-inline-syntax-design.md`.

**Architecture:** five new `SpanStyle`s from `InlineTokenizer`, styled by
`LivePreviewStyler` and table cells; `$$` becomes a `Fence` (info `math`) so
block math rides the code-block path into a new KaTeX `MathRenderer`, which
shares a WKWebView host with mermaid.

**Tech Stack:** Swift 6.1, SwiftUI + AppKit/TextKit 2, WebKit; checks via
`swift run Checks <Group>` (no XCTest).

## Global Constraints

- macOS 14+; no new package dependencies.
- KaTeX `0.18.11` from `https://cdn.jsdelivr.net/npm/katex@0.18.11/dist/`:
  - `katex.min.js` `sha384-vaygNa7Kw+54Zb42f7K+4bfhZp4vWSHPJMKwd7nVmlgSvRADUrCRRdCpc1/CJwO+`
  - `katex.min.css` `sha384-NJ/T2p1ROqNH3Yico+wdWm5Rv2rlinAOvV25Sw1zLOaxg8yLDPVv8GGAUccx50rh`
- Note text reaches a web page only as a JS string literal (`<` escaped).
- Editor perf limits unchanged (keystroke ≤ 60 ms debug at 4,000 lines; ≤ 2 % restyled).
- Commits only after 18:00 KST; never pushed without being asked.

---

### Task 1: Strikethrough and highlight

**Files:**
- Modify: `Sources/MarkdownCore/MarkSpan.swift` (SpanStyle)
- Modify: `Sources/MarkdownCore/InlineTokenizer.swift` (`scanInline`, `pairSpan`)
- Modify: `Sources/EditorEngine/LivePreviewStyler.swift` (`attributes(for:)`)
- Modify: `Sources/MarkdownCore/TableParser.swift` (`CellRun.Style`, `runs`)
- Modify: `Sources/EditorEngine/TableWidget.swift` (`attributed`)
- Create: `Sources/Checks/InlineSyntaxChecks.swift`; register in `Sources/Checks/main.swift`

**Interfaces:**
- Produces: `SpanStyle.strikethrough`, `.highlight`, `.math`, `.footnoteRef`,
  `.footnoteDef` (all five added here so later tasks only fill them in);
  `CellRun.Style.strike` (32), `.highlight` (64), `.math` (128).

- [ ] **Step 1: Failing checks** — `InlineSyntaxChecks.swift`:

```swift
import AppKit
import MarkdownCore
import EditorEngine

private func styles(_ text: String) -> [SpanStyle] { InlineTokenizer.spans(in: text).map(\.style) }

func inlineSyntaxChecks() {
    let s = InlineTokenizer.spans(in: "a ~~gone~~ b")
    expectEqual(s.first?.style, .strikethrough, "~~x~~ is struck")
    expectEqual(s.first?.content, 4..<8, "struck content 'gone'")
    expectEqual(s.first?.markers, [2..<4, 8..<10], "markers are the two ~~")
    let h = InlineTokenizer.spans(in: "==hi==")
    expectEqual(h.first?.style, .highlight, "==x== is highlighted")
    expectEqual(h.first?.markers, [0..<2, 4..<6], "markers are the two ==")
    expectEqual(styles("if a == b == c"), [], "== around spaces is not a highlight")
    expectEqual(styles("~~ a ~~"), [], "~~ around spaces is not struck")
    expectEqual(styles("~~~\ncode\n~~~"), [.codeBlock, .codeBlock, .codeBlock], "~~~ still opens a fence")
    expectEqual(styles("`~~no~~`"), [.inlineCode], "no strike inside inline code")

    let runs = TableParser.runs("~~x~~ ==y==")
    expectEqual(runs.map(\.text), ["x", " ", "y"], "cell markers dropped")
    expect(runs[0].style.contains(.strike) && runs[2].style.contains(.highlight), "cell runs carry strike/highlight")
}

func inlineSyntaxStylerChecks() {
    let text = "~~a~~ ==b==\nnext"
    let storage = NSTextStorage(string: text)
    let end = (text as NSString).length
    LivePreviewStyler.apply(Decorator.decorations(spans: InlineTokenizer.spans(in: text), selection: end..<end), to: storage)
    expectEqual(storage.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) as? Int,
                NSUnderlineStyle.single.rawValue, "struck text has a strikethrough")
    expect(storage.attribute(.backgroundColor, at: 8, effectiveRange: nil) != nil, "highlighted text has a wash")
    expect(((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 99) < 1,
           "~~ hidden off the caret's line")
}
```

Register in `main.swift` next to `("Styler", stylerChecks)`:

```swift
    ("InlineSyntax", inlineSyntaxChecks),
    ("InlineSyntaxStyler", inlineSyntaxStylerChecks),
```

- [ ] **Step 2: Run** `swift run Checks InlineSyntax InlineSyntaxStyler` — expect a compile error (`.strikethrough` unknown).

- [ ] **Step 3: Implement.** `MarkSpan.swift`, after `case tag`:

```swift
    case strikethrough // `~~text~~`
    case highlight     // `==text==`
    case math          // `$x$` — styled, not rendered (a `$$` block is a fence)
    case footnoteRef   // `[^id]` — the id shows raised
    case footnoteDef   // `[^id]:` at a line's start — the label stays visible
```

`InlineTokenizer`: constants `tilde` (`~`), `equals` (`=`), `dollar`
(`$`), `backslash`, `caret` (`^`), `colon`, `tab` alongside the others.
`pairSpan` gains `tight: Bool = false`; when tight, a close is accepted only if
the content neither starts nor ends with a space/tab (else `return nil`).
In `scanInline`, before the `star` branch:

```swift
            if c == tilde, i + 1 < n, ns.character(at: i + 1) == tilde,
               let (span, next) = pairSpan(ns, marker: "~~", style: .strikethrough, tight: true,
                                           from: i, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
            if c == equals, i + 1 < n, ns.character(at: i + 1) == equals,
               let (span, next) = pairSpan(ns, marker: "==", style: .highlight, tight: true,
                                           from: i, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
```

`LivePreviewStyler.attributes(for:)`:

```swift
        case .strikethrough:
            return [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor]
        case .highlight:
            return [.backgroundColor: highlightColor]
        case .math, .footnoteRef, .footnoteDef:
            return [:]   // Tasks 2 and 3
```

with

```swift
    /// `==highlight==`: a marker-pen yellow, fainter on a dark background.
    static let highlightColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.systemYellow.withAlphaComponent(dark ? 0.3 : 0.45)
    }
```

`TableParser`: add the three `CellRun.Style` constants; in `runs`,
`case .strikethrough: style = .strike`, `case .highlight: style = .highlight`,
`case .math: style = .math`. `TableWidget.attributed`:

```swift
            if run.style.contains(.strike) {
                piece.strikethroughStyle = .single
                piece.foregroundColor = Color(nsColor: .secondaryLabelColor)
            }
            if run.style.contains(.highlight) { piece.backgroundColor = Color(nsColor: LivePreviewStyler.highlightColor) }
```

(`highlightColor` is `static`, internal to EditorEngine — `TableWidget` is in
the same module.)

- [ ] **Step 4: Run** `swift run Checks InlineSyntax InlineSyntaxStyler Tokenizer Styler TableParser` — all pass.
- [ ] **Step 5: Commit** `feat(editor): ~~strikethrough~~ and ==highlight==`

### Task 2: Inline math

**Files:** `InlineTokenizer.swift` (`mathSpan`), `LivePreviewStyler.swift`
(trait style), `TableWidget.swift` (`font(for:)`), `InlineSyntaxChecks.swift`.

**Interfaces:** Consumes `SpanStyle.math`, `CellRun.Style.math`. Produces
`LivePreviewStyler.mathFont(ofSize:) -> NSFont`, `LivePreviewStyler.mathColor`.

- [ ] **Step 1: Failing checks** — append to `inlineSyntaxChecks()`:

```swift
    let m = InlineTokenizer.spans(in: "area $\\pi r^2$ here")
    expectEqual(m.first?.style, .math, "$x$ is math")
    expectEqual(m.first?.content, 6..<13, "math content")
    expectEqual(m.first?.markers, [5..<6, 13..<14], "markers are the two $")
    expectEqual(styles("costs $5 and $10"), [], "$5 and $10 is money, not math")
    expectEqual(styles("$ x$"), [], "no space after the opening $")
    expectEqual(styles("$x $"), [], "no space before the closing $")
    expectEqual(styles("\\$x$"), [], "an escaped $ opens nothing")
    expectEqual(styles("`$x$`"), [.inlineCode], "no math in inline code")
    let d = InlineTokenizer.spans(in: "$$e=mc^2$$")
    expectEqual(d.first?.style, .math, "$$x$$ on one line is inline math")
    expectEqual(d.first?.markers, [0..<2, 8..<10], "its markers are the two $$")
```

and to `inlineSyntaxStylerChecks()`:

```swift
    let mt = "x $y$\nz"
    let ms = NSTextStorage(string: mt)
    LivePreviewStyler.apply(Decorator.decorations(spans: InlineTokenizer.spans(in: mt), selection: 7..<7), to: ms)
    let mf = ms.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
    expect(mf?.fontName.hasPrefix("STIX") == true || mf?.fontDescriptor.symbolicTraits.contains(.italic) == true,
           "math is set in STIX italic")
```

- [ ] **Step 2: Run** `swift run Checks InlineSyntax InlineSyntaxStyler` — math checks fail.
- [ ] **Step 3: Implement.** In `scanInline`, after the `backtick` branch:

```swift
            if c == backslash, i + 1 < n, ns.character(at: i + 1) == dollar { i += 2; continue }
            if c == dollar, let (span, next) = mathSpan(ns, from: i, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
```

```swift
    /// `$x$` (or `$$x$$` written on one line): the opening delimiter before a
    /// non-blank, the closing one after a non-blank and — for `$` — not before a
    /// digit, so `$5 and $10` stays text. `\$` is never a delimiter.
    private static func mathSpan(_ ns: NSString, from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        let mlen = start + 1 < n && ns.character(at: start + 1) == dollar ? 2 : 1
        let contentStart = start + mlen
        func blank(_ k: Int) -> Bool { ns.character(at: k) == space || ns.character(at: k) == tab }
        guard contentStart < n, !blank(contentStart), ns.character(at: contentStart) != dollar else { return nil }
        var j = contentStart
        while j < n {
            let c = ns.character(at: j)
            if c == backslash { j += 2; continue }
            if c == dollar {
                guard mlen == 1 || (j + 1 < n && ns.character(at: j + 1) == dollar) else { j += 1; continue }
                guard !blank(j - 1) else { return nil }
                let after = j + mlen
                if mlen == 1, after < n, ns.character(at: after) >= zero, ns.character(at: after) <= nine { return nil }
                let span = MarkSpan(style: .math,
                                    content: (lineStart + contentStart)..<(lineStart + j),
                                    markers: [(lineStart + start)..<(lineStart + contentStart),
                                              (lineStart + j)..<(lineStart + after)],
                                    line: lineRange)
                return (span, after)
            }
            j += 1
        }
        return nil
    }
```

`LivePreviewStyler`: `.math` joins `isTraitStyle`; in `applyTrait`
`case .math: storage.addAttributes([.font: mathFont(ofSize: current.pointSize), .foregroundColor: mathColor], range: sub)`;
`attributes(for: .math)` returns `[.font: mathFont(ofSize: baseFontSize), .foregroundColor: mathColor]`;

```swift
    /// Inline math is set, not rendered: STIX (shipped with macOS) italic.
    static func mathFont(ofSize size: CGFloat) -> NSFont {
        NSFont(name: "STIXGeneral-Italic", size: size)
            ?? NSFontManager.shared.convert(EditorFonts.text(textFont, size: size), toHaveTrait: .italicFontMask)
    }
    static let mathColor = NSColor.systemIndigo
```

`TableWidget.font(for:)`: `if style.contains(.math) { return LivePreviewStyler.mathFont(ofSize: base.pointSize) }` after the code case.

- [ ] **Step 4: Run** `swift run Checks InlineSyntax InlineSyntaxStyler Tokenizer TokenizerCache Styler` — pass.
- [ ] **Step 5: Commit** `feat(editor): inline $math$`

### Task 3: Footnotes

**Files:** `InlineTokenizer.swift` (`footnoteRefSpan`, `footnoteDefSpan`),
Create `Sources/MarkdownCore/Footnotes.swift`, `LivePreviewStyler.swift`,
`MarkdownEditorView.swift` (`handleClick`), `InlineSyntaxChecks.swift`.

**Interfaces:** Produces `Footnotes.jumpTarget(at: Int, in: String) -> Int?`.
Consumes `Coordinator.scrollLineToTop(at:)`.

- [ ] **Step 1: Failing checks** — append to `inlineSyntaxChecks()`, and add a group:

```swift
    let r = InlineTokenizer.spans(in: "Fact[^1] here")
    expectEqual(r.first?.style, .footnoteRef, "[^1] mid-line is a reference")
    expectEqual(r.first?.content, 6..<7, "the id shows")
    expectEqual(r.first?.markers, [4..<6, 7..<8], "[^ and ] hide")
    let def = InlineTokenizer.spans(in: "[^1]: The note **b**")
    expectEqual(def.first?.style, .footnoteDef, "[^1]: at line start is a definition")
    expectEqual(def.first?.content, 0..<5, "the label is the definition span")
    expectEqual(def.first?.markers, [], "the label stays visible")
    expect(def.contains { $0.style == .bold }, "the definition's text is styled inline")
    expect(LinkParser.links(in: "x[^1] and [^1]: y").isEmpty, "footnotes are not links")
    expectEqual(styles("[^ 1]"), [], "no blanks in an id")
```

```swift
func footnoteChecks() {
    let text = "One[^a] two[^b].\n\n[^a]: First.\n[^b]: Second."
    let ns = text as NSString
    let defA = ns.range(of: "[^a]:").location, defB = ns.range(of: "[^b]:").location
    expectEqual(Footnotes.jumpTarget(at: 5, in: text), defA, "a reference jumps to its definition line")
    expectEqual(Footnotes.jumpTarget(at: 13, in: text), defB, "each reference finds its own definition")
    expectEqual(Footnotes.jumpTarget(at: defA + 1, in: text), 3, "a definition's label jumps back to the first reference")
    expectEqual(Footnotes.jumpTarget(at: 0, in: text), nil, "plain text jumps nowhere")
    expectEqual(Footnotes.jumpTarget(at: 4, in: "x[^z] y"), nil, "a reference with no definition jumps nowhere")
}
```

Register `("Footnotes", footnoteChecks),`.

- [ ] **Step 2: Run** `swift run Checks InlineSyntax Footnotes` — fail (`Footnotes` unknown).
- [ ] **Step 3: Implement.** `scanInline`, before the `openBracket` branch:

```swift
            if c == openBracket, let (span, next) = footnoteRefSpan(ns, from: i, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
```

```swift
    /// The end of a footnote label `[^id]` starting at `start` (the index of its
    /// `]`), or nil: an id is one or more characters, none blank or a bracket.
    private static func footnoteLabelEnd(_ ns: NSString, from start: Int) -> Int? {
        let n = ns.length
        guard start + 2 < n, ns.character(at: start) == openBracket, ns.character(at: start + 1) == caret else { return nil }
        var j = start + 2
        while j < n {
            let c = ns.character(at: j)
            if c == closeBracket { return j > start + 2 ? j : nil }
            if c == space || c == tab || c == openBracket { return nil }
            j += 1
        }
        return nil
    }

    private static func footnoteRefSpan(_ ns: NSString, from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        guard let close = footnoteLabelEnd(ns, from: start) else { return nil }
        let span = MarkSpan(style: .footnoteRef, content: (lineStart + start + 2)..<(lineStart + close),
                            markers: [(lineStart + start)..<(lineStart + start + 2), (lineStart + close)..<(lineStart + close + 1)],
                            line: lineRange)
        return (span, close + 1)
    }

    /// `[^id]:` opening a line: the definition's label, kept visible.
    private static func footnoteDefSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        guard let close = footnoteLabelEnd(ns, from: 0), close + 1 < ns.length, ns.character(at: close + 1) == colon else { return nil }
        return (MarkSpan(style: .footnoteDef, content: lineStart..<(lineStart + close + 2), markers: [], line: lineRange), close + 2)
    }
```

At the top of `parseLine`:

```swift
        if let (def, contentOffset) = footnoteDefSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(def)
            scanInline(ns, from: contentOffset, lineStart: lineStart, lineRange: lineRange, into: &result)
            return
        }
```

`Footnotes.swift`:

```swift
import Foundation

/// Where a click on a footnote goes: from a reference `[^id]` to the line
/// defining it, and from a definition's `[^id]:` back to the first reference.
public enum Footnotes {
    public static func jumpTarget(at offset: Int, in text: String) -> Int? {
        let ns = text as NSString
        let notes = InlineTokenizer.spans(in: text).filter { $0.style == .footnoteRef || $0.style == .footnoteDef }
        func whole(_ s: MarkSpan) -> Range<Int> {
            s.style == .footnoteRef ? s.markers[0].lowerBound..<s.markers[1].upperBound : s.content
        }
        func id(_ s: MarkSpan) -> String {
            let r = s.style == .footnoteRef ? s.content : (s.content.lowerBound + 2)..<(s.content.upperBound - 2)
            return ns.substring(with: NSRange(location: r.lowerBound, length: r.count))
        }
        guard let hit = notes.first(where: { whole($0).contains(offset) }) else { return nil }
        let key = id(hit)
        let other: SpanStyle = hit.style == .footnoteRef ? .footnoteDef : .footnoteRef
        return notes.first { $0.style == other && id($0) == key }.map { whole($0).lowerBound }
    }
}
```

`LivePreviewStyler.attributes(for:)` replaces the Task 1 placeholder case:

```swift
        case .footnoteRef:
            // Raised and small, like a printed footnote mark.
            return [.font: EditorFonts.text(textFont, size: (baseFontSize * 0.72).rounded()),
                    .baselineOffset: (baseFontSize * 0.35).rounded(),
                    .foregroundColor: NSColor.controlAccentColor]
        case .footnoteDef:
            return [.foregroundColor: NSColor.secondaryLabelColor]
```

`handleClick`, after the checkbox toggle:

```swift
            // A footnote mark jumps to its definition, and a definition's label back.
            if let textView, let target = Footnotes.jumpTarget(at: index, in: textView.string) {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: target, length: 0))
                scrollLineToTop(at: target)
                return true
            }
```

- [ ] **Step 4: Run** `swift run Checks InlineSyntax InlineSyntaxStyler Footnotes Tokenizer LinkParser LinkTokenizer` — pass.
- [ ] **Step 5: Commit** `feat(editor): footnotes — raised marks, click to the definition and back`

### Task 4: `$$` math fences

**Files:** `Sources/MarkdownCore/Fence.swift`, `Sources/MarkdownCore/CodeHighlighter.swift`,
`Sources/Checks/InlineSyntaxChecks.swift`, `Sources/Checks/TokenizerCacheChecks.swift` (vocabulary).

**Interfaces:** Produces `CodeBlockRegion.language == "math"` for `$$` blocks.

- [ ] **Step 1: Failing checks** — new group:

```swift
func mathFenceChecks() {
    let text = "a\n$$\nx^2 #notatag\n$$\nb"
    let regions = CodeBlockParser.regions(in: text)
    expectEqual(regions.map(\.language), ["math"], "a $$ block is a math region")
    expectEqual(regions.first.map { $0.bodyText(in: text as NSString) }, "x^2 #notatag", "its body is the formula")
    expect(Tags.occurrences(in: text).isEmpty, "no tags inside math")
    expectEqual(styles("$$\n**x**\n$$"), [.codeBlock, .codeBlock, .codeBlock], "math lines aren't markdown")
    expectEqual(CodeBlockParser.regions(in: "```math\nx\n```").map(\.language), ["math"], "```math is math too")
    expectEqual(CodeBlockParser.regions(in: "$$\nx\n").count, 0, "an unclosed $$ renders nothing")
    expectEqual(CodeBlockParser.codeRanges(in: "$$\nx\n").count, 1, "but is code while being typed")
    expectEqual(CodeBlockParser.regions(in: "$$ \nx\n$$\r").count, 1, "trailing blanks and CR are fine")
    expect(Fence.opening("$$$") == nil && Fence.opening("$$ x") == nil, "only a bare $$ is a fence")
    expect(CodeHighlighter.tokens(in: "x = 2 + \"y\"", language: "math").isEmpty, "math source isn't syntax-colored")
}
```

Register `("MathFence", mathFenceChecks),`. In `TokenizerCacheChecks.swift`,
add `"$$"` and `"$x$ ~~s~~ ==h== [^1]"` to `lines` and `"$"` to the typed
characters (line 36 array) so the incremental/full comparison covers them.

- [ ] **Step 2: Run** `swift run Checks MathFence` — fail.
- [ ] **Step 3: Implement.** `Fence.parse`, replacing the marker guard:

```swift
        guard let marker = chars.first, marker == "`" || marker == "~" || marker == "$" else { return nil }
        // `$$` alone on its line opens and closes a math block (rendered under the
        // language `math`, like GitHub's ```math).
        if marker == "$" {
            guard chars.trimmingCharacters(in: .whitespaces) == "$$" else { return nil }
            return Fence(marker: "$", length: 2, info: "math", indent: indent)
        }
```

`isClosed(by:)`: `return other.marker == marker && other.length >= length && (other.info.isEmpty || marker == "$")`.
Update the `opening` doc comment (“3+ backticks or tildes, or a bare `$$`”).
`CodeHighlighter.tokens`: `guard language != "math" else { return [] }` at the top.

- [ ] **Step 4: Run** `swift run Checks MathFence NestedFence CodeBlockRegion CodeBlockTokenizer TokenizerCache ParserEquivalence InlineSyntax ReadingMode` — pass.
- [ ] **Step 5: Commit** `feat(editor): $$ blocks are math fences`

### Task 5: KaTeX renderer

**Files:**
- Create: `Sources/CoreRenderers/WebBlockView.swift` (the WKWebView host, moved out of `MermaidRenderer.swift`)
- Modify: `Sources/CoreRenderers/MermaidRenderer.swift` (use `WebBlockView`)
- Create: `Sources/CoreRenderers/MathRenderer.swift` (`MathRenderer`, `MathPage`)
- Modify: `Sources/HanjiApp/HanjiApp.swift:84` (register)
- Create: `Sources/Checks/MathPageChecks.swift`; register `("MathPage", mathPageChecks)`
- Modify: `THIRD_PARTY_NOTICES.md`

**Interfaces:**
- Produces: `struct WebBlockView: View { init(minHeight: CGFloat, maxHeight: CGFloat, page: @escaping (_ nonce: String) -> String, allowsNavigation: @escaping (URL?, WKNavigationType) -> Bool, baseURL: URL) }`;
  `MathPage.html(source: String, nonce: String) -> String`, `MathPage.baseURL`, `MathPage.allowsNavigation(to:type:)`.

- [ ] **Step 1: Failing checks** — `MathPageChecks.swift`, mirroring `MermaidPageChecks`:

```swift
import Foundation
import WebKit
import CoreRenderers

/// A formula comes from the note, so it reaches KaTeX as data only.
func mathPageChecks() {
    let nonce = "N0nce"
    func page(_ source: String) -> String { MathPage.html(source: source, nonce: nonce) }
    expect(!page("</script><script>alert(1)</script>").contains("<script>alert"), "a closing script tag can't break out")
    expect(!page("<img src=x onerror=alert(1)>").contains("<img"), "note text never lands as an HTML tag")
    let plain = page("e^{i\\pi}+1=0")
    expect(plain.contains("\"e^{i\\\\pi}+1=0\""), "the formula is passed as a string literal")
    expect(plain.contains("default-src 'none'"), "a CSP denies everything not listed")
    expect(plain.contains("'nonce-\(nonce)'"), "only nonce-tagged inline script runs")
    expect(!plain.contains("connect-src"), "no fetch/XHR destinations")
    expect(plain.contains("katex@0.18.11/"), "KaTeX is pinned to an exact version")
    expect(plain.contains("sha384-vaygNa7Kw+54Zb42f7K+4bfhZp4vWSHPJMKwd7nVmlgSvRADUrCRRdCpc1/CJwO+"), "the script is integrity-checked")
    expect(plain.contains("sha384-NJ/T2p1ROqNH3Yico+wdWm5Rv2rlinAOvV25Sw1zLOaxg8yLDPVv8GGAUccx50rh"), "the stylesheet is integrity-checked")
    expect(plain.contains("trust: false"), "KaTeX may not run \\href / \\url / html commands")
    expect(MathPage.allowsNavigation(to: MathPage.baseURL, type: .other), "the page itself loads")
    expect(!MathPage.allowsNavigation(to: URL(string: "https://evil.example/"), type: .linkActivated), "links don't navigate")
}
```

- [ ] **Step 2: Run** `swift run Checks MathPage` — fail (`MathPage` unknown).
- [ ] **Step 3: Implement.** Move `MermaidHeight` / `MermaidView` / `MermaidWeb`
  into `WebBlockView.swift` as `WebBlockView` (state object, `NSViewRepresentable`,
  coordinator), parameterised by `page`, `allowsNavigation`, `baseURL` and the
  height clamp (mermaid keeps 40…600; math uses 24…400). Keep the comments
  (non-persistent data store, main-frame-only navigation, posting
  `.hanjiWidgetDidResize`). `MermaidRenderer.makeView` becomes:

```swift
        AnyView(WebBlockView(minHeight: 40, maxHeight: 600,
                             page: { MermaidPage.html(source: source, nonce: $0) },
                             allowsNavigation: MermaidPage.allowsNavigation, baseURL: MermaidPage.baseURL))
```

`MathRenderer.swift`:

```swift
import SwiftUI
import WebKit
import ExtensionSDK

/// Renders a `$$` (or ```math) block as a display formula with KaTeX, loaded
/// pinned and integrity-checked from a CDN — like mermaid, it needs network access.
public struct MathRenderer: CodeBlockRenderer {
    public let language = "math"
    public init() {}
    public func makeView(source: String) -> AnyView {
        AnyView(WebBlockView(minHeight: 24, maxHeight: 400,
                             page: { MathPage.html(source: source, nonce: $0) },
                             allowsNavigation: MathPage.allowsNavigation, baseURL: MathPage.baseURL))
    }
}

/// The page a math block renders in. Same rules as `MermaidPage`: the formula
/// arrives as a string literal, a CSP admits only the pinned KaTeX build and
/// this page's nonce-tagged script, and nothing may be fetched or navigated to.
/// KaTeX runs with `trust: false`, so `\href`, `\url` and HTML commands render
/// as errors rather than links.
public enum MathPage {
    public static let baseURL = URL(string: "https://hanji.invalid/")!
    static let base = "https://cdn.jsdelivr.net/npm/katex@0.18.11/dist/"
    static let scriptIntegrity = "sha384-vaygNa7Kw+54Zb42f7K+4bfhZp4vWSHPJMKwd7nVmlgSvRADUrCRRdCpc1/CJwO+"
    static let styleIntegrity = "sha384-NJ/T2p1ROqNH3Yico+wdWm5Rv2rlinAOvV25Sw1zLOaxg8yLDPVv8GGAUccx50rh"

    public static func html(source: String, nonce: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; \
        script-src 'nonce-\(nonce)' \(base); style-src 'unsafe-inline' \(base); font-src \(base); img-src data:">
        <link rel="stylesheet" href="\(base)katex.min.css" integrity="\(styleIntegrity)" crossorigin="anonymous">
        <script nonce="\(nonce)" src="\(base)katex.min.js" integrity="\(scriptIntegrity)" crossorigin="anonymous"></script>
        <style>html,body{margin:0;padding:0;background:transparent}#m{display:inline-block;min-width:100%;font-size:1.1em}\
        .katex-display{margin:4px 0}.err{color:#d33;font:12px ui-monospace,monospace;white-space:pre-wrap}</style>
        </head><body><div id="m"></div>
        <script nonce="\(nonce)">
        function report(){
          var el = document.getElementById('m');
          var h = el ? el.getBoundingClientRect().height : 0;
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mkHeight)
            window.webkit.messageHandlers.mkHeight.postMessage(Math.ceil(h));
        }
        var src = \(PageText.jsStringLiteral(source));
        var el = document.getElementById('m');
        if (typeof katex === 'undefined') { el.className = 'err'; el.textContent = src + '\\n(KaTeX could not load — offline?)'; }
        else {
          try { katex.render(src, el, { displayMode: true, throwOnError: true, trust: false, strict: 'ignore', maxExpand: 1000, maxSize: 50 }); }
          catch (e) { el.className = 'err'; el.textContent = (e && e.message) ? e.message : String(e); }
        }
        requestAnimationFrame(function(){ requestAnimationFrame(report); });
        </script>
        </body></html>
        """
    }

    public static func allowsNavigation(to url: URL?, type: WKNavigationType) -> Bool {
        type == .other && url == baseURL
    }
}
```

Move `jsStringLiteral` out of `MermaidPage` into `enum PageText` in
`WebBlockView.swift` (internal), used by both pages. Background: match
whatever `MermaidWeb` does today (if it draws a white page in dark mode,
set `web.setValue(false, forKey: "drawsBackground")` in `WebBlockView` for
both). Register in `HanjiApp.swift` after mermaid:
`h.renderers.register(MathRenderer())`. `THIRD_PARTY_NOTICES.md`: a `## KaTeX`
section like `## Mermaid` (not bundled; `katex@0.18.11` from jsDelivr,
pinned, integrity-checked; MIT).

- [ ] **Step 4: Run** `swift build && swift run Checks MathPage MermaidPage RendererRegistry` — pass.
- [ ] **Step 5: Commit** `feat(renderers): $$ math blocks render with KaTeX`

### Task 6: Docs and a look at the app

**Files:** `README.md` (Features › Editing), `CHANGELOG.md` (`[Unreleased]` › Editor).

- [ ] **Step 1:** README Editing bullets: `~~strikethrough~~` / `==highlight==`;
  footnotes (raised marks, click to the definition and back); math (`$…$` set
  in STIX italic, `$$` blocks rendered with KaTeX — network needed, like
  mermaid). CHANGELOG: one line each.
- [ ] **Step 2:** `swift run Checks --changed --slow` — all affected groups pass,
  including `EditorPerf` / `IncrementalRestyle`.
- [ ] **Step 3:** Launch the debug build on a scratch vault holding one note
  with every construct (`HANJI_OPEN_VAULT=…`), screenshot Live Preview and
  reading mode (⌘E), check: struck/highlighted text, raised footnote marks,
  STIX math, a rendered `$$` formula, a KaTeX error shown in red. Kill the
  launched app by PID and confirm none remain.
- [ ] **Step 4: Commit** `docs: strikethrough, highlight, footnotes and math`
