# Left/Right Editor Split Implementation Plan

**Goal:** Two editor panes side by side, each its own tab group; only the focused pane is the live buffer (the other shows its active tab's snapshot and goes live on click).

**Architecture:** `Pane` is a plain tab-group class (`tabs`/`activeTabID`). AppState keeps its single working state (= active pane's active tab) and exposes `tabs`/`activeTabID` as **computed proxies to the active pane**. Tab mutators move onto `activePane` (firing `objectWillChange` since `Pane` is a class). `focusPane`/`splitRight`/`closePaneIfEmpty` manage panes; reconcile spans all panes. The UI renders 1 or 2 panes (`HSplitView`); the inactive pane's editor binds a `.constant` snapshot and `MarkdownEditorView.onFocus` activates a pane.

**Tech Stack:** Swift 5.10/SPM, SwiftUI, custom Checks runner. No new deps.

**Spec:** `docs/design/2026-06-18-hanji-split-design.md`

**Conventions:** TDD via `Sources/Checks`; commits to main. READ files before editing. The existing tab/autosave/conflict tests (`Tabs`, `TabReload`, `Autosave`, `Conflict`, `E2E`) are the safety net for the Task 1 refactor — they MUST stay green (behavior preserved with one pane).

---

## File structure

- Create `Sources/AppCore/Pane.swift` — the `Pane` tab-group class.
- Modify `Sources/AppCore/AppState.swift` — `panes`/`activePaneID`, computed `tabs`/`activeTabID`, rewired tab mutators, `focusPane`/`splitRight`/`closePaneIfEmpty`, multi-pane reconcile.
- Modify `Sources/EditorEngine/MarkdownEditorView.swift` — `onFocus` callback.
- Modify `Sources/HanjiApp/ContentView.swift` — per-pane `paneView`, `HSplitView`.
- Modify `Sources/HanjiApp/TabBarView.swift` — take a `Pane`.
- Modify `Sources/HanjiApp/HanjiApp.swift` — Split Right command.
- Modify `Sources/Checks/TabChecks.swift` (+`PaneChecks`) and `main.swift`.

---

## Task 1: Introduce Pane; move tabs onto the active pane (behavior-preserving)

**Files:**
- Create: `Sources/AppCore/Pane.swift`
- Modify: `Sources/AppCore/AppState.swift`
- Modify: `Sources/Checks/TabChecks.swift` (append a tiny proxy check)
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Create `Sources/AppCore/Pane.swift`**

```swift
import Foundation

/// One editor pane: an ordered group of open tabs with an active tab. A plain
/// class — AppState owns the `@Published panes` array and fires objectWillChange
/// when a pane's contents change.
public final class Pane: Identifiable {
    public let id = UUID()
    public var tabs: [OpenTab]
    public var activeTabID: UUID?
    public init(tabs: [OpenTab] = [], activeTabID: UUID? = nil) {
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}
```

- [ ] **Step 2: Append a proxy check** to `Sources/Checks/TabChecks.swift`:

```swift
func paneProxyChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }) else { expect(false, "files"); return }
    expectEqual(s.panes.count, 1, "starts with one pane")
    expect(s.activePaneID != nil, "active pane set")
    s.open(a)
    expectEqual(s.tabs.count, 1, "tabs proxy reflects active pane")
    expectEqual(s.panes.first?.tabs.count, 1, "active pane holds the tab")
    expectEqual(s.activeTabID, s.panes.first?.activeTabID, "activeTabID proxy matches pane")
}
```

- [ ] **Step 3: Register** `("PaneProxy", paneProxyChecks),` in `main.swift` after `("Tabs", …)`.

- [ ] **Step 4: Run `swift run Checks PaneProxy`** → build failure (`no member 'panes'`).

- [ ] **Step 5: AppState — add panes, computed proxies; rewire mutators.** In `AppState.swift`:

Replace the stored tab declarations
```swift
    @Published public private(set) var tabs: [OpenTab] = []
    @Published public private(set) var activeTabID: UUID?
```
with:
```swift
    @Published public private(set) var panes: [Pane] = [Pane()]
    @Published public var activePaneID: UUID?
    public var activePane: Pane? { panes.first { $0.id == activePaneID } ?? panes.first }
    public var isSplit: Bool { panes.count > 1 }
    /// Active pane's tabs / active tab (proxies; views re-render via objectWillChange).
    public var tabs: [OpenTab] { activePane?.tabs ?? [] }
    public var activeTabID: UUID? { activePane?.activeTabID }
```
In `init`, after the stored-property defaults run, add `activePaneID = panes.first?.id`.

Replace `writeBackActive`, `hydrate` (unchanged body but confirm), `clearActive`, `open`, `switchTab`, `closeTab`, `reconcileTabs`, `removeTabSilently` with the pane-aware versions:

```swift
    private func writeBackActive() {
        guard let pane = activePane, let id = pane.activeTabID,
              let idx = pane.tabs.firstIndex(where: { $0.id == id }) else { return }
        pane.tabs[idx].text = activeText
        pane.tabs[idx].savedText = savedText
        pane.tabs[idx].externalConflict = externalConflict
    }

    private func hydrate(from tab: OpenTab) {
        selectedFile = tab.file
        activeText = tab.text
        savedText = tab.savedText
        externalConflict = tab.externalConflict
        conflictPaused = (tab.externalConflict != nil)
        pendingCursorOffset = 0
    }

    private func clearActive() {
        activePane?.activeTabID = nil
        selectedFile = nil
        activeText = ""
        savedText = ""
        externalConflict = nil
        conflictPaused = false
    }

    public func open(_ file: MarkdownFile) {
        guard let pane = activePane else { return }
        if let existing = pane.tabs.first(where: { urlSameFile($0.file.url, file.url) }) {
            switchTab(existing.id); return
        }
        flushPendingSave()
        writeBackActive()
        let text = (try? vault?.read(file)) ?? ""
        let tab = OpenTab(file: file, text: text)
        objectWillChange.send()
        pane.tabs.append(tab)
        pane.activeTabID = tab.id
        hydrate(from: tab)
    }

    public func switchTab(_ id: UUID) {
        guard let pane = activePane, id != pane.activeTabID,
              let tab = pane.tabs.first(where: { $0.id == id }) else { return }
        flushPendingSave()
        writeBackActive()
        objectWillChange.send()
        pane.activeTabID = id
        hydrate(from: tab)
    }

    public func closeTab(_ id: UUID) {
        guard let pane = activePane, let idx = pane.tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == pane.activeTabID
        if wasActive { flushPendingSave() } else { flush(pane.tabs[idx]) }
        objectWillChange.send()
        pane.tabs.remove(at: idx)
        if wasActive {
            if let next = pane.tabs[safe: idx] ?? pane.tabs.last {
                pane.activeTabID = next.id
                hydrate(from: next)
            } else {
                pane.activeTabID = nil
                closePaneIfEmpty(pane)
            }
        }
    }

    /// Remove an emptied pane and re-activate another; for the lone pane, clear.
    private func closePaneIfEmpty(_ pane: Pane) {
        guard pane.tabs.isEmpty else { return }
        if panes.count > 1 {
            panes.removeAll { $0.id == pane.id }
            let first = panes[0]
            activePaneID = first.id
            if let t = first.tabs.first(where: { $0.id == first.activeTabID }) { hydrate(from: t) }
            else { clearActive() }
        } else {
            clearActive()
        }
    }

    private func reconcileTabs() {
        guard let vault else { return }
        let fm = FileManager.default
        for pane in panes {
            for gone in pane.tabs.filter({ !fm.fileExists(atPath: $0.file.url.path) }) {
                removeTab(gone.id, in: pane)
            }
        }
        for pane in panes {
            let isActivePane = pane.id == activePaneID
            for idx in pane.tabs.indices {
                let isActiveTab = isActivePane && pane.tabs[idx].id == pane.activeTabID
                let baseline = isActiveTab ? savedText : pane.tabs[idx].savedText
                guard let disk = try? vault.read(pane.tabs[idx].file), disk != baseline else { continue }
                let conflicting = isActiveTab ? (externalConflict != nil) : (pane.tabs[idx].externalConflict != nil)
                if conflicting { continue }
                let dirty = isActiveTab ? isDirty : pane.tabs[idx].isDirty
                if dirty {
                    if isActiveTab { conflictPaused = true; externalConflict = disk }
                    else { pane.tabs[idx].externalConflict = disk }
                } else {
                    if isActiveTab { activeText = disk; savedText = disk }
                    else { pane.tabs[idx].text = disk; pane.tabs[idx].savedText = disk }
                }
            }
            closePaneIfEmpty(pane)
        }
    }

    /// Remove a tab (no save — file gone) from a specific pane; if it was the
    /// active tab of the active pane, re-activate a neighbor or clear.
    private func removeTab(_ id: UUID, in pane: Pane) {
        guard let idx = pane.tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActiveTab = pane.id == activePaneID && id == pane.activeTabID
        objectWillChange.send()
        pane.tabs.remove(at: idx)
        if wasActiveTab {
            if let next = pane.tabs[safe: idx] ?? pane.tabs.last {
                pane.activeTabID = next.id
                hydrate(from: next)
            } else {
                pane.activeTabID = nil
                // pane emptiness handled by closePaneIfEmpty after the loop
                if panes.count == 1 { clearActive() }
            }
        } else if id == pane.activeTabID {
            pane.activeTabID = pane.tabs[safe: idx]?.id ?? pane.tabs.last?.id
        }
    }
```

Replace `openVault`'s tab reset (`tabs = []` / `activeTabID = nil` lines) with:
```swift
        panes = [Pane()]
        activePaneID = panes[0].id
```

In `rename` and `move`, the tab-update loops currently use `tabs.firstIndex`/`tabs[idx]` — change them to update **every pane** (a moved/renamed open file may live in either pane):
```swift
            let newFile = MarkdownFile(url: newURL)
            for pane in panes {
                if let idx = pane.tabs.firstIndex(where: { urlSameFile($0.file.url, url) }) {
                    pane.tabs[idx].file = newFile
                }
            }
            if selectedFile.map({ urlSameFile($0.url, url) }) ?? false { selectedFile = newFile }
```
(Apply the same loop in both `rename` and `move` where they previously did the single `tabs` update.)

- [ ] **Step 6: Run the tests** — `swift run Checks PaneProxy` PASS; then the safety net: `swift run Checks Tabs && swift run Checks TabReload && swift run Checks Autosave && swift run Checks Conflict && swift run Checks E2E` ALL green; then full `swift run Checks`; `swift build`.

- [ ] **Step 7: Commit**

```bash
git add Sources/AppCore/Pane.swift Sources/AppCore/AppState.swift Sources/Checks/TabChecks.swift Sources/Checks/main.swift
git commit -m "refactor(panes): tabs live on the active Pane; AppState proxies it (single pane, behavior-preserving)"
```

---

## Task 2: Split / focus / close-pane operations

**Files:**
- Modify: `Sources/AppCore/AppState.swift`
- Modify: `Sources/Checks/TabChecks.swift` (append `paneSplitChecks`)
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — append to `Sources/Checks/TabChecks.swift`:

```swift
func paneSplitChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    try? "gamma".write(to: vault.appendingPathComponent("C.md"), atomically: true, encoding: .utf8)
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }),
          let c = s.files.first(where: { $0.name == "C.md" }) else { expect(false, "files"); return }

    s.open(a)
    s.splitRight()
    expectEqual(s.panes.count, 2, "split creates a second pane")
    expect(s.isSplit, "isSplit true")
    expectEqual(s.selectedFile?.name, "A.md", "right pane shows the same doc")
    s.splitRight()
    expectEqual(s.panes.count, 2, "second splitRight is a no-op")

    // Open targets the active (right) pane.
    s.open(c)
    expectEqual(s.panes.last?.tabs.count, 2, "C opened in the right pane")
    expectEqual(s.panes.first?.tabs.count, 1, "left pane unchanged")

    // Focus + edit preserved across panes.
    let leftID = s.panes.first!.id
    s.activeText = "right edit"          // edit the right pane's active doc (C)
    s.focusPane(leftID)
    expectEqual(s.selectedFile?.name, "A.md", "focused left pane")
    s.activeText = "left edit"
    s.focusPane(s.panes.last!.id)
    expectEqual(s.activeText, "right edit", "right pane's edit preserved")
    s.focusPane(leftID)
    expectEqual(s.activeText, "left edit", "left pane's edit preserved")

    // Closing the left pane's last tab collapses the split.
    s.closeTab(s.activeTabID!)
    expectEqual(s.panes.count, 1, "closing a pane's last tab removes the pane")
    expectEqual(s.selectedFile?.name == "A.md" || s.selectedFile?.name == "C.md", true, "remaining pane active")
}
```

- [ ] **Step 2: Register** `("PaneSplit", paneSplitChecks),` in `main.swift` after `("PaneProxy", …)`.

- [ ] **Step 3: Run `swift run Checks PaneSplit`** → build failure (`no member 'splitRight'`).

- [ ] **Step 4: Add `focusPane` + `splitRight`** to `AppState.swift`:

```swift
    /// Focus another pane: persist the live working state into the current pane's
    /// active tab, then hydrate from the target pane's active tab.
    public func focusPane(_ id: UUID) {
        guard id != activePaneID, let target = panes.first(where: { $0.id == id }) else { return }
        flushPendingSave()
        writeBackActive()
        activePaneID = id
        if let tab = target.tabs.first(where: { $0.id == target.activeTabID }) { hydrate(from: tab) }
        else { clearActive() }
    }

    /// Open the active document in a new right pane (no-op if already split or empty).
    public func splitRight() {
        guard panes.count == 1, let cur = activePane, let id = cur.activeTabID,
              let tab = cur.tabs.first(where: { $0.id == id }) else { return }
        flushPendingSave()
        writeBackActive()
        let snapshot = cur.tabs.first(where: { $0.id == id }) ?? tab   // post-writeback copy
        let right = Pane(tabs: [snapshot], activeTabID: snapshot.id)
        panes.append(right)
        activePaneID = right.id
        hydrate(from: snapshot)
    }
```

- [ ] **Step 5: Run the tests** — `swift run Checks PaneSplit` PASS; then `swift run Checks PaneProxy && swift run Checks Tabs && swift run Checks TabReload && swift run Checks Conflict && swift run Checks E2E`; full `swift run Checks`.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppCore/AppState.swift Sources/Checks/TabChecks.swift Sources/Checks/main.swift
git commit -m "feat(panes): splitRight + focusPane (single live buffer, snapshot per pane)"
```

---

## Task 3: Split UI + onFocus + Split Right command

**Files:**
- Modify: `Sources/EditorEngine/MarkdownEditorView.swift`
- Modify: `Sources/HanjiApp/TabBarView.swift`
- Modify: `Sources/HanjiApp/ContentView.swift`
- Modify: `Sources/HanjiApp/HanjiApp.swift`

- [ ] **Step 1: `onFocus` on the editor** — in `MarkdownEditorView.swift`:

Add the param + store on the coordinator (mirror the existing `onOpenLink` wiring):
```swift
    public var onFocus: (() -> Void)?
```
Add it to `init` (defaulted `onFocus: (() -> Void)? = nil`), assign `self.onFocus = onFocus`, and set `context.coordinator.onFocus = onFocus` in both `makeNSView` and `updateNSView`. On the `Coordinator` add `var onFocus: (() -> Void)?`. In `ClickableTextView`, fire it when the view becomes first responder:
```swift
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecameFirstResponder?() }
        return ok
    }
```
Add `var onBecameFirstResponder: (() -> Void)?` to `ClickableTextView`, and in `makeNSView` set `textView.onBecameFirstResponder = { [weak coordinator = context.coordinator] in coordinator?.onFocus?() }`.

- [ ] **Step 2: `TabBarView` takes a pane** — change `TabBarView` to `init(pane: Pane)` and read `pane.tabs`/`pane.activeTabID`; tapping a tab calls `appState.focusPane(pane.id)` then `appState.switchTab(tab.id)`; close calls `appState.focusPane(pane.id)` then `appState.closeTab(tab.id)`. Dirty for the active tab of the **active pane** uses `appState.isDirty`, else the snapshot's `isDirty`:
```swift
struct TabBarView: View {
    @EnvironmentObject var appState: AppState
    let pane: Pane
    var body: some View {
        if !pane.tabs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(pane.tabs) { tab in tabItem(tab); Divider().frame(height: 16) }
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
                .font(.callout).lineLimit(1).foregroundStyle(isActive ? .primary : .secondary)
            if dirty { Circle().fill(Color.secondary).frame(width: 6, height: 6) }
            Button { appState.focusPane(pane.id); appState.closeTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { appState.focusPane(pane.id); appState.switchTab(tab.id) }
    }
}
```
(`focusPane` is a no-op when `pane.id == activePaneID`, so same-pane taps just switch.)

- [ ] **Step 3: `editorPane` renders panes** — in `ContentView.swift`, replace the body of `editorPane` so it renders one pane or an `HSplitView` of two, factoring the per-pane content into a `paneView(_:)`:

```swift
    @ViewBuilder private var editorPane: some View {
        VStack(spacing: 0) {
            if appState.panes.count > 1 {
                HSplitView {
                    ForEach(appState.panes) { pane in paneView(pane) }
                }
            } else if let pane = appState.panes.first {
                paneView(pane)
            }
            statusBar
        }
        .toolbar { /* unchanged toolbar */ }
    }

    @ViewBuilder private func paneView(_ pane: Pane) -> some View {
        let isActivePane = pane.id == appState.activePaneID
        VStack(spacing: 0) {
            TabBarView(pane: pane)
            if let tab = pane.tabs.first(where: { $0.id == pane.activeTabID }) {
                let fileURL = isActivePane ? (appState.selectedFile?.url ?? tab.file.url) : tab.file.url
                InlineTitleView(fileURL: fileURL, rename: { newName in
                    _ = try? appState.rename(fileURL, to: newName)
                }, enterBody: { appState.pendingCursorOffset = 0 })
                if isActivePane, appState.externalConflict != nil {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("This note changed on disk.")
                        Spacer()
                        Button("Reload from disk") { appState.resolveConflictReloadingDisk() }
                        Button("Keep my edits") { appState.resolveConflictKeepingMine() }
                    }.padding(8).background(Color.orange.opacity(0.15))
                }
                MarkdownEditorView(
                    text: isActivePane ? $appState.activeText : .constant(tab.text),
                    renderers: appState.rendererRegistry, vaultRoot: appState.vaultRoot,
                    cursorOffset: $appState.pendingCursorOffset, fontSize: CGFloat(appState.fontSize),
                    onOpenLink: { appState.openLink($0) },
                    onFocus: { appState.focusPane(pane.id) })
                .opacity(isActivePane ? 1 : 0.92)
            } else {
                Text("Open a vault, then select a note")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if appState.isSplit && isActivePane {
                Rectangle().fill(Color.accentColor).frame(height: 2)   // active-pane indicator
            }
        }
    }
```
(Keep the existing `.toolbar { … }` content from the old `editorPane` verbatim.)

- [ ] **Step 4: Split Right command** — in `HanjiApp.swift` `.commands`, add to the existing close-tab `CommandGroup(after: .saveItem)` (or a Go menu):
```swift
                Button("Split Right") { appState.splitRight() }
                    .keyboardShortcut("\\", modifiers: .command)
```

- [ ] **Step 5: Verify** — `swift build` ✅; full `swift run Checks` ✅; `./Scripts/e2e.sh` ✅. Screenshot pass (controller): open a note, Split Right, open a different note in the right pane.

- [ ] **Step 6: Commit**

```bash
git add Sources/EditorEngine/MarkdownEditorView.swift Sources/HanjiApp/TabBarView.swift Sources/HanjiApp/ContentView.swift Sources/HanjiApp/HanjiApp.swift
git commit -m "feat(panes): left/right split UI + active-pane focus + ⌘\\ Split Right"
```

---

## Self-review (vs spec)

- §2.1 Pane → Task 1 Step 1. §2.2 panes/activePaneID + computed proxies + rewired open/switch/close/writeBack/hydrate/clear + closePaneIfEmpty + rename/move all-panes + openVault reset → Task 1 Step 5; focusPane/splitRight → Task 2. §2.3 multi-pane reconcile → Task 1 (reconcileTabs loops all panes). §2.4 UI (HSplitView, paneView, active/inactive binding, onFocus, active indicator, Split Right ⌘\) → Task 3. §3 tests: proxy (T1), split/no-op/open-targets-active/focus-preserves-edit/close-collapses (T2), reconcile across panes already covered by TabReload through the active pane + new pane paths.
- Type consistency: `Pane{id,tabs,activeTabID}`, `panes`/`activePaneID`/`activePane`/`isSplit`, `tabs`/`activeTabID` computed, `focusPane`/`splitRight`/`closePaneIfEmpty`/`removeTab(_:in:)`, `MarkdownEditorView.onFocus`, `TabBarView(pane:)` — consistent.
- Behavior-preservation safety net (Task 1): Tabs/TabReload/Autosave/Conflict/E2E must stay green — they exercise the single-pane path through the new proxies.
- Pinned risks: `tabs`/`activeTabID` change stored→computed → confirm no `$tabs`/`$activeTabID` Combine subscribers exist (grep) before Task 1; objectWillChange.send() must wrap every pane-list mutation (Pane is a class, not @Published-observed). Inactive pane editor uses `.constant` snapshot — typing requires a focus click first (acceptable). Same file in both panes = independent snapshots, last-write-wins (documented).
