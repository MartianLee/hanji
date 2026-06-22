# Tab Reorder + Send-Tab-to-Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drag a tab to reorder it within its pane, and move a tab into the left/right pane via a context menu or keyboard (creating the second pane when there's room).

**Architecture:** Two new AppState operations over the existing `Pane`/`panes` model. `moveTab(_:before:in:)` is a pure positional change of a pane's `tabs` (active tab and live buffer untouched). `moveTabToSide(_:_:)` moves a tab into the neighbouring pane (merging) or a freshly created pane (splitting), reusing `writeBackActive`/`hydrate`/`closePaneIfEmpty`. UI: SwiftUI `.draggable`/`.dropDestination` on tabs for reorder; a `.contextMenu` + `⌃⌘←/→` commands for send-to-pane.

**Tech Stack:** Swift 5.10/SPM, SwiftUI (macOS 14), custom `Checks` runner. No new dependencies.

**Spec:** `docs/design/2026-06-22-hanji-tab-reorder-split-design.md`

## Global Constraints

- TDD via `Sources/Checks` (zero-dependency runner; Command Line Tools ship no XCTest). Model logic gets a headless check; UI is verified by `swift build` + screenshot.
- Commits go to `main`, message trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- READ each file before editing it.
- Minimum target macOS 14. No new external dependencies (GRDB is the only one).
- `Pane` is a plain class, not `@Published`-observed — **every mutation of a pane's `tabs`/`activeTabID` must be wrapped in `objectWillChange.send()`** so views re-render (mirror the existing `open`/`switchTab`/`closeTab`).
- Existing safety-net checks must stay green: `Tabs`, `PaneProxy`, `PaneSplit`, `TabReload`, `Autosave`, `Conflict`, `E2E`.

---

## File structure

- Modify `Sources/AppCore/AppState.swift` — add `PaneSide`, `moveTab(_:before:in:)`, `canMoveTab(_:_:)`, `moveTabToSide(_:_:)` (near `splitRight`, ~line 305).
- Modify `Sources/Checks/TabChecks.swift` — add `tabReorderChecks` and `paneMoveTabChecks`.
- Modify `Sources/Checks/main.swift` — register both new checks.
- Modify `Sources/HanjiApp/TabBarView.swift` — drag/drop reorder + context menu.
- Modify `Sources/HanjiApp/HanjiApp.swift` — `Move Tab Left/Right` commands.

---

## Task 1: `moveTab` — within-pane reorder (model)

**Files:**
- Modify: `Sources/AppCore/AppState.swift` (add `moveTab`, after `splitRight()` ~line 305)
- Test: `Sources/Checks/TabChecks.swift` (add `tabReorderChecks`)
- Modify: `Sources/Checks/main.swift` (register `TabReorder`)

**Interfaces:**
- Consumes: `Pane.tabs: [OpenTab]`, `AppState.open(_:)`, `AppState.tabs`, `AppState.activeTabID`, `AppState.activeText`.
- Produces: `AppState.moveTab(_ sourceID: UUID, before targetID: UUID?, in pane: Pane)`.

- [ ] **Step 1: Write the failing test** — append to `Sources/Checks/TabChecks.swift`:

```swift
func tabReorderChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    try? "gamma".write(to: vault.appendingPathComponent("C.md"), atomically: true, encoding: .utf8)
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }),
          let c = s.files.first(where: { $0.name == "C.md" }) else { expect(false, "files"); return }
    s.open(a); s.open(b); s.open(c)   // order [A,B,C], C active
    let pane = s.panes.first!
    let aID = s.tabs.first(where: { $0.file.name == "A.md" })!.id
    let bID = s.tabs.first(where: { $0.file.name == "B.md" })!.id

    // Move A to the end → [B,C,A].
    s.moveTab(aID, before: nil, in: pane)
    expectEqual(pane.tabs.map { $0.file.name }, ["B.md", "C.md", "A.md"], "A moved to the end")

    // Move A before B → [A,B,C].
    s.moveTab(aID, before: bID, in: pane)
    expectEqual(pane.tabs.map { $0.file.name }, ["A.md", "B.md", "C.md"], "A moved before B")

    // No-op cases leave order unchanged.
    s.moveTab(aID, before: aID, in: pane)
    s.moveTab(UUID(), before: bID, in: pane)
    expectEqual(pane.tabs.map { $0.file.name }, ["A.md", "B.md", "C.md"], "no-op reorders unchanged")

    // Reorder never disturbs the active tab or its live buffer.
    expectEqual(s.selectedFile?.name, "C.md", "C still active after reorders")
    expectEqual(s.activeTabID, s.tabs.first(where: { $0.file.name == "C.md" })!.id, "activeTabID unchanged")
}
```

- [ ] **Step 2: Register** the check — in `Sources/Checks/main.swift`, add after the `("PaneSplit", paneSplitChecks),` line:

```swift
    ("TabReorder", tabReorderChecks),
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift run Checks TabReorder`
Expected: build failure — `value of type 'AppState' has no member 'moveTab'`.

- [ ] **Step 4: Implement `moveTab`** — in `Sources/AppCore/AppState.swift`, add immediately after the `splitRight()` method (after its closing brace, ~line 305):

```swift
    /// Move `sourceID` to just before `targetID` within `pane` (insert-style);
    /// `targetID == nil` moves it to the end. Pure positional change — the active
    /// tab and the live working fields are untouched. No-op if source == target
    /// or either id is absent.
    public func moveTab(_ sourceID: UUID, before targetID: UUID?, in pane: Pane) {
        guard sourceID != targetID,
              let from = pane.tabs.firstIndex(where: { $0.id == sourceID }) else { return }
        objectWillChange.send()
        let moved = pane.tabs.remove(at: from)
        if let targetID, let to = pane.tabs.firstIndex(where: { $0.id == targetID }) {
            pane.tabs.insert(moved, at: to)
        } else {
            pane.tabs.append(moved)
        }
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift run Checks TabReorder`
Expected: PASS.

- [ ] **Step 6: Run the safety net**

Run: `swift run Checks Tabs && swift run Checks PaneProxy && swift run Checks PaneSplit && swift run Checks TabReload`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/AppCore/AppState.swift Sources/Checks/TabChecks.swift Sources/Checks/main.swift
git commit -m "feat(tabs): moveTab — within-pane insert-style reorder (model)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Reorder UI — drag & drop in the tab bar

**Files:**
- Modify: `Sources/HanjiApp/TabBarView.swift`

**Interfaces:**
- Consumes: `AppState.moveTab(_:before:in:)`, `Pane.id`, `OpenTab.id`.
- Produces: a tab bar where dragging a tab reorders it; a trailing drop zone moves to the end.

- [ ] **Step 1: Replace `TabBarView` with the drag-enabled version** — in `Sources/HanjiApp/TabBarView.swift`, replace the whole `struct TabBarView` with:

```swift
/// Horizontal strip of one pane's open-note tabs. Tabs can be dragged to
/// reorder within the pane (insert-style); a trailing zone drops to the end.
struct TabBarView: View {
    @EnvironmentObject var appState: AppState
    let pane: Pane
    @State private var dropTarget: UUID?

    var body: some View {
        if !pane.tabs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(pane.tabs) { tab in
                        tabItem(tab)
                        Divider().frame(height: 16)
                    }
                    // Trailing drop zone → move to the end.
                    Color.clear
                        .frame(width: 40, height: 32)
                        .dropDestination(for: String.self) { items, _ in
                            guard let s = items.first, let dropped = UUID(uuidString: s) else { return false }
                            appState.moveTab(dropped, before: nil, in: pane)
                            return true
                        }
                }
            }
            .frame(height: 32)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }

    private func tabItem(_ tab: OpenTab) -> some View {
        let isActive = pane.id == appState.activePaneID && tab.id == pane.activeTabID
        let dirty = isActive ? appState.isDirty : tab.isDirty
        return HStack(spacing: 6) {
            Text(tab.file.url.deletingPathExtension().lastPathComponent)
                .font(.callout).lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
            if dirty { Circle().fill(Color.secondary).frame(width: 6, height: 6) }
            Button { appState.focusPane(pane.id); appState.closeTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .overlay(alignment: .leading) {
            if dropTarget == tab.id {
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { appState.focusPane(pane.id); appState.switchTab(tab.id) }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let dropped = UUID(uuidString: s) else { return false }
            appState.moveTab(dropped, before: tab.id, in: pane)
            return true
        } isTargeted: { hovering in
            if hovering { dropTarget = tab.id }
            else if dropTarget == tab.id { dropTarget = nil }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Run the full suite** (UI change must not break model checks)

Run: `swift run Checks`
Expected: `✅ All checks passed`.

- [ ] **Step 4: Visual check** — rebuild the bundle, launch, drag a tab:

```bash
pkill -x hanji 2>/dev/null; ./Scripts/bundle-app.sh && open hanji.app
```

Open two or three notes (⌘O), drag a tab left/right of another, confirm the order changes and the accent insertion bar shows while hovering. Screenshot and inspect: tabs reordered, active tab unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/HanjiApp/TabBarView.swift
git commit -m "feat(tabs): drag-and-drop tab reorder within a pane" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `moveTabToSide` — send a tab to the left/right pane (model)

**Files:**
- Modify: `Sources/AppCore/AppState.swift` (add `PaneSide`, `canMoveTab`, `moveTabToSide` after `moveTab`)
- Test: `Sources/Checks/TabChecks.swift` (add `paneMoveTabChecks`)
- Modify: `Sources/Checks/main.swift` (register `PaneMoveTab`)

**Interfaces:**
- Consumes: `AppState.panes`, `AppState.activePaneID`, `Pane`, `OpenTab`, `flushPendingSave()`, `writeBackActive()`, `hydrate(from:)`, `closePaneIfEmpty(_:)`, the `[safe:]` subscript.
- Produces:
  - `public enum PaneSide { case left, right }`
  - `AppState.canMoveTab(_ tabID: UUID, _ side: PaneSide) -> Bool`
  - `AppState.moveTabToSide(_ tabID: UUID, _ side: PaneSide)`

- [ ] **Step 1: Write the failing test** — append to `Sources/Checks/TabChecks.swift`:

```swift
func paneMoveTabChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }) else { expect(false, "files"); return }

    // Two tabs in one pane; move B to the right → new right pane with B.
    s.open(a); s.open(b)
    let bID = s.tabs.first(where: { $0.file.name == "B.md" })!.id
    s.moveTabToSide(bID, .right)
    expectEqual(s.panes.count, 2, "moving a tab right creates a second pane")
    expectEqual(s.panes.last?.tabs.count, 1, "right pane holds the moved tab")
    expectEqual(s.panes.first?.tabs.count, 1, "left pane keeps the other tab")
    expectEqual(s.selectedFile?.name, "B.md", "moved tab is focused")
    expectEqual(s.activePaneID, s.panes.last?.id, "right pane is active")

    // Dead-end: B already rightmost → move right again is a no-op.
    s.moveTabToSide(bID, .right)
    expectEqual(s.panes.count, 2, "moving the rightmost tab further right is a no-op")

    // Merge into existing neighbour: move B left → right pane emptied → collapse.
    s.moveTabToSide(bID, .left)
    expectEqual(s.panes.count, 1, "moving the lone right tab left collapses the split")
    expectEqual(s.tabs.count, 2, "both tabs back in one pane")
    expect(s.tabs.contains { $0.file.name == "B.md" }, "B merged back into the left pane")

    // Lone tab cannot split into a new pane.
    let vault2 = tabVault()
    defer { tabCleanup(vault2) }
    let s2 = tabState(vault2)
    let a2 = s2.files.first(where: { $0.name == "A.md" })!
    s2.open(a2)
    expect(!s2.canMoveTab(s2.activeTabID!, .right), "canMoveTab false for a lone tab (right)")
    expect(!s2.canMoveTab(s2.activeTabID!, .left), "canMoveTab false for a lone tab (left)")
    s2.moveTabToSide(s2.activeTabID!, .right)
    expectEqual(s2.panes.count, 1, "a lone tab does not split into a new pane")
}
```

- [ ] **Step 2: Register** the check — in `Sources/Checks/main.swift`, add after the `("TabReorder", tabReorderChecks),` line:

```swift
    ("PaneMoveTab", paneMoveTabChecks),
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift run Checks PaneMoveTab`
Expected: build failure — `cannot find 'PaneSide'` / `has no member 'moveTabToSide'`.

- [ ] **Step 4: Implement `PaneSide`, `canMoveTab`, `moveTabToSide`** — in `Sources/AppCore/AppState.swift`, add immediately after the `moveTab(_:before:in:)` method from Task 1:

```swift
    /// Which side a tab is sent to. Left = `panes[0]`, right = `panes[1]`.
    public enum PaneSide { case left, right }

    /// Whether `moveTabToSide(tabID, side)` would change anything: a neighbour
    /// pane on that side exists (merge), or there's room for a new pane
    /// (`panes.count < 2`) and the source keeps at least one tab.
    public func canMoveTab(_ tabID: UUID, _ side: PaneSide) -> Bool {
        guard let srcIndex = panes.firstIndex(where: { p in p.tabs.contains(where: { $0.id == tabID }) })
        else { return false }
        let neighbour = side == .right ? srcIndex + 1 : srcIndex - 1
        if neighbour >= 0 && neighbour < panes.count { return true }
        return panes.count < 2 && panes[srcIndex].tabs.count >= 2
    }

    /// Move the tab into the pane on `side`: merge into an existing neighbour, or
    /// create a new pane there (only when there's room and the source keeps a
    /// tab). The moved tab becomes that pane's active tab and the pane is focused;
    /// an emptied source pane collapses. No-op when the move is impossible.
    public func moveTabToSide(_ tabID: UUID, _ side: PaneSide) {
        guard let srcIndex = panes.firstIndex(where: { p in p.tabs.contains(where: { $0.id == tabID }) }),
              let tabIdx = panes[srcIndex].tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let src = panes[srcIndex]
        let neighbourIndex = side == .right ? srcIndex + 1 : srcIndex - 1
        let hasNeighbour = neighbourIndex >= 0 && neighbourIndex < panes.count
        guard hasNeighbour || (panes.count < 2 && src.tabs.count >= 2) else { return }

        // Persist the live buffer first when the moved tab is the active live tab,
        // so the carried-over snapshot is current.
        let isLiveTab = src.id == activePaneID && tabID == src.activeTabID
        if isLiveTab { flushPendingSave(); writeBackActive() }

        objectWillChange.send()
        let snapshot = src.tabs[tabIdx]
        let movedActive = tabID == src.activeTabID
        src.tabs.remove(at: tabIdx)
        if movedActive { src.activeTabID = src.tabs[safe: tabIdx]?.id ?? src.tabs.last?.id }

        let target: Pane
        if hasNeighbour {
            target = panes[neighbourIndex]
            target.tabs.append(snapshot)
        } else {
            let newPane = Pane(tabs: [snapshot], activeTabID: snapshot.id)
            panes.insert(newPane, at: side == .right ? srcIndex + 1 : srcIndex)
            target = newPane
        }
        target.activeTabID = snapshot.id
        activePaneID = target.id
        hydrate(from: snapshot)
        closePaneIfEmpty(src)
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift run Checks PaneMoveTab`
Expected: PASS.

- [ ] **Step 6: Run the safety net + full suite**

Run: `swift run Checks Tabs && swift run Checks PaneProxy && swift run Checks PaneSplit && swift run Checks TabReorder && swift run Checks TabReload && swift run Checks Autosave && swift run Checks Conflict && swift run Checks`
Expected: all PASS; final line `✅ All checks passed`.

- [ ] **Step 7: Commit**

```bash
git add Sources/AppCore/AppState.swift Sources/Checks/TabChecks.swift Sources/Checks/main.swift
git commit -m "feat(panes): moveTabToSide — send a tab to the left/right pane (model)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Send-to-pane UI — context menu + keyboard

**Files:**
- Modify: `Sources/HanjiApp/TabBarView.swift` (context menu on `tabItem`)
- Modify: `Sources/HanjiApp/HanjiApp.swift` (`Move Tab Left/Right` commands)

**Interfaces:**
- Consumes: `AppState.moveTabToSide(_:_:)`, `AppState.canMoveTab(_:_:)`, `AppState.PaneSide`, `AppState.activeTabID`.
- Produces: right-click "Move to Left/Right Pane" per tab; `⌃⌘←` / `⌃⌘→` move the active tab.

- [ ] **Step 1: Add the context menu** — in `Sources/HanjiApp/TabBarView.swift`, in `tabItem(_:)`, add a `.contextMenu` modifier immediately after the `.onTapGesture { … }` line (before `.draggable`):

```swift
        .contextMenu {
            Button("Move to Left Pane") { appState.moveTabToSide(tab.id, .left) }
                .disabled(!appState.canMoveTab(tab.id, .left))
            Button("Move to Right Pane") { appState.moveTabToSide(tab.id, .right) }
                .disabled(!appState.canMoveTab(tab.id, .right))
        }
```

- [ ] **Step 2: Add the keyboard commands** — in `Sources/HanjiApp/HanjiApp.swift`, in the `CommandGroup(after: .saveItem)` block, add after the `Button("Split Right") { … }` / `.keyboardShortcut("\\", …)` lines (within the same group, before its closing brace ~line 92):

```swift
                Button("Move Tab Right") {
                    if let id = appState.activeTabID { appState.moveTabToSide(id, .right) }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
                Button("Move Tab Left") {
                    if let id = appState.activeTabID { appState.moveTabToSide(id, .left) }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
```

(`PaneSide` is declared in `AppCore`, which `HanjiApp.swift` already imports for `appState`. If the build reports `cannot find '.right' in scope`, confirm `import AppCore` is present at the top of the file.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Run the full suite**

Run: `swift run Checks`
Expected: `✅ All checks passed`.

- [ ] **Step 5: Visual check** — rebuild, launch, exercise both triggers:

```bash
pkill -x hanji 2>/dev/null; ./Scripts/bundle-app.sh && open hanji.app
```

With two notes open in one pane: right-click a tab → **Move to Right Pane** → the pane splits and that tab moves right. Focus a tab and press **⌃⌘←** → it merges back, collapsing the split. Confirm menu items are disabled when the direction is impossible (e.g. a lone tab). Screenshot and inspect.

- [ ] **Step 6: Run E2E and commit**

```bash
./Scripts/e2e.sh
git add Sources/HanjiApp/TabBarView.swift Sources/HanjiApp/HanjiApp.swift
git commit -m "feat(panes): context menu + ⌃⌘←/→ to move a tab between panes" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review (vs spec)

- **§2.1 Reorder `moveTab`** → Task 1 (model + insert/end/no-op/active-unchanged tests). **UI** → Task 2 (`.draggable`/`.dropDestination`, trailing end zone, `isTargeted` insertion bar).
- **§2.2 Send-to-pane `moveTabToSide` + `PaneSide`** → Task 3. Merge into neighbour, create-with-room-and-≥2-tabs, lone-tab no-op, dead-end no-op, source repoint/collapse, focus follows — covered by `paneMoveTabChecks`. `canMoveTab` (for menu disabling) defined and tested here. **UI** → Task 4 (context menu + `⌃⌘←/→`).
- **§2.3 UI triggers** → Task 2 (drag) + Task 4 (context menu + keyboard). Existing `⌘\` `splitRight` untouched (verified: not modified by any task).
- **§3 Testing** → `tabReorderChecks` (Task 1), `paneMoveTabChecks` (Task 3); both registered in `main.swift`. UI verified by screenshot per the project's convention.
- **§4 Out of scope** → no task adds cross-pane drag, edge preview, swap, 3+ panes, vertical split, or pinned tabs.
- **Type consistency:** `moveTab(_:before:in:)`, `PaneSide{.left,.right}`, `canMoveTab(_:_:)->Bool`, `moveTabToSide(_:_:)` — names/signatures identical across Tasks 1/3/4 and the tests. `Pane`/`OpenTab`/`activePaneID`/`closePaneIfEmpty`/`writeBackActive`/`hydrate(from:)`/`[safe:]` all already exist in `AppState.swift`.
- **Placeholder scan:** none — every code step is complete.
- **objectWillChange:** wrapped in both `moveTab` and `moveTabToSide` before pane mutation, per the global constraint.
