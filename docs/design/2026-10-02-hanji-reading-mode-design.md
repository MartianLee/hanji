# Hanji — Reading Mode

Design doc · 2026-10-02 · issue #1 · builds on the Live Preview editor
(`Sources/EditorEngine/MarkdownEditorView.swift`)

**Goal:** a per-tab view that shows a note fully rendered — no Markdown
marker on any line, every widget drawn — and can't be typed into. Listed in
README › Status & known gaps as "a separate reading (rendered-only) mode".

## Decisions

**Per tab, not app-wide or per note.** ⌘E flips the active tab only, as in
Obsidian. A split can keep one note in editing and another in reading.

**Same editor, with no caret to reveal.** Live Preview already renders
everything except the caret's line. Reading mode runs the same pipeline with
"no line holds the caret", and makes the text view non-editable. Rejected:

- An HTML renderer in a web view. It would also serve export/print (#2), but
  wikilinks, embeds, Dataview, mermaid, tags and checkbox toggles would all be
  rebuilt, and the result would look different from the editor.
- A second NSTextView holding marker-free attributed text. Copying would give
  clean text, but it is a second renderer, and checkbox clicks would need
  mapping back to source offsets.

**Checkboxes still toggle.** They are the one edit reading mode allows,
undoable with ⌘Z. Everything else that changes the note — typing, paste, cut,
list editing, renaming the inline title — is off.

## Behaviour

- **Switching:** ⌘E, View › Reading Mode (a checked toggle), or the
  `tab.toggleReading` command in the ⌘P palette. A reading tab shows a `book`
  icon before its title. The top visible line stays put across the switch.
- **Rendering:** every line hides its markers; images, tables, rules, mermaid
  and code-block renderers always show. Clicking a widget doesn't reveal its
  source.
- **Allowed:** selecting and copying (copies the Markdown source), ⌘F find
  (replace is unavailable), clicking links and tags (⌘-click opens a new tab),
  toggling checkboxes.
- **Follows the tab:** link navigation and Back/Forward in the tab keep the
  mode; moving the tab to the other pane keeps it. Two tabs on the same note
  have their own modes and share the buffer. A new tab opens in editing.
- **Persistence:** only pinned tabs come back after a relaunch, so the mode is
  remembered for pinned tabs only.
- **Outside changes:** vault-wide replace and reload-from-disk show up in a
  reading tab like in an editing one.

## Design

### AppCore — state

- `OpenTab.isReading: Bool`. On the tab, not the shared `NoteBuffer`.
  `open`/`show` in the same tab keep the tab struct, so navigation carries the
  mode for free; `moveTabToSide` moves the struct whole.
- `AppState.toggleReading(_ tabID:)`, shaped like `togglePin`.
- Persistence: next to `persistPins()`, the key `io.hanji.reading.<vault>`
  holds the vault-relative paths of tabs that are both pinned and reading.
  It is recomputed from the tabs on every change, like the pins, so renames,
  moves and unpinning follow without extra code. `restorePins()` sets
  `isReading` on the tabs it reopens.

### EditorEngine — rendering

- `MarkdownEditorView(isReading: Bool = false)`.
- The coordinator gets `revealSelection: NSRange?` — nil in reading mode,
  otherwise the text view's selection. Every place that decides "the caret's
  line shows its source" reads it; nil reveals no line:
  1. `Decorator.decorations` (inline markers; its selection becomes optional)
  2. `hideMarkers`
  3. `markerPlacements` (bullets and checkboxes)
  4. `reapplyReservations`
  5. `updateWidgets` — code-block renderers, `imageWidgets`, `hrWidgets`,
     `tableWidgets`
  6. `textViewDidChangeSelection` — no restyle on caret moves in reading mode
- Change tracking (`dirtyParagraphs`, `isStyledAsShown`) keeps following the
  real caret. At worst it restyles a paragraph that renders the same, and the
  incremental restyle stays untouched.
- `updateNSView`, when `isReading` changes: commit any marked text
  (`unmarkText()`), remember the top visible character offset, set
  `isEditable = !isReading`, close the `[[` completion list, run one full
  restyle and widget pass, then scroll that offset back to the top.
- `toggleCheckbox`: in reading mode, turn `isEditable` on for the duration of
  the replacement, so `shouldChangeText` passes and the undo entry is
  registered as usual. If ⌘Z turns out to be refused while the view is not
  editable, `ClickableTextView` does the same around `undo:` / `redo:`.
- `handleClick`: in reading mode skip the branch that snaps the caret to a
  widget's first line; checkbox, tag and link handling are unchanged.

### HanjiApp — entry points

- `ContentView` passes `isReading: tab.isReading`, and makes the inline title
  read-only for a reading tab.
- View menu (`CommandGroup(after: .sidebar)`): a `Toggle("Reading Mode")`
  bound to the active tab, ⌘E. Nothing in the app uses ⌘E today.
- `HanjiApp` registers `Command(id: "tab.toggleReading", …)` beside
  `tab.togglePin`.
- `TabBarView` shows `Image(systemName: "book")` before a reading tab's title.

## Edge cases

- **IME composition** when switching: the marked text is committed first,
  so the full restyle never runs over a composition (see the TextKit 2 Live
  Preview invariants).
- **Scroll:** the full restyle changes line heights (the caret line's markers
  hide, widgets replace source). The top visible offset is restored after
  layout. The full-document `ensureLayout` stays as it is.
- **Saving:** switching never saves or blocks saving; autosave, the conflict
  banner and the missing-on-disk banner work in reading mode.
- **Same note in both panes**, one reading: edits in the other pane appear
  live, through the shared buffer.
- **Inactive pane:** the first click focuses the pane and doesn't toggle a
  checkbox — unchanged.
- **Find bar:** a non-editable NSTextView hides the replace row; checked in
  the harness.

## Testing

`swift run Checks`:

- **AppState** (TabChecks / PinChecks): toggling flips only that tab; the mode
  survives same-tab `open` and Back/Forward; new tabs open in editing; moving
  to the other pane keeps it; a pinned reading tab comes back reading after
  reopening the vault; an unpinned one isn't stored; a rename carries it.
- **Editor** (`EditorHarness` gains `isReading`): on the caret's line,
  `**bold**` markers are hidden; a rule and a table under the caret render as
  widgets; key presses and paste leave the text unchanged; a checkbox toggles
  and ⌘Z restores it while non-editable; switching during composition commits
  it; the top visible line holds across a switch.
- **Mutation:** pointing any one of the six reveal sites back at the real
  selection turns a check red.
- **Live app:** synthetic clicks land at offset 0, so real-mouse clicks on
  checkboxes and links are confirmed by hand from a written checklist.

## Out of scope

Copying without markers; a setting for the default mode of new tabs;
export / print (#2).
