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

### 2.1 `Document` (AppCore) — one open buffer

```swift
public final class Document: ObservableObject, Identifiable {
    public let id = UUID()
    public let file: MarkdownFile
    @Published public var text: String
    @Published public var savedText: String
    @Published public var externalConflict: String? = nil
    @Published public var pendingCursorOffset: Int? = nil
    var conflictPaused = false
    public var isDirty: Bool { text != savedText }
    public init(file: MarkdownFile, text: String) {
        self.file = file; self.text = text; self.savedText = text
    }
}
```

### 2.2 `AppState` — open documents + active

```swift
@Published public private(set) var documents: [Document] = []
@Published public var activeDocumentID: Document.ID?
public var activeDocument: Document? { documents.first { $0.id == activeDocumentID } }
```

Backward-compatible computed proxies (read paths unchanged for consumers):

```swift
public var selectedFile: MarkdownFile? { activeDocument?.file }
public var activeText: String {            // editor no longer binds this; SDK/readers do
    get { activeDocument?.text ?? "" }
    set { activeDocument?.text = newValue }
}
public var externalConflict: String? { activeDocument?.externalConflict }
public var isDirty: Bool { activeDocument?.isDirty ?? false }
```
(`@Published selectedFile` becomes a computed proxy; views that observed it now
re-render via `activeDocumentID` / the active document's `objectWillChange`
re-broadcast — AppState subscribes to the active document and forwards
`objectWillChange`.)

`open(_:)` becomes:
```swift
public func open(_ file: MarkdownFile) {
    if let existing = documents.first(where: { $0.file.url.standardizedFileURL == file.url.standardizedFileURL }) {
        activate(existing); return
    }
    let text = (try? vault?.read(file)) ?? ""
    let doc = Document(file: file, text: text)
    documents.append(doc)
    activate(doc)
    observeAutosave(doc)
}
private func activate(_ doc: Document) {
    activeDocumentID = doc.id
    rebroadcast(doc)        // forward doc.objectWillChange so proxy readers update
}
public func closeTab(_ id: Document.ID) {
    guard let doc = documents.first(where: { $0.id == id }) else { return }
    flush(doc)              // save if dirty
    documents.removeAll { $0.id == id }
    if activeDocumentID == id { activeDocumentID = documents.last?.id }
}
```

### 2.3 Autosave & conflict (per document)

- `observeAutosave(doc)`: subscribe to `doc.$text.debounce(0.8s)` → background
  write of *that* document; stored in a `[Document.ID: AnyCancellable]` map,
  removed on close.
- `flush(_ doc)` / `flushPendingSave()`: synchronous write of a dirty doc
  (active doc for the menu/quit path; specific doc for tab close).
- `reloadTree`: after the tree rebuild, iterate **all** open documents — for each,
  if it vanished, close its tab; else content-compare against disk and set that
  document's `externalConflict` (dirty) or silently reload (clean), exactly like
  today but per-document.
- Conflict resolution methods take the active document (banner acts on it).

### 2.4 UI (HanjiApp/ContentView)

- New `TabBarView` above the editor in `editorPane`: a horizontal row of tabs
  (`documents`), each showing the file's base name, a dirty dot, and a close (×)
  button; clicking a tab activates it. The active tab is highlighted.
- The editor binds to the **active document**: `MarkdownEditorView(text:
  Binding(get/set on activeDocument.text), …)`. Inline title + conflict banner
  read the active document.
- `⌘W` (CommandGroup) closes the active tab; tree/⌘O/search/link/backlink opens
  route through `AppState.open` (unchanged call sites — they already call `open`).

## 3. Testing

Headless (real AppState + temp vault):
- open A → 1 tab, active; open B → 2 tabs, B active; open A again → still 2 tabs,
  A re-activated (no duplicate).
- edit A (dirty), switch to B, `flushPendingSave()`/close → A saved to disk.
- close active tab → previous tab active; close last → no active document,
  `selectedFile == nil`.
- per-document conflict: two open docs, edit one externally → only that
  document's `externalConflict` set after `reloadTree`.
- proxy correctness: `selectedFile`/`activeText` follow `activeDocumentID`.

UI: screenshot the tab bar with two tabs (one dirty).

## 4. Out of scope

Left/right split (next slice); tab drag-reorder; drag tab between panes; pinned
tabs; ⌘T empty tab; tab overflow menu; per-tab scroll memory beyond cursor.
