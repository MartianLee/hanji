# hanji — Editor Tabs (multi-document)

Design doc · 2026-06-16 · Epic G slice (tabs). Split panes are a separate
follow-up slice that will wrap the tab group in a `Pane` abstraction.

## 1. Goal

Open multiple notes as tabs in the editor area. Each tab is an independent
document buffer (own text, dirty state, conflict, cursor). Clicking a note opens
or focuses its tab; ⌘W closes the active tab. This replaces today's strictly
single-document model (`selectedFile` + `activeText` + …).

### Decisions (locked)

- **Scope:** tabs only. Left/right split is a later slice; do **not** build a
  `Pane` abstraction now (YAGNI). The split slice will move `documents`/active
  into a `Pane`.
- **One buffer per file:** a file opens at most once (no duplicate tabs of the
  same note), so there is never a dual-buffer save conflict.
- **Backward-compatible proxies:** the existing single-doc API
  (`selectedFile`, `activeText`, `savedText`, `externalConflict`,
  `pendingCursorOffset`, `isDirty`) stays, forwarding to the **active document**,
  so Host/SDK, search, backlinks, calendar, and the inline title keep working;
  only the editor's text binding moves to the active document.
- **Open behavior:** opening a note focuses its tab if already open, else appends
  a new tab and activates it.
- **Close:** ⌘W closes the active tab (flushing if dirty); closing the last tab
  shows the empty state.

## 2. Architecture

**Key idea (low-churn):** keep AppState's existing single-doc `@Published`
fields (`selectedFile`, `activeText`, `savedText`, `externalConflict`,
`pendingCursorOffset`, `conflictPaused`) as the **active tab's live working
state**. Tabs are lightweight **saved snapshots**; switching a tab writes the
working state back into the outgoing tab and hydrates the working state from the
incoming tab. The editor binding (`$appState.activeText`), the autosave debounce
(on `$activeText`), and every SDK publisher (`$selectedFile`, `$activeText`)
stay exactly as they are — only `open`, tab-switch, close, and the tab bar are new.

### 2.1 `OpenTab` (AppCore) — a per-tab snapshot

```swift
public struct OpenTab: Identifiable, Equatable {
    public let id = UUID()
    public var file: MarkdownFile
    public var text: String
    public var savedText: String
    public var externalConflict: String?
    public var cursorOffset: Int?
    public var isDirty: Bool { text != savedText }
}
```

### 2.2 `AppState` — tabs + active id (existing fields unchanged)

```swift
@Published public private(set) var tabs: [OpenTab] = []
@Published public private(set) var activeTabID: OpenTab.ID?
// selectedFile / activeText / savedText / externalConflict / pendingCursorOffset
// remain the existing @Published fields = the ACTIVE tab's working state.
```

`open(_:)`:
```swift
public func open(_ file: MarkdownFile) {
    if let existing = tabs.first(where: { $0.file.url.standardizedFileURL == file.url.standardizedFileURL }) {
        switchTab(existing.id); return
    }
    writeBackActive()                          // persist current working state to its tab
    let text = (try? vault?.read(file)) ?? ""
    var tab = OpenTab(file: file, text: text, savedText: text, externalConflict: nil, cursorOffset: 0)
    tabs.append(tab)
    activeTabID = tab.id
    hydrate(from: tab)                          // load working state from the new tab
}

public func switchTab(_ id: OpenTab.ID) {
    guard id != activeTabID, let tab = tabs.first(where: { $0.id == id }) else { return }
    writeBackActive()
    activeTabID = id
    hydrate(from: tab)
}

public func closeTab(_ id: OpenTab.ID) {
    if id == activeTabID { writeBackActive() }
    if let tab = tabs.first(where: { $0.id == id }) { flush(tab) }   // save if dirty
    let wasActive = id == activeTabID
    let idx = tabs.firstIndex { $0.id == id }
    tabs.removeAll { $0.id == id }
    if wasActive {
        let next = tabs[safe: idx ?? 0] ?? tabs.last
        if let next { activeTabID = next.id; hydrate(from: next) } else { clearActive() }
    }
}
```
- `writeBackActive()`: copy `selectedFile/activeText/savedText/externalConflict/
  pendingCursorOffset` into `tabs[active]`.
- `hydrate(from:)`: set those working fields from the tab; set `pendingCursorOffset
  = tab.cursorOffset` so the editor restores the caret; clear `conflictPaused`
  consistent with the tab's conflict.
- `clearActive()`: `activeTabID = nil`, `selectedFile = nil`, `activeText = ""`,
  `savedText = ""`, `externalConflict = nil` (empty state).

### 2.3 Autosave & conflict (multi-tab)

- Autosave stays on `$activeText` → writes the active tab's file (unchanged).
  `flush(_ tab:)` writes a specific dirty tab synchronously (used on tab close).
- `reloadTree`: after the tree rebuild, reconcile **every** open tab against disk:
  - vanished file → remove that tab (if active, switch to a neighbor / clear);
  - the **active** tab → existing content-compare logic on the working fields
    (sets `externalConflict` / silent reload);
  - **inactive** tabs → content-compare against disk and update the tab's stored
    `savedText`/`text`/`externalConflict` snapshot (its banner shows when
    switched to). Keep it simple: clean inactive tab silently re-reads; dirty
    inactive tab stores `externalConflict` in its snapshot.
- Conflict-resolution methods act on the active working state (unchanged).

### 2.4 UI (HanjiApp/ContentView)

- New `TabBarView` above the editor in `editorPane`: a horizontal row over
  `appState.tabs`, each tab = base name + dirty dot + close (×); clicking calls
  `switchTab`. Active tab highlighted. The bar is shown only when ≥1 tab is open
  (a single tab still shows, for the close affordance + consistency).
- Editor, inline title, and conflict banner are **unchanged** (they read the
  active working fields). Opens from tree/⌘O/search/link/backlink already call
  `AppState.open` — now tab-aware automatically.
- `⌘W` (CommandGroup, Go/File menu) → `closeTab(activeTabID)`.
- A small `Array.subscript(safe:)` helper (AppCore) for bounds-safe neighbor pick.

## 3. Testing

Headless (real AppState + temp vault):
- open A → 1 tab, active; open B → 2 tabs, B active; open A again → still 2 tabs,
  A re-activated (no duplicate).
- working state follows tabs: after `open(B)` then `switchTab(A)`,
  `selectedFile == A` and `activeText` == A's content.
- edit A (dirty), `switchTab(B)`, `switchTab(A)` → A's edit preserved in its tab
  (no loss across switches); the edit is on disk after `flushPendingSave`/close.
- close active tab → a neighbor tab becomes active; close last tab → `tabs`
  empty, `activeTabID == nil`, `selectedFile == nil`, `activeText == ""`.
- per-tab conflict: open A and B, edit B's file on disk, `reloadTree` → B's tab
  carries the conflict; A unaffected.

UI: screenshot the tab bar with two tabs (one dirty).

## 4. Out of scope

Left/right split (next slice); tab drag-reorder; drag tab between panes; pinned
tabs; ⌘T empty tab; tab overflow menu; per-tab scroll memory beyond cursor.
