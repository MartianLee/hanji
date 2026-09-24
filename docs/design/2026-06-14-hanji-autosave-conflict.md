# Autosave + External-Edit Conflict Implementation Plan

**Goal:** Add Obsidian-style autosave (debounced + flush on note switch/quit) with content-based dirty tracking, and surface external edits to the open note via a non-modal conflict banner.

**Architecture:** `AppState` gains a `savedText` disk baseline (`isDirty = activeText != savedText`), a debounced `$activeText` autosave that routes through `flushPendingSave()`, an outgoing-note flush in `open(_:)`, external-change detection appended to `reloadTree()`, and two conflict-resolution methods. `ContentView` shows a banner when `externalConflict != nil`; `HanjiApp` flushes on `scenePhase` background.

**Tech Stack:** Swift 5.10/SPM, Combine, SwiftUI, custom Checks runner. No new dependencies.

**Spec:** `docs/design/2026-06-14-hanji-autosave-conflict-design.md`

**Conventions:** TDD via `Sources/Checks` (`expect`/`expectEqual`, register in `main.swift`, `swift run Checks <Group>`); commits to main. Tests construct `AppState` and drive it directly (`flushPendingSave()`, `reloadTree()`) — never rely on the debounce timer or the FS watcher firing (main runloop isn't spinning headless). READ files before editing.

---

## File structure

- Modify `Sources/AppCore/AppState.swift` — `savedText`/`externalConflict`/`isDirty`, autosave pipeline, `flushPendingSave`, `open` flush, `reloadTree` conflict detection, resolution methods, `save` alias.
- Modify `Sources/HanjiApp/ContentView.swift` — conflict banner above the editor.
- Modify `Sources/HanjiApp/HanjiApp.swift` — `scenePhase` flush.
- Create `Sources/Checks/AutosaveChecks.swift` — `autosaveChecks` + `conflictChecks`.
- Modify `Sources/Checks/main.swift` — register both groups.
- Modify `Sources/Checks/E2EChecks.swift` — external-edit reload step.

---

## Task 1: Dirty tracking + autosave

**Files:**
- Modify: `Sources/AppCore/AppState.swift`
- Create: `Sources/Checks/AutosaveChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — `Sources/Checks/AutosaveChecks.swift`

```swift
import Foundation
import AppCore
import VaultKit
import MKSearchKit

private func tempVault(_ prefix: String) -> URL {
    let v = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
    return v
}

private func newState(_ vault: URL) -> AppState {
    let s = AppState(defaults: UserDefaults(suiteName: "mk-as-\(UUID().uuidString)")!)
    s.openVault(at: vault)
    return s
}

private func cleanup(_ vault: URL) {
    try? FileManager.default.removeItem(at: SearchIndex.indexFileURL(forVault: vault))
    try? FileManager.default.removeItem(at: vault)
}

func autosaveChecks() {
    let vault = tempVault("mk-autosave")
    defer { cleanup(vault) }
    try? "alpha original".write(to: vault.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
    try? "beta original".write(to: vault.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)

    let s = newState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }) else { expect(false, "files found"); return }

    // Open is clean; editing makes it dirty.
    s.open(a)
    expectEqual(s.savedText, "alpha original", "baseline captured on open")
    expect(!s.isDirty, "freshly opened note is clean")
    s.activeText = "alpha edited"
    expect(s.isDirty, "edited note is dirty")

    // flushPendingSave writes to disk and rebaselines.
    s.flushPendingSave()
    expect(!s.isDirty, "clean after flush")
    let onDisk = try? String(contentsOf: vault.appendingPathComponent("A.md"), encoding: .utf8)
    expectEqual(onDisk, "alpha edited", "flush wrote to disk")

    // Switching notes flushes the outgoing edit (no data loss).
    s.activeText = "alpha edited again"
    s.open(b)
    expectEqual(s.savedText, "beta original", "B baseline loaded")
    let aAfterSwitch = try? String(contentsOf: vault.appendingPathComponent("A.md"), encoding: .utf8)
    expectEqual(aAfterSwitch, "alpha edited again", "switching saved A's edit")

    // flush is a no-op when clean (does not rewrite identical content).
    s.open(a)
    expect(!s.isDirty, "reopened clean")
    s.flushPendingSave()   // should not throw / change anything
    expect(!s.isDirty, "still clean after no-op flush")
}
```

- [ ] **Step 2: Register** — add `("Autosave", autosaveChecks),` in `Sources/Checks/main.swift` (after `("AppState", ...)` or near the AppState groups).

- [ ] **Step 3: Run test to verify it fails**

Run: `swift run Checks Autosave`
Expected: build failure — `value of type 'AppState' has no member 'savedText'`.

- [ ] **Step 4: Implement in `Sources/AppCore/AppState.swift`**

Add `import Combine` if not already present (it is). Add the new published state near the other `@Published` properties:
```swift
    /// Disk baseline of the open note; the buffer is dirty when it differs.
    @Published public var savedText: String = ""
    /// External (on-disk) version of the open note awaiting conflict resolution.
    @Published public var externalConflict: String? = nil
    public var isDirty: Bool { activeText != savedText }
```
Add private members near `watcher`:
```swift
    private var autosaveCancellable: AnyCancellable?
    private var conflictPaused = false
    private let autosaveInterval: TimeInterval
```
Change the init signature and append the autosave pipeline at the end of `init`:
```swift
    public init(defaults: UserDefaults = .standard, autosaveInterval: TimeInterval = 0.8) {
        self.defaults = defaults
        self.autosaveInterval = autosaveInterval
        // ... existing body (recents/treeSort/fontSize restore) unchanged ...
        autosaveCancellable = $activeText
            .debounce(for: .seconds(autosaveInterval), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.flushPendingSave() }
    }
```
Replace `open(_:)`:
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
Replace `save()` with a flush alias and add `flushPendingSave()`:
```swift
    /// Toolbar/menu "Save" — writes only if there are unsaved changes.
    public func save() { flushPendingSave() }

    /// Write the buffer if dirty and not paused for a conflict. Safe to call
    /// directly (tests, note switch, quit); idempotent when clean.
    public func flushPendingSave() {
        guard !conflictPaused, isDirty, let file = selectedFile, let vault else { return }
        try? vault.write(activeText, to: file)
        savedText = activeText
        scheduleReindex()
    }
```
In `openVault(at:)`, after `activeText = ""` add:
```swift
        savedText = ""
        externalConflict = nil
        conflictPaused = false
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift run Checks Autosave`
Expected: PASS (all assertions). Then `swift run Checks` (full suite green — existing AppState/E2E groups still pass; `save()` now routes through the dirty check).

- [ ] **Step 6: Commit**

```bash
git add Sources/AppCore/AppState.swift Sources/Checks/AutosaveChecks.swift Sources/Checks/main.swift
git commit -m "feat(editor): content-based dirty tracking + debounced autosave (flush on switch)"
```

---

## Task 2: External-edit detection + conflict resolution

**Files:**
- Modify: `Sources/AppCore/AppState.swift`
- Modify: `Sources/Checks/AutosaveChecks.swift` (append `conflictChecks`)
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — append to `Sources/Checks/AutosaveChecks.swift`

```swift
func conflictChecks() {
    let vault = tempVault("mk-conflict")
    defer { cleanup(vault) }
    let aURL = vault.appendingPathComponent("A.md")
    try? "v1".write(to: aURL, atomically: true, encoding: .utf8)

    let s = newState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }) else { expect(false, "A found"); return }
    s.open(a)

    // Clean buffer + external change → silent reload.
    try? "external v2".write(to: aURL, atomically: true, encoding: .utf8)
    s.reloadTree()
    expect(s.externalConflict == nil, "clean buffer does not raise a conflict")
    expectEqual(s.activeText, "external v2", "clean buffer reloaded from disk")
    expect(!s.isDirty, "reloaded buffer is clean")

    // Our own write does NOT raise a false conflict.
    s.activeText = "my v3"
    s.flushPendingSave()
    s.reloadTree()
    expect(s.externalConflict == nil, "our own save is not a conflict")
    expectEqual(s.activeText, "my v3", "buffer unchanged after own-write reload")

    // Dirty buffer + external change → conflict, autosave paused.
    s.activeText = "my v4 (unsaved)"
    expect(s.isDirty, "dirty before external change")
    try? "external v4".write(to: aURL, atomically: true, encoding: .utf8)
    s.reloadTree()
    expectEqual(s.externalConflict, "external v4", "conflict captured disk version")
    expectEqual(s.activeText, "my v4 (unsaved)", "my edits preserved during conflict")
    s.flushPendingSave()   // paused — must not write
    let duringConflict = try? String(contentsOf: aURL, encoding: .utf8)
    expectEqual(duringConflict, "external v4", "autosave paused during conflict")

    // Resolve: keep mine → my buffer written over disk, conflict cleared.
    s.resolveConflictKeepingMine()
    expect(s.externalConflict == nil, "conflict cleared after keep-mine")
    let kept = try? String(contentsOf: aURL, encoding: .utf8)
    expectEqual(kept, "my v4 (unsaved)", "keep-mine wrote my version to disk")
    expect(!s.isDirty, "clean after keep-mine flush")

    // Resolve: reload from disk → buffer replaced, conflict cleared.
    s.activeText = "my v5 (unsaved)"
    try? "external v5".write(to: aURL, atomically: true, encoding: .utf8)
    s.reloadTree()
    expectEqual(s.externalConflict, "external v5", "second conflict raised")
    s.resolveConflictReloadingDisk()
    expect(s.externalConflict == nil, "conflict cleared after reload")
    expectEqual(s.activeText, "external v5", "reload took the disk version")
    expect(!s.isDirty, "clean after reload")
}
```

- [ ] **Step 2: Register** — add `("Conflict", conflictChecks),` in `main.swift` after `("Autosave", ...)`.

- [ ] **Step 3: Run test to verify it fails**

Run: `swift run Checks Conflict`
Expected: build failure — `has no member 'resolveConflictKeepingMine'`.

- [ ] **Step 4: Implement in `Sources/AppCore/AppState.swift`**

In `reloadTree()`, after the existing disappeared-file branch (`if let sel = selectedFile, !FileManager...`) and before `scheduleReindex()`, add:
```swift
        // Detect external edits to the open note (content-based, so our own
        // writes — where diskText == savedText — never raise a conflict).
        if let file = selectedFile, FileManager.default.fileExists(atPath: file.url.path),
           let diskText = try? vault?.read(file), diskText != savedText {
            if isDirty {
                conflictPaused = true
                externalConflict = diskText        // banner; autosave paused
            } else {
                activeText = diskText               // clean buffer → silent reload
                savedText = diskText
            }
        }
```
Append the resolution methods to the class:
```swift
    /// Conflict banner: discard my unsaved edits and take the on-disk version.
    public func resolveConflictReloadingDisk() {
        guard let diskText = externalConflict else { return }
        activeText = diskText
        savedText = diskText
        externalConflict = nil
        conflictPaused = false
    }

    /// Conflict banner: keep my edits and write them over the on-disk version.
    public func resolveConflictKeepingMine() {
        guard let diskText = externalConflict else { return }
        savedText = diskText                        // now activeText != savedText → dirty
        externalConflict = nil
        conflictPaused = false
        flushPendingSave()                          // write my version to disk
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift run Checks Conflict`
Expected: PASS. Then `swift run Checks Autosave` (still green) and full `swift run Checks`.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppCore/AppState.swift Sources/Checks/AutosaveChecks.swift Sources/Checks/main.swift
git commit -m "feat(editor): external-edit conflict detection + reload/keep-mine resolution"
```

---

## Task 3: Conflict banner + quit flush + E2E

**Files:**
- Modify: `Sources/HanjiApp/ContentView.swift`
- Modify: `Sources/HanjiApp/HanjiApp.swift`
- Modify: `Sources/Checks/E2EChecks.swift`

- [ ] **Step 1: E2E step** — in `Sources/Checks/E2EChecks.swift`, find the local vault-root variable (the dataview step 4d used `root`). After step 4d, insert:

```swift
    // 4e. External-edit reload: a clean buffer picks up an on-disk change.
    let extNote = root.appendingPathComponent("Ext.md")
    try? "before".write(to: extNote, atomically: true, encoding: .utf8)
    appState.reloadTree()
    if let ext = appState.files.first(where: { $0.name == "Ext.md" }) {
        appState.open(ext)
        expectEqual(appState.activeText, "before", "E2E: opened external note")
        try? "after (external)".write(to: extNote, atomically: true, encoding: .utf8)
        appState.reloadTree()
        expectEqual(appState.activeText, "after (external)", "E2E: clean buffer reloaded external edit")
        expect(appState.externalConflict == nil, "E2E: no conflict for clean buffer")
    } else {
        expect(false, "E2E: Ext.md indexed")
    }
```

- [ ] **Step 2: Banner in `Sources/HanjiApp/ContentView.swift`** — in `editorPane`, replace the `if appState.selectedFile != nil { MarkdownEditorView(...) }` branch so the banner sits above the editor:

```swift
            if appState.selectedFile != nil {
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
                MarkdownEditorView(text: $appState.activeText, renderers: appState.rendererRegistry, vaultRoot: appState.vaultRoot, cursorOffset: $appState.pendingCursorOffset, fontSize: CGFloat(appState.fontSize))
            } else {
                Text("Open a vault, then select a note")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
```

- [ ] **Step 3: Quit/background flush in `Sources/HanjiApp/HanjiApp.swift`** — add `@Environment(\.scenePhase) private var scenePhase` near the other property wrappers (after the `@State` declarations), and attach an `onChange` to the `ContentView` in the `WindowGroup` (alongside the existing modifiers, e.g. right after `.frame(minWidth: 900, minHeight: 560)`):

```swift
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { appState.flushPendingSave() }
                }
```

- [ ] **Step 4: Verify** — `swift build` (expect Build complete); `swift run Checks` (full suite green); `./Scripts/e2e.sh` (green).

- [ ] **Step 5: Commit**

```bash
git add Sources/HanjiApp/ContentView.swift Sources/HanjiApp/HanjiApp.swift Sources/Checks/E2EChecks.swift
git commit -m "feat(editor): conflict banner + flush on background/quit + E2E reload step"
```

---

## Self-review (vs spec)

- §2 decisions: autosave (Task 1 debounce + flush), content-based dirty (`savedText`/`isDirty`, Task 1), non-modal banner (Task 3), reload/keep-mine actions (Task 2). §4.1 AppState members/methods → Tasks 1–2 verbatim. §4.2 banner → Task 3. §4.3 scenePhase flush → Task 3. §5 all seven headless cases: flush(T1), no-lose-switch(T1), clean-reload(T2), dirty-conflict(T2), resolve-reload(T2), resolve-keep-mine(T2), own-write-no-false-conflict(T2). E2E reload step → Task 3.
- Type consistency: `savedText`, `externalConflict`, `isDirty`, `flushPendingSave()`, `save()`, `resolveConflictReloadingDisk()`, `resolveConflictKeepingMine()`, `open(_:)`, `reloadTree()`, init `autosaveInterval` — consistent across tasks and matching the spec.
- Pinned risks: tests drive `flushPendingSave`/`reloadTree` directly (no timer/watcher reliance); `open(_:)` flush order (save outgoing BEFORE reassigning `selectedFile`); resolution sets `conflictPaused = false` before `flushPendingSave()` (keep-mine) so the write isn't skipped; own-write no-false-conflict guaranteed by content equality (`diskText == savedText`).
- Visual: conflict banner screenshot deferred to the controller's verification pass (capture the hanji window by id — it sits on a secondary display).
