# Hanji — Strikethrough, Highlight, Footnotes, Math

Design doc · 2026-10-24

**Goal:** the inline syntax a vault written elsewhere uses most and Hanji still
shows raw: `~~strikethrough~~`, `==highlight==`, footnotes (`[^1]` and
`[^1]: …`), and LaTeX math (`$…$` inline, `$$ … $$` blocks). First of three
pieces from the Obsidian comparison; link rewriting on rename (#12) and note
embeds / hover preview follow with their own docs.

## Decisions

**New span styles from the same tokenizer.** `SpanStyle` gains
`.strikethrough`, `.highlight`, `.math`, `.footnoteRef` and `.footnoteDef`.
Everything else that reads spans (the styler, reading mode, table cells, the
incremental parser) picks them up from there, so they can't disagree about
what is struck or highlighted.

**`$$` blocks are fences.** `Fence` accepts a line that is exactly `$$` (after
the usual indent) as a fence with marker `$`, length 2 and info `math`, closed
by the next bare `$$`. That puts math on the code-block path unchanged: its
body is never read as markdown or tags, the incremental parser and its
equivalence checks already cover fences, reading mode hides the `$$` lines
(#19), and the block renders through the renderer registry under the language
`math` — which also renders GitHub's ```` ```math ```` blocks. `$$x$$` on one
line is not a block; it is inline math. Rejected: a separate math-block
region type (a second copy of every fence rule).

**KaTeX from the CDN, block math only.** `MathRenderer` (CoreRenderers) works
like `MermaidRenderer`: a pinned, integrity-checked KaTeX 0.18.11 build in a
WKWebView with a CSP, the formula passed only as a string literal, and the
page reporting its height. It needs network access, like mermaid. Inline
`$…$` is not rendered: off the caret's line the `$`s are hidden and the
formula is set in STIX italic. Rejected: bundling KaTeX (≈1 MB of JS and
fonts in the app); rendering inline math to images (line heights and caret
geometry in TextKit 2 — see the Live Preview invariants — for little gain).

**No inline footnotes.** `^[…]` is left for later.

## Behaviour

- **`~~text~~`:** struck through, in the secondary label color. A run of three
  or more `~` at a line's start is still a fence.
- **`==text==`:** a yellow wash behind the text (lighter in dark mode).
- **Inline math `$x$`:** an opening `$` followed by a non-space, a closing `$`
  preceded by a non-space and not followed by a digit — so `$5 and $10` is
  text. Not inside inline code or links. A `\$` is not a delimiter. Shown in
  STIX italic, `$`s hidden off the caret's line.
- **Block math:** `$$` / formula lines / `$$` renders as a KaTeX display
  formula where the block is, like a mermaid diagram; the caret inside shows
  the source. A KaTeX error shows its message in red instead of a formula.
- **Footnote reference `[^id]`:** anywhere but the start of a line followed by
  `:`. Superscript, smaller, accent color; `[^` and `]` hidden off the caret's
  line, so `[^1]` reads as a raised `1`. Clicking it moves the caret to the
  definition line (its line at the top, as an Outline jump). With no
  definition in the note, nothing happens.
- **Footnote definition `[^id]: text`:** at a line's start; the `[^id]:` label
  in the secondary label color. Clicking the label jumps back to the first
  reference.
- **Tables:** cells are tokenized by the same tokenizer; struck, highlighted
  and math text is styled in cells too.
- **Reading mode:** all of the above, with markers hidden on every line.

## Design

### MarkdownCore

- `SpanStyle`: the five new cases.
- `InlineTokenizer.scanInline`: `~~` and `==` via `pairSpan` (as `**`); `$`
  via a new `mathSpan` with the delimiter rules above; `[^` via a new
  `footnoteRefSpan` tried before `bracketSpan`. `parseLine`: a line starting
  with `[^id]:` yields a `.footnoteDef` span whose marker is the label, then
  scans the rest inline.
- `Fence.parse`: the `$$` case (marker `$`, info always `math`; a `$$` fence
  can't carry an info string).
- `Footnotes` (new file): `definition(of:in:)` and `firstReference(to:in:)` —
  offsets for the click jumps, from the tokenizer's spans.

### EditorEngine

- `LivePreviewStyler.attributes(for:)`: strikethrough, highlight, footnote
  styles. `.math` is a trait style (composes with heading size).
- Click handling: a click on a `.footnoteRef` / `.footnoteDef` span asks
  `Footnotes` for the target and jumps there, before link handling.
- Table cells: map the new styles where cell text is styled.

### CoreRenderers

- `MathRenderer` (`language = "math"`) and `MathPage` (HTML, CSP, navigation
  rule, string literal), registered with the default renderers next to
  mermaid.

## Testing

- Tokenizer: each new style; `$5 and $10`; `\$`; `$` in inline code; `~~~`
  fence vs `~~x~~`; `[^1]:` at line start vs `[^1]` mid-line; `[^1]` is not a
  markdown link; `$$` fences open/close, unclosed `$$`, `$$x$$` on one line.
- Parser equivalence: incremental vs full parse with `$$` blocks typed and
  deleted.
- Styler: attributes for each style; markers hidden off the caret's line.
- `MathPage`: CSP, the formula never reaching markup, navigation refused (as
  `MermaidPageChecks`).
- Footnote jumps: definition / first reference offsets.
- Performance: the editor perf groups stay within their limits.
- GUI: a note with each construct, screenshotted in Live Preview and reading
  mode.
