# hanji — Left/Right Editor Split

Design doc · 2026-06-18 · Epic G slice (split panes), built on the tabs slice.

## 1. Goal

Show two editor panes side by side, each with its own tab group, so two notes
are visible at once. Only one pane is focused/edited at a time.

### Key insight (locked)

Keyboard focus is singular, so **one live editing buffer is enough**. AppState's
existing single working state (`selectedFile`/`activeText`/`savedText`/
`externalConflict`/`pendingCursorOffset`/`conflictPaused`) stays as-is and
represents the **active pane's active tab**. A `Pane` is just a tab group; the
non-active pane renders its active tab's **snapshot** (read-only display) and
becomes live when clicked. No per-pane working state, no per-pane autosave, no
SDK mirror.

### Decisions (locked)

- **Scope:** exactly 1 or 2 panes, left/right (`HSplitView`). Defer 3+ panes,
  vertical split, drag-tab-between-panes, per-pane sidebars.
- **Public API preserved:** `tabs`/`activeTabID`/`open`/`switchTab`/`closeTab`/
  `selectedFile`/`activeText`/… keep working by operating on the **active pane**
  — SDK/Host, search, backlinks, calendar, and existing tests are unchanged.
- **Open targets the active pane.** Split Right puts the active doc in a new
  right pane. Closing a pane's last tab removes the pane (2→1); the last tab of a
  lone pane → empty state.

## 2. Architecture

### 2.1 `Pane` (AppCore) — a tab group

```swift
public final class Pane: Identifiable {
    public let id = UUID()
    public var tabs: [OpenTab]
    public var activeTabID: UUID?
    public init(tabs: [OpenTab] = [], activeTabID: UUID? = nil) {
        self.tabs = tabs; self.activeTabID = activeTabID
    }
}
```
(A plain class — AppState owns the published array and drives `objectWillChange`.)

### 2.2 `AppState` — panes over the existing working state

```swift
@Published public private(set) var panes: [Pane] = [Pane()]
@Published public private(set) var activePaneID: UUID?
var activePane: Pane? { panes.first { $0.id == activePaneID } ?? panes.first }
public var isSplit: Bool { panes.count > 1 }
```

The existing `tabs`/`activeTabID` become **proxies to the active pane** (so all
current call sites and tests keep working):
```swift
public var tabs: [OpenTab] { activePane?.tabs ?? [] }
public var activeTabID: UUID? { activePane?.activeTabID }
```
(They were `@Published private(set)` stored; switching to computed requires that
nothing subscribes to `$tabs`/`$activeTabID` — only views read them, and views
re-render via `objectWillChange` which AppState fires on every pane mutation. The
TabBarView observes AppState. Verify no `$tabs` publisher use before changing.)

`open`/`switchTab`/`closeTab` mutate `activePane`'s tab list + the working state
(via the existing `writeBackActive`/`hydrate`/`flush`), wrapped in
`objectWillChange.send()` since `Pane` is a plain class. `writeBackActive`/
`hydrate` already read/write the working fields; they now find the active tab in
`activePane.tabs`.

New pane operations:
```swift
/// Focus another pane: write the live working state back into the current
/// active pane's active tab, then hydrate from the target pane's active tab.
public func focusPane(_ id: UUID) {
    guard id != activePaneID, let target = panes.first(where: { $0.id == id }),
          let tab = target.tabs.first(where: { $0.id == target.activeTabID }) else { return }
    flushPendingSave()
    writeBackActive()
    activePaneID = id
    hydrate(from: tab)
}

/// Open the active document in a new right pane (no-op if already split).
public func splitRight() {
    guard panes.count == 1, let cur = activePane, let id = cur.activeTabID,
          let tab = cur.tabs.first(where: { $0.id == id }) else { return }
    writeBackActive()                       // ensure the snapshot is current
    let right = Pane(tabs: [tab], activeTabID: tab.id)   // same OpenTab (shared file/buffer snapshot)
    panes.append(right)
    activePaneID = right.id
    hydrate(from: tab)
}

/// Remove a pane (when its last tab closed); collapse the split.
private func closePaneIfEmpty(_ pane: Pane) {
    guard pane.tabs.isEmpty, panes.count > 1 else { return }
    panes.removeAll { $0.id == pane.id }
    if activePaneID == pane.id, let first = panes.first {
        activePaneID = first.id
        if let t = first.tabs.first(where: { $0.id == first.activeTabID }) { hydrate(from: t) }
        else { clearActive() }
    }
}
```
`closeTab` removes from the active pane, then calls `closePaneIfEmpty`; if it was
the lone pane's last tab → `clearActive()` (empty state).

Note on shared OpenTab across panes: splitRight puts the SAME `OpenTab` value in
the right pane. Since `OpenTab` is a value type, the two panes hold independent
snapshots after the split — editing in one writes back to its own pane's copy.
Opening the same file in both panes is allowed (two independent snapshots); on
save the last write wins, acceptable for v1 (documented).

### 2.3 reconcile (reloadTree)

`reconcileTabs` iterates **every tab in every pane** (not just `tabs`): close
vanished tabs (and `closePaneIfEmpty`), and detect external edits — the active
pane's active tab uses the live working fields; all others use their snapshot.

### 2.4 UI (HanjiApp/ContentView)

- `editorPane` renders the panes: one pane → today's single column; two panes →
  `HSplitView { paneView(panes[0]); paneView(panes[1]) }`.
- `paneView(pane)` = `TabBarView(pane:)` + inline title + conflict banner +
  `MarkdownEditorView`. Binding rule:
  - active pane → `text: $appState.activeText` (live);
  - inactive pane → `text: .constant(pane.activeTab.text)` (snapshot display).
- `MarkdownEditorView` gains `onFocus: (() -> Void)?`, fired when its text view
  becomes first responder (a `becomeFirstResponder`/`mouseDown` hook). Each pane
  passes `onFocus: { appState.focusPane(pane.id) }`. The active pane is visually
  indicated (e.g., a subtle top accent or the inactive pane dimmed).
- `TabBarView` takes a `pane` (its tabs/active), and its tap/close act on that
  pane (focus the pane first if needed, then switch/close).
- Commands: **Split Right** (⌘\\ in a Go/View menu) → `splitRight()`. ⌘W closes
  the active pane's active tab (existing command, now pane-aware).

## 3. Testing

Headless (real AppState + temp vault):
- `splitRight` → `panes.count == 2`, right pane active, same doc; `splitRight`
  again is a no-op.
- `focusPane` writes back + hydrates: edit in pane A, `focusPane(B)`, edit B,
  `focusPane(A)` → A's edit preserved and on disk after flush.
- open targets the active pane: after `splitRight`, `open(C)` adds C to the right
  pane's tabs (not the left).
- closing the last tab of a pane removes that pane and re-activates the other;
  closing the last tab of a lone pane clears the working state.
- `reconcileTabs` across panes: external edit to a tab in the inactive pane
  reloads its snapshot; vanished tab in either pane is closed.
- proxy correctness: `tabs`/`activeTabID`/`selectedFile`/`activeText` reflect the
  active pane.

UI: screenshot a 2-pane split (different note in each), with the active pane
indicated.

## 4. Out of scope

3+ panes; vertical (top/bottom) split; dragging a tab between panes; per-pane
right sidebars; synced scroll; linked panes.
