# Hanji — Outline Panel

Design doc · 2026-10-09 · issue #3

**Goal:** a right-sidebar panel listing the open note's headings; a click jumps
there, and the heading of the section being read is highlighted. Listed in
README › Status & known gaps ("an outline / table-of-contents panel").

## Decisions

**Right sidebar, as a first-party plugin.** Like Backlinks and Calendar it is
an `OutlinePlugin` that registers a sidebar view, so it can be switched off in
Settings ▸ Plugins. It sits first, above Backlinks. Rejected: a third mode tab
in the left sidebar (hides the file list while open); building it into the app
(every right-sidebar panel today is a plugin).

**Headings from the editor's own tokenizer.** `Outline.headings(in:)` keeps
the `.heading` spans of `InlineTokenizer.spans(in:)`, which already skips
fenced code (unclosed fences too) and frontmatter. The outline can't disagree
with what the editor styles as a heading. Not from the metadata index: it
updates on save, not while typing.

**Two small SDK additions.** `EditorContext.focusOffset` (where the reader
is) and `WorkspaceActions.reveal(offset:)` (jump there, line at the top).
Other plugins can use them too.

## Behaviour

- **List:** `#`–`######` headings in order, indented one step per level below
  the note's highest level. The title shows the visible text: `**bold**` →
  bold, `[[target|alias]]` → alias, `` `code` `` → code; a closing `##` run
  is dropped. `#tag` (no space) is not a heading; setext (`===`) headings
  aren't supported by Hanji and aren't listed.
- **Empty states:** "Open a note to see its outline" with no note; "No
  headings" when the note has none.
- **Updates:** as the text changes, at most every 0.15s; the first change after
  a pause (a note switch included) shows at once.
- **Click:** the caret moves to the heading's line, that line is scrolled to
  the top of the editor, and the editor takes focus. Works in reading mode.
- **Current heading:** the last heading at or before the focus offset — the
  caret while editing, the top visible line while reading — is highlighted.
- **Split view:** follows the active pane's note; an inactive pane reports
  neither caret nor scroll.

## Design

### MarkdownCore — `Outline` (new file)

```swift
public struct OutlineHeading: Equatable {
    public let level: Int      // 1...6
    public let title: String   // visible text
    public let offset: Int     // UTF-16 offset of the heading line's start
}
public enum Outline {
    public static func headings(in text: String) -> [OutlineHeading]
    /// Index of the heading whose section holds `offset` (nil: before the first).
    public static func current(in headings: [OutlineHeading], at offset: Int) -> Int?
}
```

The title is the heading's content with the marker ranges of the other spans
on that line removed, trimmed, then a trailing ` #…` run dropped.

### ExtensionSDK

- `EditorContext.focusOffset: AnyPublisher<Int, Never>`
- `WorkspaceActions.reveal(offset: Int)` — in the active note.

### AppCore

- `focusOffset` is a `CurrentValueSubject` on `AppState`, not `@Published`:
  it changes on every caret move, and publishing through `objectWillChange`
  would re-render the window on each one.
- `caretMoved(to:)` (existing) and a new `viewportMoved(top:)` record the
  caret and the top visible line; the subject sends `isActiveTabReading ?
  viewportTop : liveCaret`. `toggleReading` and `hydrate(from:)` (tab switch;
  it already resets the caret to 0) resend it, `hydrate` resetting the
  viewport top to 0.
- `reveal(offset:)` sets `pendingJumpToTop = true`, then `pendingCursorOffset
  = offset`. `pendingJumpToTop` is cleared when `pendingCursorOffset` goes
  back to nil (the editor clears it once the jump is applied), so a later
  search or Back/Forward jump keeps today's placement.
- `Host` forwards `focusOffset` and `reveal(offset:)`.

### EditorEngine

- `MarkdownEditorView(..., jumpsToTop: Bool = false, onViewportTopChange: ((Int) -> Void)? = nil)`.
- A `cursorOffset` jump with `jumpsToTop` sets the coordinator's
  `pendingScrollAnchor` to the line's start (delta 0) instead of
  `scrollRangeToVisible` + `revealCaretAfterLayout`; the widget pass restores
  it once the lines above have their real heights (the mechanism reading mode
  uses to hold the view).
- `clipViewDidScroll` reports the top visible line's start offset through
  `onViewportTopChange`, at most once per runloop turn, live pane only.

### OutlinePlugin (new target)

`activate(host:)` registers sidebar view `outline` titled "Outline". The view
takes `activeNotePath.combineLatest(activeText)` throttled at 0.15s
(`latest: true`) into `Outline.headings`, `focusOffset` into
`Outline.current`, and calls `workspace.reveal(offset:)` on a click. Listed
before `BacklinksPlugin()` in `HanjiApp`.

## Testing

`swift run Checks`:
- **Outline:** levels, titles, offsets; headings in fenced code, an unclosed
  fence and frontmatter excluded; `#tag` not a heading; inline markdown
  stripped and a closing `##` dropped; `current(at:)` before, on and between
  headings; a 4,000-line note under a time limit.
- **AppState:** `focusOffset` follows the caret while editing and the
  viewport top while reading, and is resent on a mode toggle and a tab switch;
  `reveal` sets the jump and its top placement, which clears with the jump.
- **Editor (EditorHarness):** a `jumpsToTop` jump puts the heading's line at
  the top, with a table above it whose height differs between source and
  grid; scrolling reports the top line; EditorReveal still passes.
- **Live app:** a probe copy shows the panel; clicking a row is tried through
  AXPress, otherwise checked by hand.

## Out of scope

Collapsing sections in the outline, reordering sections by dragging, setext
headings.
