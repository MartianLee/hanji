# Hanji — Workspace Restore

Design doc · 2026-10-31

**Goal:** quitting and reopening Hanji (or reopening a vault) brings back the
workspace as it was: every open tab in both panes, in order, which tab each
pane showed, which pane was active, pins and reading mode — and each note
where it was left, caret and scroll. Today only pinned tabs come back, the
first one is shown, and everything starts at the top.

## Decisions

**Each tab remembers where its note was left.** `OpenTab.position` holds the
caret and the view's top: the offset where the wrapped line at the top edge
starts — inside a paragraph, for a long one — and how many points into that
line the view is scrolled. (Recording only the paragraph at the top, as first
built, brought a tab back with that paragraph's start at the top: up to a
paragraph higher than it was left.) The live editor
already reports both (`caretMoved`, `viewportMoved`); they now also land in
the live tab. An inactive pane's editor reports its top line too — it can be
scrolled without being focused — into its own tab only.

**Showing a tab goes back to its position.** `hydrate(from:)` jumps to the
tab's position instead of offset 0: the caret where it was, the remembered
line at the top. So switching tabs also returns to where you were, which the
tabs design (2026-06-16) asked for and later code lost. A tab that starts
showing another note (a link followed in place, Back/Forward) starts that
note fresh: at the top, or at the history entry's caret.

**A jump can name the line for the top.** `AppState.pendingJumpTopLine` /
`MarkdownEditorView.jumpTopLine`: the pending caret jump also scrolls that
line to the top (through `scrollLineToTop`, which waits for real layout).
Setting `pendingCursorOffset` clears the placement of the previous jump, so a
search hit set right after opening a note isn't scrolled to the note's old
top line; whoever wants a placement sets it after the offset (`reveal`).

**A new editor starts at its tab's position.** `MarkdownEditorView` takes
`startCaret`/`startTopLine`, applied once when the editor is made and no jump
is pending for it — without taking focus. That is how the inactive pane
comes back at launch (jumps only reach the active pane), and it also stops a
split from throwing the other pane's editor back to the top when the panes
are rebuilt.

**The workspace is stored per vault, in UserDefaults** (`io.hanji.workspace.<vault path>`),
as JSON: panes → tabs (vault-relative path, pinned, reading, caret, top, top delta),
each pane's active tab, the active pane. Written when the vault closes or the
app quits (`saveAllForClose`), and a second after any change to the app state
settles, so a crash loses little. No note text: every note is saved on quit.

**Restoring.** `openVault` restores the stored workspace; notes that no longer
exist (or aren't UTF-8) are dropped, a pane left empty goes, a dropped active
tab passes to its neighbour. A note open in both panes shares one buffer, as
always. Without a stored workspace, the old pinned-tabs list is used once
(migration). The `HANJI_OPEN_VAULT` test hook skips restoring, so probes start
from a known state.

## Out of scope

Back/forward history (starts empty); a note's selection range (only the
caret); window size and sidebar state (SwiftUI's own); the scroll offset
within a line (the top line is enough).

## Checks

- `WorkspaceRestore` (model): save, reopen in a fresh AppState, compare panes,
  tabs, pins, reading, active tab/pane, the live tab's pending jump; missing
  notes dropped; shared buffer across panes; legacy pins; a debounced save.
- `TabPosition` (model): switching tabs returns to each one's position; a
  note opened in place starts at the top; Back puts the caret into view; a
  jump set after opening a note carries no stale placement.
- `EditorJumpTopLine`, `EditorStartPosition` (editor): caret and top line
  land where asked; an inactive editor starts at its position without focus
  and reports its top line.
- `WorkspaceRestoreEditors`: both panes of a restored split, built like
  ContentView, show their notes at the saved lines.
