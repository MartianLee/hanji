# hanji — Autosave + External-Edit Conflict (G1)

Design doc · 2026-06-14 · Epic G, slice 1 (data safety) of the v1 close-out.
Closes the PRD §7 external-edit handling and fixes a pre-existing data-loss bug.

## 1. Problem

Today the editor binds `$appState.activeText`; `open(_:)` overwrites `activeText`
with the new note's contents **without saving the previous note**, and there is
**no ⌘S and no autosave** — only a toolbar "Save" button. Two gaps:

1. Switching notes (or quitting) with unsaved edits **silently discards them**.
2. An external edit (Finder, git, iCloud/Dropbox sync) to the open note is never
   surfaced; the FS watcher rebuilds the tree/index but leaves the editor buffer
   stale, and the next save clobbers the external change.

## 2. Decisions (locked)

- **Save model:** Autosave, Obsidian-style — debounced after typing + flush on
  note switch + flush on quit. No manual ⌘S required (a Save command may stay).
- **Dirty tracking:** content-based, not mtime. `AppState.savedText` is the
  disk baseline for the open note; `isDirty == (activeText != savedText)`.
  Content comparison is immune to sync/touch mtime jitter and naturally treats
  our own write as "no external change" (after a save, `savedText == activeText
  == disk`).
- **Conflict UX:** non-modal banner at the top of the editor. A clean buffer
  reloads silently; only a dirty buffer prompts.
- **Conflict actions:** "Reload from disk" (discard mine) and "Keep my edits"
  (mine wins on the next autosave).

## 3. Flow

```
 typing ──▶ activeText changes ──▶ debounce 0.8s ──▶ isDirty?
                                                       │yes
                                                       ▼
                                         vault.write(activeText)
                                         savedText = activeText ; reindex
                                                       │
        ┌──────────────────────────────────────────────┘
        ▼
 open(new): if old isDirty → flush old, then load new (activeText=savedText=read)
 quit/scenePhase background: flush

 VaultWatcher ─▶ reloadTree ─▶ open file diskText = read(open)
     diskText == savedText ───────────────▶ ignore (no external change / our write)
     diskText != savedText ──┬─ !isDirty ─▶ silent reload (activeText=savedText=diskText)
                             └─  isDirty ─▶ externalConflict = diskText
                                            (banner shown; autosave paused)
 banner "Reload from disk" ─▶ activeText=savedText=diskText; conflict=nil; resume
 banner "Keep my edits"    ─▶ savedText=diskText; conflict=nil  (→ dirty → next
                                                                  autosave writes mine)
```

## 4. Components

### 4.1 `AppState` (AppCore)

New state:
```swift
@Published public var savedText: String = ""          // disk baseline of open note
@Published public var externalConflict: String? = nil // disk version awaiting resolution
public var isDirty: Bool { activeText != savedText }
private var autosaveCancellable: AnyCancellable?
private var conflictPaused = false                     // suspend autosave during a conflict
```

Autosave wiring (in `init`, debounce injectable for tests — default 0.8s):
```swift
autosaveCancellable = $activeText
    .debounce(for: .seconds(autosaveInterval), scheduler: RunLoop.main)
    .sink { [weak self] _ in self?.flushPendingSave() }
```
```swift
/// Write the buffer if dirty and not paused for a conflict. Safe to call
/// directly (tests, note switch, quit).
public func flushPendingSave() {
    guard !conflictPaused, isDirty, let file = selectedFile, let vault else { return }
    try? vault.write(activeText, to: file)
    savedText = activeText
    scheduleReindex()
}
```

`open(_:)` saves the outgoing note first, then rebaselines:
```swift
public func open(_ file: MarkdownFile) {
    flushPendingSave()                       // don't lose edits on the previous note
    selectedFile = file
    let text = (try? vault?.read(file)) ?? ""
    activeText = text
    savedText = text
    externalConflict = nil
    conflictPaused = false
}
```

`openVault` resets `savedText = ""`, `externalConflict = nil`. The existing
`save()` becomes `flushPendingSave()` (keep the method/command name for the
toolbar/menu, but route through the dirty check).

External-change detection — extend `reloadTree()` after the tree/index rebuild:
```swift
if let file = selectedFile, FileManager.default.fileExists(atPath: file.url.path),
   let diskText = try? vault?.read(file), diskText != savedText {
    if isDirty {
        conflictPaused = true
        externalConflict = diskText          // banner
    } else {
        activeText = diskText                 // clean buffer → silent reload
        savedText = diskText
    }
}
```
(The existing "open file disappeared → clear editor" branch stays.)

Resolution methods:
```swift
public func resolveConflictReloadingDisk() {
    guard let diskText = externalConflict else { return }
    activeText = diskText
    savedText = diskText
    externalConflict = nil
    conflictPaused = false
}
public func resolveConflictKeepingMine() {
    guard let diskText = externalConflict else { return }
    savedText = diskText                      // now activeText != savedText → dirty
    externalConflict = nil
    conflictPaused = false
    flushPendingSave()                        // write my version over disk
}
```

⚠️ Our own autosave write triggers the watcher → `reloadTree` → reads disk ==
`savedText` (just set) → ignored. No self-conflict.

### 4.2 ContentView banner (HanjiApp)

Above `MarkdownEditorView`, when `appState.externalConflict != nil`:
```swift
if appState.externalConflict != nil {
    HStack(spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        Text("This note changed on disk.")
        Spacer()
        Button("Reload from disk") { appState.resolveConflictReloadingDisk() }
        Button("Keep my edits") { appState.resolveConflictKeepingMine() }
    }
    .padding(8)
    .background(Color.orange.opacity(0.15))
}
```

### 4.3 Quit/background flush

In `HanjiApp`, observe `scenePhase`; on `.background`/`.inactive` call
`appState.flushPendingSave()`. (Covers ⌘Q and window close on macOS.)

## 5. Testing

Headless (real `AppState` + temp vault; construct with `autosaveInterval` 0 or
call `flushPendingSave()` directly — do not rely on the debounce timer):

- **autosave flush:** set `activeText`, `flushPendingSave()` → disk file equals it.
- **no-lose-on-switch:** open A, edit (dirty), `open(B)` → A's file on disk has
  the edit; B loads clean.
- **clean external reload:** open A (clean), write A's file externally,
  `reloadTree()` → `activeText` equals the external text, no conflict.
- **dirty external conflict:** open A, edit (dirty), write A externally,
  `reloadTree()` → `externalConflict != nil`, `activeText` unchanged (mine),
  autosave paused (a `flushPendingSave()` is a no-op).
- **resolve reload:** from the conflict, `resolveConflictReloadingDisk()` →
  `activeText`/`savedText` == disk, `externalConflict == nil`.
- **resolve keep-mine:** from the conflict, `resolveConflictKeepingMine()` →
  disk file equals my buffer, `externalConflict == nil`.
- **own-write no false conflict:** edit, `flushPendingSave()`, then
  `reloadTree()` → no conflict (disk == savedText).

E2E step: open a note, simulate an external edit by writing the file directly,
call `reloadTree()`, assert the clean-buffer reload path updates `activeText`.

Visual: screenshot the conflict banner (capture the hanji window by id since
its window sits on a secondary display).

## 6. Out of scope

3-way merge / diff view; rename-while-open conflicts; a queue for simultaneous
conflicts across multiple notes (only the single open note is handled); per-note
autosave-interval settings.
