# hanji — Code-Block Syntax Highlighting (#30)

Design doc · 2026-06-15 · Epic G slice (code highlight) of the v1 close-out.

## 1. Goal

Color keywords, types, strings, comments, and numbers inside fenced code blocks,
applied as foreground colors over the existing mono slab (the slab background and
mono font from the recent code-block work stay intact). tree-sitter is deferred.

## 2. Decisions (locked)

- **Coverage:** a grammar set + generic fallback. v1 ships swift, javascript/
  typescript, python, json, bash/shell; unknown languages get a C-like fallback.
- **Engine:** one pure char-by-char scanner parameterized by a per-language
  `LanguageGrammar` (keywords, comment markers, string delimiters). Grammars are
  static data, addable incrementally.
- **Placement:** foreground colors only, run in the editor's `restyle()` over
  each `CodeBlockRegion.body`; mono font / slab untouched.
- **Theme:** `TokenKind → system NSColor` (adapts to light/dark).

## 3. Architecture

### 3.1 `CodeHighlighter` (MarkdownCore, pure)

```swift
public enum CodeHighlighter {
    public enum TokenKind { case keyword, type, string, comment, number }
    public struct Token { let range: Range<Int> /* UTF-16 */; let kind: TokenKind }
    public struct LanguageGrammar {
        let keywords: Set<String>; let types: Set<String>
        let lineComments: [String]; let blockComment: (open: String, close: String)?
        let stringDelims: [Character]
    }
    public static func tokens(in code: String, language: String) -> [Token]
}
```
The scanner indexes the text as **UTF-16** (`NSString`) so token ranges map
directly onto `NSTextStorage`. Per position it tries, in order: line comment →
block comment → string (delimiter, `\` escape, multi-line) → number (digit run
with `.`/`_`/hex) → identifier (keyword/type lookup, else uncolored). Scanning
the whole block at once gives multi-line strings/comments for free.

`grammar(for:)` resolves aliases (js/javascript/ts/typescript, py/python,
sh/bash/shell/zsh, json, swift) and falls back to a C-like grammar for unknown
languages. The fallback deliberately omits `#` as a comment marker (ambiguous
across languages) to avoid mis-coloring.

### 3.2 Editor application (EditorEngine)

`CodeBlockRegion` already carries `language` and `body` (inner range). In
`restyle()`, after `LivePreviewStyler.apply(...)` (which resets attributes),
run `LivePreviewStyler.highlightCode(regions:in:)`: for each region, tokenize
`body` and add `.foregroundColor` per token from `codeColor(_:)`. Code blocks
keep their raw text even with the caret inside, so highlighting is always on and
refreshes through the existing restyle path (text change / caret line change).

### 3.3 Palette

`codeColor`: keyword = `.systemPink`, type = `.systemTeal`, string =
`.systemGreen`, number = `.systemOrange`, comment = `.secondaryLabelColor`.
System colors adapt to appearance; tunable after seeing it rendered.

## 4. Testing

- `CodeHighlighter` (pure): per-language keyword/comment/string/number; multi-line
  block comment + string; escaped quote stays one token; language alias; unknown
  → fallback; fallback does not treat `#` as a comment.
- Styler integration: a code keyword gets a non-default foreground color and the
  mono font survives.
- Visual: screenshot a highlighted block (window-id capture; no interaction).

## 5. Out of scope

tree-sitter (incremental/accurate, later); semantic (type-aware) coloring; line
numbers; language-specific niceties (JS regex/template literals, Swift/Python
string interpolation, Python `"""` blocks — these highlight as plain strings);
inline-code highlighting (stays single-tone).
