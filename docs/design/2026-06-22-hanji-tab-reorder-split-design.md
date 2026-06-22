# hanji — Tab Reorder + Send-Tab-to-Pane

Design doc · 2026-06-22 · builds on the tabs slice (OpenTab snapshots) and the
left/right split slice (`Pane`/`panes`/`splitRight`/`focusPane`).

## 1. Goal

Two interactions on the tab bar:

1. **Reorder** — drag a tab within its own tab bar to a new position
   (insert-style, like a browser/editor).
2. **Send to pane** — move a tab into the left/right pane via a context menu or
   keyboard, creating the second pane when there's room (the keyboard form is
   what the request called "split to left/right pane").

### Decisions (locked)

- **Reorder is within one pane only**, insert-style: a dragged tab lands at the
  drop position and the rest shift; no two-element swap, no cross-pane drag.
- **Reorder never changes the active tab or the live buffer** — it is a pure
  positional change of `Pane.tabs`. No writeBack/hydrate, no autosave coupling.
- **Send-to-pane MOVES the tab** (not a copy). It respects the existing
  **2-pane max** (left = `panes[0]`, right = `panes[1]`). A new pane is created
  only when there is room *and* the source pane keeps at least one tab (so a
  lone tab never "splits" into the same single pane).
- **Existing `splitRight()` (⌘\\) is kept unchanged** — it *duplicates* the
  current document into a new right pane (same doc side-by-side). Send-to-pane is
  a distinct *move* operation. The two coexist.
- **No drag-to-edge split preview.** The VSCode-style edge overlay is explicitly
  out of scope; triggers are a tab context menu and keyboard shortcuts.

## 2. Architecture

### 2.1 Reorder — `moveTab` (AppCore/AppState)

```swift
/// Move `sourceID` to just before `targetID` within `pane` (insert-style).
/// `targetID == nil` moves it to the end. No-op if source == target or either
/// id is absent. Pure positional change: activeTabID and the live working
/// fields are untouched.
public func moveTab(_ sourceID: UUID, before targetID: UUID?, in pane: Pane)
```

Sketch:
```swift
public func moveTab(_ sourceID: UUID, before targetID: UUID?, in pane: Pane) {
    guard sourceID != targetID,
          let from = pane.tabs.firstIndex(where: { $0.id == sourceID }) else { return }
    objectWillChange.send()
    let moved = pane.tabs.remove(at: from)
    if let targetID, let to = pane.tabs.firstIndex(where: { $0.id == targetID }) {
        pane.tabs.insert(moved, at: to)            // before target (post-removal index)
    } else {
        pane.tabs.append(moved)                    // nil target → end
    }
}
```
`Pane` is a plain class, so the mutation is wrapped in `objectWillChange.send()`
exactly like the other tab mutators. Because the active tab is identified by
`activeTabID` (not by index), reordering leaves the active tab and the live
buffer exactly as they were.

### 2.2 Send-to-pane — `moveTabToSide` (AppCore/AppState)

```swift
public enum PaneSide { case left, right }

/// Move the tab into the pane on `side`. If a pane already exists there, merge
/// the tab into it; otherwise create a new pane there (only when panes < 2 and
/// the source keeps ≥1 tab). The moved tab becomes that pane's active tab and
/// that pane is focused. An emptied source pane collapses. No-op when the move
/// is impossible (no room / dead-end side / lone tab that can't split).
public func moveTabToSide(_ tabID: UUID, _ side: PaneSide)
```

Semantics (2-pane model; `panes[0]` = left, `panes[1]` = right):

- Locate the source pane `src` (the pane whose `tabs` contains `tabID`) and the
  tab's snapshot. Persist the live buffer first when the moved tab is the active
  live tab (`flushPendingSave()` + `writeBackActive()`), so the snapshot carried
  over is current.
- Compute the neighbour index `srcIndex ± 1` (`+1` for `.right`, `-1` for
  `.left`).
- **Neighbour pane exists** → remove the tab from `src`, append the snapshot to
  the neighbour, set the neighbour's `activeTabID` to it, focus the neighbour
  (`activePaneID = neighbour.id`, hydrate from the snapshot). If the moved tab
  was `src`'s `activeTabID` and `src` still has tabs, repoint `src.activeTabID`
  to a remaining neighbour (so it's valid when re-focused). If `src` is now
  empty, collapse it via the existing `closePaneIfEmpty(src)`.
- **No neighbour, room exists (`panes.count < 2`), and `src.tabs.count ≥ 2`** →
  build `Pane(tabs: [snapshot], activeTabID: snapshot.id)`, insert it at the
  correct side (`.right` after `src`, `.left` before `src`), remove the tab from
  `src`, repoint `src.activeTabID` if it was the moved tab, focus the new pane,
  hydrate.
- **Otherwise** (would exceed 2 panes, dead-end side, or a lone tab that can't
  split) → **no-op**.

This reuses `closePaneIfEmpty`, `writeBackActive`, `hydrate`, and
`flushPendingSave` unchanged. Cross-pane reconcile and rename/move already loop
every pane, so they need no change.

### 2.3 UI (HanjiApp)

- **Reorder (TabBarView):** each `tabItem` gets `.draggable(tab.id.uuidString)`
  and `.dropDestination(for: String.self) { ids, _ in moveTab(parsed, before: tab.id, in: pane) }`.
  A thin trailing drop zone after the last tab drops with `before: nil` (move to
  end). `isTargeted` draws a subtle insertion indicator (leading edge of the drop
  target). Dragging is independent of tap-to-switch.
- **Send-to-pane (TabBarView):** each `tabItem` gets a `.contextMenu` with
  **"Move to Left Pane"** / **"Move to Right Pane"**, each disabled when that
  direction is a no-op for that tab.
- **Keyboard (HanjiApp `.commands`):** **"Move Tab Right"** `⌃⌘→` and
  **"Move Tab Left"** `⌃⌘←`, acting on the active pane's active tab via
  `moveTabToSide(appState.activeTabID!, .right/.left)`. (`⌘\\` stays as the
  existing duplicate-to-right `splitRight`.)

## 3. Testing

Headless `Checks` (real AppState + temp vault), extending `TabChecks`:

**Reorder (`moveTab`):**
- Open A, B, C (order `[A,B,C]`). `moveTab(A, before: nil)` → `[B,C,A]`.
- `moveTab(C, before: B's id)` → C lands before B.
- No-op: `moveTab(x, before: x)` and unknown ids leave order unchanged.
- Invariants: `activeTabID` and `activeText` are unchanged after any reorder.

**Send-to-pane (`moveTabToSide`):**
- Two tabs in one pane, `moveTabToSide(tab2, .right)` → `panes.count == 2`,
  tab2 in the right pane and active, left pane keeps tab1.
- A neighbour exists: `moveTabToSide(leftTab, .right)` merges into the right
  pane; if the left pane is emptied it collapses back to one pane.
- Lone tab: single pane with one tab, `moveTabToSide(tab, .right)` is a no-op
  (no pointless split).
- Dead-end: tab already in the right pane, `moveTabToSide(tab, .right)` is a
  no-op (2-pane max).
- `.left` mirror: a new left pane is inserted at index 0 (existing pane shifts
  right); the moved tab is focused.

## 4. Out of scope

Cross-pane *drag* (only context-menu/keyboard moves across panes); drag-to-edge
split preview (VSCode-style overlay); two-element swap reorder; 3+ panes;
vertical split; pinned/locked tabs; reordering panes themselves.
