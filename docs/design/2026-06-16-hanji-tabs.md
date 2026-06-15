# Editor Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open multiple notes as tabs; each tab is an independent buffer (text, dirty, conflict). Clicking a note opens or focuses its tab; ⌘W closes the active tab.

**Architecture:** AppState keeps its existing single-doc `@Published` fields as the **active tab's working state**. `tabs: [OpenTab]` are saved snapshots; switching writes the working state back into the outgoing tab and hydrates from the incoming one. The editor binding (`$appState.activeText`), autosave (`$activeText`), and all SDK publishers stay unchanged — only `open`/`switchTab`/`closeTab`/`rename`, `reloadTree`'s reconcile, and a `TabBarView` are new.

**Tech Stack:** Swift 5.10/SPM, SwiftUI, Combine, custom Checks runner. No new deps.

**Spec:** `docs/design/2026-06-16-hanji-tabs-design.md`

**Conventions:** TDD via `Sources/Checks` (`expect`/`expectEqual`, register in `main.swift`, `swift run Checks <Group>`); commits to main, trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. READ files before editing. `MarkdownFile(url:)` is a public init (AppState already uses it).

---

## File structure

- Create `Sources/AppCore/OpenTab.swift` — `OpenTab` snapshot + `Array[safe:]`.
- Modify `Sources/AppCore/AppState.swift` — `tabs`/`activeTabID`, write-back/hydrate/clear helpers, tab-aware `open`/`switchTab`/`closeTab`, in-place `rename`, `openVault` reset, `reloadTree` reconcile.
- Create `Sources/HanjiApp/TabBarView.swift` — the tab strip.
- Modify `Sources/HanjiApp/ContentView.swift` — show the tab bar in `editorPane`.
- Modify `Sources/HanjiApp/HanjiApp.swift` — ⌘W close-tab command.
- Create `Sources/Checks/TabChecks.swift`; register in `Sources/Checks/main.swift`.

---

## Task 1: Multi-document model — open / switch / close / rename

**Files:**
- Create: `Sources/AppCore/OpenTab.swift`
- Modify: `Sources/AppCore/AppState.swift`
- Create: `Sources/Checks/TabChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — `Sources/Checks/TabChecks.swift`

```swift
import Foundation
import AppCore
import VaultKit
import MKSearchKit

private func tabVault() -> URL {
    let v = FileManager.default.temporaryDirectory.appendingPathComponent("mk-tab-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
    try? "alpha".write(to: v.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
    try? "beta".write(to: v.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
    return v
}
private func tabState(_ vault: URL) -> AppState {
    let s = AppState(defaults: UserDefaults(suiteName: "mk-tab-\(UUID().uuidString)")!)
    s.openVault(at: vault)
    return s
}
private func tabCleanup(_ vault: URL) {
    try? FileManager.default.removeItem(at: SearchIndex.indexFileURL(forVault: vault))
    try? FileManager.default.removeItem(at: vault)
}

func tabChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }) else { expect(false, "files"); return }

    // Open builds tabs and tracks the active working state.
    s.open(a)
    expectEqual(s.tabs.count, 1, "one tab after opening A")
    expectEqual(s.selectedFile?.name, "A.md", "A active")
    s.open(b)
    expectEqual(s.tabs.count, 2, "two tabs")
    expectEqual(s.selectedFile?.name, "B.md", "B active")

    // Re-opening an open note focuses it (no duplicate).
    s.open(a)
    expectEqual(s.tabs.count, 2, "no duplicate tab")
    expectEqual(s.selectedFile?.name, "A.md", "A re-activated")

    // Edits survive tab switches and reach disk.
    s.activeText = "alpha edited"
    s.switchTab(s.tabs.first(where: { $0.file.name == "B.md" })!.id)
    expectEqual(s.selectedFile?.name, "B.md", "switched to B")
    s.switchTab(s.tabs.first(where: { $0.file.name == "A.md" })!.id)
    expectEqual(s.activeText, "alpha edited", "A's edit preserved across switches")
    expectEqual(try? String(contentsOf: vault.appendingPathComponent("A.md"), encoding: .utf8),
                "alpha edited", "switching flushed A to disk")

    // Closing the active tab activates a neighbor; closing the last clears.
    let aID = s.tabs.first(where: { $0.file.name == "A.md" })!.id
    s.closeTab(aID)
    expectEqual(s.tabs.count, 1, "one tab after close")
    expectEqual(s.selectedFile?.name, "B.md", "neighbor B active")
    s.closeTab(s.activeTabID!)
    expect(s.tabs.isEmpty, "no tabs left")
    expect(s.activeTabID == nil && s.selectedFile == nil && s.activeText == "", "cleared active state")

    // Rename updates the open tab in place (no new tab, no stale tab).
    s.open(a)
    _ = try? s.rename(a.url, to: "Renamed")
    expectEqual(s.tabs.count, 1, "rename keeps a single tab")
    expectEqual(s.selectedFile?.name, "Renamed.md", "active file renamed in place")
    expectEqual(s.tabs.first?.file.name, "Renamed.md", "tab file renamed in place")
}
```

- [ ] **Step 2: Register** — add `("Tabs", tabChecks),` in `Sources/Checks/main.swift` (near `("Autosave", …)`).

- [ ] **Step 3: Run test to verify it fails** — `swift run Checks Tabs` → build failure (`value of type 'AppState' has no member 'tabs'`).

- [ ] **Step 4: Create `Sources/AppCore/OpenTab.swift`**

```swift
import Foundation
import VaultKit

/// A saved snapshot of one open tab. The ACTIVE tab's live state lives in
/// AppState's `selectedFile`/`activeText`/`savedText`/`externalConflict`
/// working fields; this snapshot is written back on switch/close.
public struct OpenTab: Identifiable, Equatable {
    public let id: UUID
    public var file: MarkdownFile
    public var text: String
    public var savedText: String
    public var externalConflict: String?
    public var isDirty: Bool { text != savedText }
    public init(file: MarkdownFile, text: String) {
        self.id = UUID()
        self.file = file
        self.text = text
        self.savedText = text
        self.externalConflict = nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

- [ ] **Step 5: Add tab state + helpers to `AppState.swift`** — add near the other `@Published` properties:

```swift
    @Published public private(set) var tabs: [OpenTab] = []
    @Published public private(set) var activeTabID: UUID?
```

Add these private helpers (place them just above `open(_:)`):

```swift
    /// Copy the live working state into the active tab's snapshot.
    private func writeBackActive() {
        guard let id = activeTabID, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].text = activeText
        tabs[idx].savedText = savedText
        tabs[idx].externalConflict = externalConflict
    }
    /// Load the working state from a tab snapshot.
    private func hydrate(from tab: OpenTab) {
        selectedFile = tab.file
        activeText = tab.text
        savedText = tab.savedText
        externalConflict = tab.externalConflict
        conflictPaused = (tab.externalConflict != nil)
        pendingCursorOffset = 0
    }
    private func clearActive() {
        activeTabID = nil
        selectedFile = nil
        activeText = ""
        savedText = ""
        externalConflict = nil
        conflictPaused = false
    }
    /// Synchronous write of a non-active tab's snapshot if dirty.
    private func flush(_ tab: OpenTab) {
        guard tab.isDirty, let vault else { return }
        try? vault.write(tab.text, to: tab.file)
        scheduleReindex()
    }
```

- [ ] **Step 6: Replace `open(_:)` and add `switchTab`/`closeTab`** — replace the existing `open(_:)` with:

```swift
    public func open(_ file: MarkdownFile) {
        if let existing = tabs.first(where: { $0.file.url.standardizedFileURL == file.url.standardizedFileURL }) {
            switchTab(existing.id); return
        }
        flushPendingSave()        // save the outgoing tab to disk
        writeBackActive()         // persist its working state into its snapshot
        let text = (try? vault?.read(file)) ?? ""
        let tab = OpenTab(file: file, text: text)
        tabs.append(tab)
        activeTabID = tab.id
        hydrate(from: tab)
    }

    /// Make an already-open tab active.
    public func switchTab(_ id: UUID) {
        guard id != activeTabID, let tab = tabs.first(where: { $0.id == id }) else { return }
        flushPendingSave()
        writeBackActive()
        activeTabID = id
        hydrate(from: tab)
    }

    /// Close a tab (saving it if dirty); a neighbor becomes active, or the
    /// editor clears if it was the last tab.
    public func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == activeTabID
        if wasActive { flushPendingSave() } else { flush(tabs[idx]) }
        tabs.remove(at: idx)
        if wasActive {
            if let next = tabs[safe: idx] ?? tabs.last {
                activeTabID = next.id
                hydrate(from: next)
            } else {
                clearActive()
            }
        }
    }
```

- [ ] **Step 7: Rename in place + openVault reset** — replace `rename(_:to:)` with the tab-aware version:

```swift
    @discardableResult
    public func rename(_ url: URL, to newName: String) throws -> URL {
        guard let v = vault else { throw VaultError.invalidName }
        let newURL = try v.rename(url, to: newName)
        if newURL.standardizedFileURL != url.standardizedFileURL {
            fileOperations.append(.renamed(from: url, to: newURL))
            let newFile = MarkdownFile(url: newURL)
            if let idx = tabs.firstIndex(where: { $0.file.url.standardizedFileURL == url.standardizedFileURL }) {
                tabs[idx].file = newFile
            }
            if selectedFile?.url.standardizedFileURL == url.standardizedFileURL { selectedFile = newFile }
        }
        reloadTree()
        return newURL
    }
```
(Confirm the existing `rename` signature/return matches — it returns `URL` and is `@discardableResult` or not; keep the existing attribute. If the old body had a `wasOpen`/`open(f)` tail, it is fully replaced by the above.)

In `openVault(at:)`, where it resets `selectedFile = nil` / `activeText = ""`, also add:
```swift
        tabs = []
        activeTabID = nil
```

- [ ] **Step 8: Run the test to verify it passes** — `swift run Checks Tabs` → PASS. Then `swift run Checks Autosave && swift run Checks Conflict && swift run Checks E2E` (existing single-doc behavior still works through tabs), then full `swift run Checks`.

- [ ] **Step 9: Commit**

```bash
git add Sources/AppCore/OpenTab.swift Sources/AppCore/AppState.swift Sources/Checks/TabChecks.swift Sources/Checks/main.swift
git commit -m "feat(tabs): multi-document model — open/switch/close/rename over OpenTab snapshots" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: reloadTree reconcile across all tabs

**Files:**
- Modify: `Sources/AppCore/AppState.swift`
- Modify: `Sources/Checks/TabChecks.swift` (append a group)
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — append to `Sources/Checks/TabChecks.swift`:

```swift
func tabReloadChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }) else { expect(false, "files"); return }
    s.open(a); s.open(b)   // A inactive (clean, flushed), B active

    // External edit to an inactive, clean tab → silent reload into its snapshot.
    try? "alpha external".write(to: vault.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
    s.reloadTree()
    let aTab = s.tabs.first { $0.file.name == "A.md" }
    expectEqual(aTab?.text, "alpha external", "inactive clean tab reloaded from disk")
    expect(aTab?.externalConflict == nil, "no conflict for clean inactive tab")
    expect(s.externalConflict == nil, "active B unaffected")

    // External edit conflicting with the ACTIVE tab's unsaved buffer → banner.
    s.activeText = "beta unsaved"
    try? "beta external".write(to: vault.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
    s.reloadTree()
    expectEqual(s.externalConflict, "beta external", "active dirty tab raises a conflict")

    // A vanished file closes its tab.
    try? FileManager.default.removeItem(at: vault.appendingPathComponent("A.md"))
    s.reloadTree()
    expect(!s.tabs.contains { $0.file.name == "A.md" }, "vanished file's tab closed")
}
```

- [ ] **Step 2: Register** — add `("TabReload", tabReloadChecks),` in `main.swift` after `("Tabs", …)`.

- [ ] **Step 3: Run test to verify it fails** — `swift run Checks TabReload` → fails (inactive tab not reloaded / tab not closed) because `reloadTree` only handles the active document.

- [ ] **Step 4: Replace `reloadTree`'s conflict block with a per-tab reconcile** — in `AppState.swift`, replace the body from `if let sel = selectedFile, !FileManager…` through the external-edit `if externalConflict == nil, …` block (the active-only logic) with a single call, and add the reconcile method:

```swift
    public func reloadTree() {
        guard let v = vault else { return }
        tree = (try? v.tree(sort: treeSort)) ?? []
        files = (try? v.markdownFiles()) ?? files
        reconcileTabs()
        scheduleReindex()
    }

    /// Reconcile every open tab against disk after an FS change: close tabs whose
    /// file vanished; for surviving tabs detect external edits (the active tab
    /// uses the live working fields, others their snapshot).
    private func reconcileTabs() {
        guard let vault else { return }
        let fm = FileManager.default
        for gone in tabs.filter({ !fm.fileExists(atPath: $0.file.url.path) }) {
            removeTabSilently(gone.id)
        }
        for idx in tabs.indices {
            let isActive = tabs[idx].id == activeTabID
            let baseline = isActive ? savedText : tabs[idx].savedText
            guard let disk = try? vault.read(tabs[idx].file), disk != baseline else { continue }
            let alreadyConflicting = isActive ? (externalConflict != nil) : (tabs[idx].externalConflict != nil)
            if alreadyConflicting { continue }
            let dirty = isActive ? isDirty : tabs[idx].isDirty
            if dirty {
                if isActive { conflictPaused = true; externalConflict = disk }
                else { tabs[idx].externalConflict = disk }
            } else {
                if isActive { activeText = disk; savedText = disk }
                else { tabs[idx].text = disk; tabs[idx].savedText = disk }
            }
        }
    }

    /// Remove a tab without saving (its file is gone); reactivate a neighbor.
    private func removeTabSilently(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == activeTabID
        tabs.remove(at: idx)
        if wasActive {
            if let next = tabs[safe: idx] ?? tabs.last { activeTabID = next.id; hydrate(from: next) }
            else { clearActive() }
        }
    }
```
(Keep the existing conflict-resolution methods `resolveConflictReloadingDisk`/`resolveConflictKeepingMine` — they act on the active working fields, unchanged.)

- [ ] **Step 5: Run the test to verify it passes** — `swift run Checks TabReload` → PASS; then `swift run Checks Tabs && swift run Checks Conflict && swift run Checks Autosave && swift run Checks E2E`; then full `swift run Checks`.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppCore/AppState.swift Sources/Checks/TabChecks.swift Sources/Checks/main.swift
git commit -m "feat(tabs): reconcile every open tab against disk on reload (per-tab conflict)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Tab bar UI + ⌘W

**Files:**
- Create: `Sources/HanjiApp/TabBarView.swift`
- Modify: `Sources/HanjiApp/ContentView.swift`
- Modify: `Sources/HanjiApp/HanjiApp.swift`

- [ ] **Step 1: Create `Sources/HanjiApp/TabBarView.swift`**

```swift
import SwiftUI
import AppCore

/// Horizontal strip of open-note tabs above the editor. The active tab's dirty
/// state comes from the live working buffer; other tabs from their snapshot.
struct TabBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if !appState.tabs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(appState.tabs) { tab in
                        tabItem(tab)
                        Divider().frame(height: 16)
                    }
                }
            }
            .frame(height: 32)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }

    private func tabItem(_ tab: OpenTab) -> some View {
        let isActive = tab.id == appState.activeTabID
        let dirty = isActive ? appState.isDirty : tab.isDirty
        return HStack(spacing: 6) {
            Text(tab.file.url.deletingPathExtension().lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
            if dirty {
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
            }
            Button { appState.closeTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { appState.switchTab(tab.id) }
    }
}
```

- [ ] **Step 2: Show the tab bar in `editorPane`** — in `ContentView.swift`, make `TabBarView()` the first child of the `editorPane` `VStack` (above the `if appState.selectedFile != nil` block):

```swift
    @ViewBuilder private var editorPane: some View {
        VStack(spacing: 0) {
            TabBarView()
            if let selected = appState.selectedFile {
                // … existing inline title / conflict banner / editor …
```
(Leave the rest of `editorPane` unchanged.)

- [ ] **Step 3: ⌘W closes the active tab** — in `HanjiApp.swift` `.commands`, add (e.g. inside a `CommandGroup(after: .saveItem)` or a new `CommandMenu`):

```swift
            CommandGroup(after: .saveItem) {
                Button("Close Tab") {
                    if let id = appState.activeTabID { appState.closeTab(id) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
```
(⌘W now closes the active tab; the window is closed via the red button or ⌘Q. This matches Obsidian.)

- [ ] **Step 4: Verify** — `swift build` ✅; full `swift run Checks` ✅; `./Scripts/e2e.sh` ✅. Then a screenshot pass (the controller): open two notes, capture the tab bar (one tab dirty after an edit).

- [ ] **Step 5: Commit**

```bash
git add Sources/HanjiApp/TabBarView.swift Sources/HanjiApp/ContentView.swift Sources/HanjiApp/HanjiApp.swift
git commit -m "feat(tabs): tab bar UI + ⌘W close-tab" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review (vs spec)

- §2.1 OpenTab → Task 1 Step 4. §2.2 tabs/activeTabID + open/switchTab/closeTab + write-back/hydrate/clear + rename-in-place + openVault reset → Task 1 Steps 5–7. §2.3 per-tab autosave/conflict (autosave on `$activeText` unchanged; reconcile all tabs; switching flushes so inactive tabs are clean) → Task 2. §2.4 TabBarView + editorPane + ⌘W → Task 3. §3 tests → Tasks 1–2 (open/dup/switch-preserves-edit/close-neighbor/close-last/rename; inactive reload, active conflict, vanished-close).
- Type consistency: `OpenTab{id,file,text,savedText,externalConflict,isDirty}`, `tabs`/`activeTabID`, `open/switchTab/closeTab`, `writeBackActive/hydrate/clearActive/flush(_:)/reconcileTabs/removeTabSilently`, `Array[safe:]` — consistent across tasks.
- Backward compat: `selectedFile`/`activeText`/`savedText`/`externalConflict`/`pendingCursorOffset` stay stored `@Published` (so `$selectedFile`/`$activeText` subscribers in Host keep working); editor binding + autosave + conflict banner + inline title unchanged. Pinned simplification: per-tab live caret memory is **not** captured (AppState can't read the editor caret) — switching restores the caret to the top (`pendingCursorOffset = 0`); documented, out of scope.
- Risk: ⌘W hijacks window-close globally → documented (use red button / ⌘Q). Switching always flushes the outgoing tab (Obsidian-style autosave) so inactive tabs are never dirty — reconcile relies on this but still guards per-tab `isDirty`.
