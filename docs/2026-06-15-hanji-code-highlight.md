# Code-Block Syntax Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Color keywords/types/strings/comments/numbers inside fenced code blocks via a pure, grammar-configured tokenizer, applied as foreground colors over the existing mono slab.

**Architecture:** A pure `CodeHighlighter` in MarkdownCore scans a code block's text with one char-by-char scanner parameterized by a per-language `LanguageGrammar` (keywords, comment markers, string delimiters), with a C-like fallback for unknown languages. The editor's `restyle()` runs it over each `CodeBlockRegion.body` and adds foreground colors from a `LivePreviewStyler` palette — the mono font and slab background are untouched.

**Tech Stack:** Swift 5.10/SPM, AppKit (NSColor/NSTextStorage), custom Checks runner. No new dependencies.

**Spec:** `docs/2026-06-15-hanji-code-highlight-design.md`

**Conventions:** TDD via `Sources/Checks` (`expect`/`expectEqual`, register in `main.swift`, `swift run Checks <Group>`); commits to main, real timestamps, trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Tokens are **UTF-16 ranges** (the scanner indexes `NSString` so offsets map straight onto `NSTextStorage`). READ files before editing.

---

## File structure

- Create `Sources/MarkdownCore/CodeHighlighter.swift` — `TokenKind`, `Token`, `LanguageGrammar`, grammar table + alias resolution, the scanner.
- Modify `Sources/EditorEngine/LivePreviewStyler.swift` — `codeColor(_:)` palette + `highlightCode(_:in:)`.
- Modify `Sources/EditorEngine/MarkdownEditorView.swift` — call `highlightCode` from `restyle()`.
- Create `Sources/Checks/CodeHighlighterChecks.swift` — scanner TDD.
- Modify `Sources/Checks/CodeBlockStylerChecks.swift` — integration assertion (foreground color on a code token).
- Modify `Sources/Checks/main.swift` — register the new group.
- Modify `README.md`.

---

## Task 1: CodeHighlighter (pure)

**Files:**
- Create: `Sources/MarkdownCore/CodeHighlighter.swift`
- Create: `Sources/Checks/CodeHighlighterChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — `Sources/Checks/CodeHighlighterChecks.swift`

```swift
import Foundation
import MarkdownCore

func codeHighlighterChecks() {
    func toks(_ code: String, _ lang: String) -> [(CodeHighlighter.TokenKind, String)] {
        let ns = code as NSString
        return CodeHighlighter.tokens(in: code, language: lang).map { t in
            (t.kind, ns.substring(with: NSRange(location: t.range.lowerBound,
                                                length: t.range.upperBound - t.range.lowerBound)))
        }
    }
    func has(_ ts: [(CodeHighlighter.TokenKind, String)], _ kind: CodeHighlighter.TokenKind, _ text: String) -> Bool {
        ts.contains { $0.0 == kind && $0.1 == text }
    }

    // Swift: keyword, number, line comment.
    let sw = toks("func f() { let x = 1 } // note", "swift")
    expect(has(sw, .keyword, "func"), "swift func keyword")
    expect(has(sw, .keyword, "let"), "swift let keyword")
    expect(has(sw, .number, "1"), "swift number")
    expect(has(sw, .comment, "// note"), "swift line comment")

    // Swift: multi-line block comment + string.
    let sw2 = toks("/* a\nb */ let s = \"hi\"", "swift")
    expect(has(sw2, .comment, "/* a\nb */"), "multi-line block comment")
    expect(has(sw2, .string, "\"hi\""), "swift string")

    // String with an escaped quote stays one token.
    let esc = toks("\"a\\\"b\"", "swift")
    expectEqual(esc.count, 1, "escaped quote does not split the string")
    expect(esc.first?.0 == .string, "escaped string token kind")

    // Python: hash comment, keywords, string.
    let py = toks("# c\ndef g():\n    return None", "python")
    expect(has(py, .comment, "# c"), "python hash comment")
    expect(has(py, .keyword, "def"), "python def")
    expect(has(py, .keyword, "return"), "python return")
    expect(has(py, .keyword, "None"), "python None")

    // JS via alias + single quotes + template backtick.
    let js = toks("const x = 'hi'; // c", "js")
    expect(has(js, .keyword, "const"), "js const (alias resolves)")
    expect(has(js, .string, "'hi'"), "js single-quote string")
    expect(has(js, .comment, "// c"), "js line comment")

    // JSON: string keys/values, number, literal.
    let json = toks("{\"a\": 12, \"b\": true}", "json")
    expect(has(json, .string, "\"a\""), "json key string")
    expect(has(json, .number, "12"), "json number")
    expect(has(json, .keyword, "true"), "json literal")

    // Bash: hash comment, keyword.
    let sh = toks("# c\necho hi", "bash")
    expect(has(sh, .comment, "# c"), "bash hash comment")
    expect(has(sh, .keyword, "echo"), "bash echo keyword")

    // Unknown language → C-like fallback (// comment, number; '#' is NOT a comment).
    let fb = toks("x = 1 // c", "rust")
    expect(has(fb, .comment, "// c"), "fallback line comment")
    expect(has(fb, .number, "1"), "fallback number")
    let fbHash = toks("a # 2", "rust")
    expect(!fbHash.contains { $0.0 == .comment }, "fallback does not treat # as a comment")
}
```

- [ ] **Step 2: Register** — add `("CodeHighlighter", codeHighlighterChecks),` in `Sources/Checks/main.swift` (near `("HRParser", ...)` / `("Frontmatter", ...)`).

- [ ] **Step 3: Run test to verify it fails**

Run: `swift run Checks CodeHighlighter`
Expected: build failure — `cannot find 'CodeHighlighter' in scope`.

- [ ] **Step 4: Implement `Sources/MarkdownCore/CodeHighlighter.swift`**

```swift
import Foundation

/// Lightweight, grammar-configured syntax tokenizer for fenced code blocks.
/// One scanner indexes the text as UTF-16 (so token ranges drop straight onto
/// NSTextStorage); per-language `LanguageGrammar` supplies keywords, comment
/// markers, and string delimiters. Unknown languages get a C-like fallback.
public enum CodeHighlighter {
    public enum TokenKind: Equatable { case keyword, type, string, comment, number }

    public struct Token: Equatable {
        public let range: Range<Int>   // UTF-16
        public let kind: TokenKind
        public init(range: Range<Int>, kind: TokenKind) { self.range = range; self.kind = kind }
    }

    public struct LanguageGrammar {
        public let keywords: Set<String>
        public let types: Set<String>
        public let lineComments: [String]
        public let blockComment: (open: String, close: String)?
        public let stringDelims: [Character]
        public init(keywords: Set<String>, types: Set<String> = [], lineComments: [String],
                    blockComment: (open: String, close: String)? = nil, stringDelims: [Character]) {
            self.keywords = keywords; self.types = types
            self.lineComments = lineComments; self.blockComment = blockComment
            self.stringDelims = stringDelims
        }
    }

    public static func tokens(in code: String, language: String) -> [Token] {
        let g = grammar(for: language)
        let ns = code as NSString
        let n = ns.length
        let delimUnits = Set(g.stringDelims.compactMap { $0.unicodeScalars.first.map { UInt16($0.value) } })
        var out: [Token] = []
        var i = 0

        func matches(_ s: String, at k: Int) -> Bool {
            let m = s as NSString
            guard k + m.length <= n else { return false }
            for j in 0..<m.length where ns.character(at: k + j) != m.character(at: j) { return false }
            return true
        }
        func isDigit(_ u: UInt16) -> Bool { u >= 48 && u <= 57 }
        func isIdentStart(_ u: UInt16) -> Bool { (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 }
        func isIdentChar(_ u: UInt16) -> Bool { isIdentStart(u) || isDigit(u) }

        while i < n {
            // Line comment → to end of line.
            if let lc = g.lineComments.first(where: { matches($0, at: i) }) {
                _ = lc
                var j = i
                while j < n && ns.character(at: j) != 10 { j += 1 }
                out.append(Token(range: i..<j, kind: .comment)); i = j; continue
            }
            // Block comment → to close marker (or EOF).
            if let bc = g.blockComment, matches(bc.open, at: i) {
                var j = i + (bc.open as NSString).length
                while j < n && !matches(bc.close, at: j) { j += 1 }
                if j < n { j += (bc.close as NSString).length }
                out.append(Token(range: i..<min(j, n), kind: .comment)); i = min(j, n); continue
            }
            let u = ns.character(at: i)
            // String → matching delimiter, honoring backslash escapes; multi-line ok.
            if delimUnits.contains(u) {
                var j = i + 1
                while j < n {
                    let c = ns.character(at: j)
                    if c == 92 { j += 2; continue }      // backslash
                    if c == u { j += 1; break }
                    j += 1
                }
                out.append(Token(range: i..<min(j, n), kind: .string)); i = min(j, n); continue
            }
            // Number → digit run with ., _, hex digits, x/X.
            if isDigit(u) {
                var j = i + 1
                while j < n {
                    let c = ns.character(at: j)
                    if isDigit(c) || c == 46 || c == 95 || c == 120 || c == 88
                        || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) { j += 1 } else { break }
                }
                out.append(Token(range: i..<j, kind: .number)); i = j; continue
            }
            // Identifier → keyword / type / nothing.
            if isIdentStart(u) {
                var j = i + 1
                while j < n && isIdentChar(ns.character(at: j)) { j += 1 }
                let word = ns.substring(with: NSRange(location: i, length: j - i))
                if g.keywords.contains(word) { out.append(Token(range: i..<j, kind: .keyword)) }
                else if g.types.contains(word) { out.append(Token(range: i..<j, kind: .type)) }
                i = j; continue
            }
            i += 1
        }
        return out
    }

    // MARK: - Grammars

    private static func grammar(for language: String) -> LanguageGrammar {
        switch language.lowercased() {
        case "swift": return swift
        case "js", "javascript", "ts", "typescript", "jsx", "tsx": return javascript
        case "py", "python": return python
        case "json": return json
        case "sh", "bash", "shell", "zsh": return bash
        default: return fallback
        }
    }

    private static let swift = LanguageGrammar(
        keywords: ["func","let","var","if","else","for","while","return","struct","class","enum",
                   "protocol","extension","import","guard","switch","case","default","break","continue",
                   "in","self","nil","true","false","public","private","internal","fileprivate","open",
                   "static","init","deinit","override","throws","throw","try","catch","do","defer",
                   "as","is","where","async","await","weak","unowned","lazy","mutating","some","any","typealias"],
        types: ["Int","String","Bool","Double","Float","Array","Dictionary","Set","Optional","Character","Data","URL","Date","Void"],
        lineComments: ["//"], blockComment: ("/*", "*/"), stringDelims: ["\""])

    private static let javascript = LanguageGrammar(
        keywords: ["const","let","var","function","return","if","else","for","while","do","class","extends",
                   "new","this","super","import","export","from","default","async","await","try","catch","finally",
                   "throw","typeof","instanceof","in","of","switch","case","break","continue","null","undefined",
                   "true","false","interface","type","enum","public","private","protected","readonly","static","void"],
        types: ["string","number","boolean","any","unknown","never","object","Array","Promise"],
        lineComments: ["//"], blockComment: ("/*", "*/"), stringDelims: ["\"", "'", "`"])

    private static let python = LanguageGrammar(
        keywords: ["def","class","return","if","elif","else","for","while","import","from","as","with",
                   "try","except","finally","raise","pass","break","continue","in","is","not","and","or",
                   "None","True","False","lambda","yield","global","nonlocal","async","await","assert","del","with"],
        lineComments: ["#"], blockComment: nil, stringDelims: ["\"", "'"])

    private static let json = LanguageGrammar(
        keywords: ["true","false","null"], lineComments: [], blockComment: nil, stringDelims: ["\""])

    private static let bash = LanguageGrammar(
        keywords: ["if","then","else","elif","fi","for","while","until","do","done","case","esac",
                   "function","in","return","echo","export","local","read","source","exit","set","unset","alias"],
        lineComments: ["#"], blockComment: nil, stringDelims: ["\"", "'"])

    /// C-like default for unknown languages. `#` is deliberately NOT a comment
    /// marker (ambiguous across languages) to avoid mis-coloring.
    private static let fallback = LanguageGrammar(
        keywords: ["if","else","for","while","return","function","class","def","const","let","var",
                   "import","export","true","false","null","new","switch","case","break","continue"],
        lineComments: ["//"], blockComment: ("/*", "*/"), stringDelims: ["\"", "'"])
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift run Checks CodeHighlighter`
Expected: PASS (all assertions). Then `swift run Checks` (full suite green).

- [ ] **Step 6: Commit**

```bash
git add Sources/MarkdownCore/CodeHighlighter.swift Sources/Checks/CodeHighlighterChecks.swift Sources/Checks/main.swift
git commit -m "feat(core): grammar-configured code syntax tokenizer (swift/js/py/json/bash + fallback)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Editor integration + palette + README

**Files:**
- Modify: `Sources/EditorEngine/LivePreviewStyler.swift`
- Modify: `Sources/EditorEngine/MarkdownEditorView.swift`
- Modify: `Sources/Checks/CodeBlockStylerChecks.swift`
- Modify: `README.md`

- [ ] **Step 1: Write the failing test** — append to `Sources/Checks/CodeBlockStylerChecks.swift` (it already imports AppKit/MarkdownCore/EditorEngine):

```swift
func codeHighlightStylerChecks() {
    let text = "```swift\nlet x = 1\n```"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: 100..<100), to: storage)
    LivePreviewStyler.highlightCode(CodeBlockParser.regions(in: text), in: storage)

    // 'let' starts at offset 9 (after "```swift\n"); it must carry a non-default
    // foreground color (the keyword color), and the mono code font must remain.
    let attrs = storage.attributes(at: 9, effectiveRange: nil)
    let color = attrs[.foregroundColor] as? NSColor
    expect(color != nil && color != NSColor.textColor, "keyword got a syntax color")
    let font = attrs[.font] as? NSFont
    expect(font?.isFixedPitch == true, "code stays monospaced under highlighting")
}
```

- [ ] **Step 2: Register** — add `("CodeHighlightStyler", codeHighlightStylerChecks),` in `Sources/Checks/main.swift` (after `("CodeBlockStyler", ...)`).

- [ ] **Step 3: Run test to verify it fails**

Run: `swift run Checks CodeHighlightStyler`
Expected: build failure — `type 'LivePreviewStyler' has no member 'highlightCode'`.

- [ ] **Step 4: Palette + highlight pass** — in `Sources/EditorEngine/LivePreviewStyler.swift`, add `import MarkdownCore` if not present (it is — `SpanStyle` comes from there), and append to the enum:

```swift
    /// Syntax-highlight palette (system colors adapt to light/dark).
    static func codeColor(_ kind: CodeHighlighter.TokenKind) -> NSColor {
        switch kind {
        case .keyword: return .systemPink
        case .type:    return .systemTeal
        case .string:  return .systemGreen
        case .number:  return .systemOrange
        case .comment: return .secondaryLabelColor
        }
    }

    /// Add foreground colors to syntax tokens inside each code block's body.
    /// Runs after `apply` (which resets colors), leaving the mono font + slab
    /// background untouched. `regions` come from `CodeBlockParser.regions`.
    public static func highlightCode(_ regions: [CodeBlockRegion], in storage: NSTextStorage) {
        let ns = storage.string as NSString
        storage.beginEditing()
        for region in regions where region.body.upperBound > region.body.lowerBound {
            let loc = region.body.lowerBound
            let len = region.body.upperBound - region.body.lowerBound
            guard loc >= 0, loc + len <= ns.length else { continue }
            let body = ns.substring(with: NSRange(location: loc, length: len))
            for token in CodeHighlighter.tokens(in: body, language: region.language) {
                let r = NSRange(location: loc + token.range.lowerBound,
                                length: token.range.upperBound - token.range.lowerBound)
                guard r.location >= 0, r.location + r.length <= ns.length else { continue }
                storage.addAttribute(.foregroundColor, value: codeColor(token.kind), range: r)
            }
        }
        storage.endEditing()
    }
```

- [ ] **Step 5: Call it from `restyle()`** — in `Sources/EditorEngine/MarkdownEditorView.swift`, change `restyle()` to keep the full region objects and run highlighting after `apply`:

```swift
        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let regions = CodeBlockParser.regions(in: storage.string)
            codeRegions = regions.map(\.full)
            let spans = InlineTokenizer.spans(in: storage.string)
            let sel = textView.selectedRange()
            let selection = sel.location..<(sel.location + sel.length)
            let deco = Decorator.decorations(spans: spans, selection: selection)
            LivePreviewStyler.apply(deco, to: storage)
            LivePreviewStyler.highlightCode(regions, in: storage)
        }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift run Checks CodeHighlightStyler`
Expected: PASS. Then `swift run Checks` (full suite green — existing `CodeBlockStyler` still passes: highlighting only adds foreground colors, the mono font/paragraph assertions are unaffected), then `swift build`.

- [ ] **Step 7: README** — add a bullet to the feature list:
```markdown
- **Code highlighting** — fenced blocks are syntax-colored (keywords, strings,
  comments, numbers) for Swift, JS/TS, Python, JSON, and shell, with a C-like
  fallback for other languages
```

- [ ] **Step 8: Commit**

```bash
git add Sources/EditorEngine/LivePreviewStyler.swift Sources/EditorEngine/MarkdownEditorView.swift Sources/Checks/CodeBlockStylerChecks.swift Sources/Checks/main.swift README.md
git commit -m "feat(editor): syntax-highlight fenced code blocks over the slab" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (vs spec)

- §1 architecture (pure tokenizer, one scanner, per-language grammar, UTF-16) → Task 1. §2 language set (swift/js+ts/python/json/bash + C-like fallback, alias map) → Task 1 grammars + `grammar(for:)`. §3 editor application (CodeBlockParser regions + body, foreground-only, after `apply`, mono/slab untouched, live via restyle) → Task 2 Steps 4–5. §4 palette (TokenKind→system NSColor, dark/light adaptive) → Task 2 Step 4. §5 tests (per-language keyword/comment/string/number, multi-line block comment + string, escape, alias, unknown→fallback, `#`-not-comment-in-fallback; styler integration foreground+mono) → Task 1 + Task 2 Step 1.
- Type consistency: `CodeHighlighter.TokenKind{keyword,type,string,comment,number}`, `Token{range,kind}`, `LanguageGrammar`, `tokens(in:language:)`, `codeColor(_:)`, `highlightCode(_:in:)`, `CodeBlockParser.regions`/`CodeBlockRegion.{language,body,full}` (existing) — consistent.
- §5 out-of-scope respected: no tree-sitter, no semantic coloring, no inline-code highlight, no triple-quote/template-literal/string-interpolation special cases (python `"""` and JS template `${}` highlight as plain strings — acceptable v1 limitation).
- Pinned risks: tokens are UTF-16 (offsets map onto storage); `highlightCode` runs AFTER `apply` (which resets foreground), else colors get wiped; bounds-guarded against stale ranges during edits; fallback omits `#` to avoid mis-coloring C/Rust. `isFixedPitch` used to assert mono survives (NSFont monospaced fonts report true).
- Visual: rendered-highlight screenshot deferred to the controller (capture the hanji window by id — secondary display; no interaction needed, a code block highlights on open).
