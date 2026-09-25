import SwiftUI
import AppKit
import AppCore
import EditorEngine
import ExtensionSDK
import VaultKit
import MarkdownCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var pluginManager: PluginManager
    @EnvironmentObject var uiState: UIState

    @State private var treeSelection = Set<URL>()
    @State private var renameTarget: FileNode?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool
    @State private var deleteTargets: [FileNode] = []
    @State private var fileErrorMessage: String?
    @State private var filterText = ""

    var body: some View {
        Group {
            if appState.vaultRoot == nil {
                WelcomeView(onOpen: openVault, onOpenRecent: openRecent)
            } else {
                splitView
            }
        }
        .overlay { paletteOverlay }
    }

    @ViewBuilder private var splitView: some View {
        // Two columns until a plugin contributes a right-sidebar panel (and the
        // user hasn't collapsed it), then three.
        if pluginManager.sidebar.isEmpty || !uiState.rightSidebarVisible {
            NavigationSplitView { fileListPane } detail: { editorPane }
        } else {
            NavigationSplitView { fileListPane } content: { editorPane } detail: { sidebarPane }
        }
    }

    @ViewBuilder private var modeTabs: some View {
        HStack(spacing: 14) {
            modeTab(.files, icon: "doc.text", help: "Files")
            modeTab(.search, icon: "magnifyingglass", help: "Search (⇧⌘F)")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func modeTab(_ mode: SidebarMode, icon: String, help: String) -> some View {
        Button { uiState.sidebarMode = mode } label: {
            Image(systemName: icon)
                .foregroundStyle(uiState.sidebarMode == mode ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder private var fileListPane: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                modeTabs
                Divider()
                if uiState.sidebarMode == .search {
                    SearchPanelView()
                } else {
                    filterField
                    List(selection: $treeSelection) {
                        treeRows(visibleTree)
                    }
                    Divider()
                    // Obsidian-style bottom-left shortcut into Settings.
                    HStack {
                        SettingsLink {
                            Image(systemName: "gearshape")
                                .imageScale(.medium)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Settings")
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
            .contextMenu {
                // Right-click on empty tree space: create at the vault root.
                Button("New Note") { newNote(in: nil) }
                Button("New Folder") { newFolder(in: nil) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                handleDrop(urls, into: appState.vaultRoot)   // empty space = vault root
            }
            .onChange(of: treeSelection) { _, sel in
                // Single-selecting a file opens it (multi-select doesn't).
                guard sel.count == 1, let url = sel.first,
                      appState.selectedFile?.url.standardizedFileURL != url.standardizedFileURL,
                      let f = appState.files.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL })
                else { return }
                appState.open(f)
            }
            .onChange(of: appState.selectedFile, initial: true) { _, file in
                // Auto-reveal the active note (opened via ⌘O, a command, or the
                // launch auto-open — `initial` catches a note opened before the
                // view appeared).
                guard let url = file?.url else { return }
                reveal(url, with: proxy)
            }
            .onChange(of: uiState.renameRequest) { _, url in
                // A just-created item wants its name typed right away: make the
                // row visible (expand ancestors), select it, scroll to it, and
                // begin the inline rename with the keyboard in the field.
                guard let url else { return }
                uiState.renameRequest = nil
                expandAncestors(of: url)
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                treeSelection = [url]
                startRename(FileNode(url: url, isDirectory: isDir, children: isDir ? [] : nil), prefill: false)
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(url) } }
            }
        }
        .navigationTitle(appState.vaultRoot?.lastPathComponent ?? "Hanji")
        .toolbar {
            ToolbarItemGroup {
                Button(action: { newNote(in: targetFolder) }) { Image(systemName: "square.and.pencil") }
                    .help("New note")
                Button(action: { newFolder(in: targetFolder) }) { Image(systemName: "folder.badge.plus") }
                    .help("New folder")
                sortMenu
                Button(action: openVault) { Image(systemName: "folder") }
                    .help("Open vault folder")
            }
        }
        .alert("Move to Trash?", isPresented: Binding(get: { !deleteTargets.isEmpty },
                                                      set: { if !$0 { deleteTargets = [] } })) {
            Button("Move to Trash", role: .destructive) {
                deleteTargets.forEach { appState.delete($0.url) }
                deleteTargets = []
            }
            Button("Cancel", role: .cancel) { deleteTargets = [] }
        } message: {
            Text(deleteTargets.count == 1
                 ? "\u{201C}\(displayName(deleteTargets[0]))\u{201D} will be moved to the Trash."
                 : "\(deleteTargets.count) items will be moved to the Trash.")
        }
        .alert("Couldn\u{2019}t complete", isPresented: Binding(get: { fileErrorMessage != nil },
                                                                set: { if !$0 { fileErrorMessage = nil } })) {
            Button("OK", role: .cancel) { fileErrorMessage = nil }
        } message: {
            Text(fileErrorMessage ?? "")
        }
        .alert(appState.notice?.title ?? "", isPresented: Binding(get: { appState.notice != nil },
                                                                  set: { if !$0 { appState.notice = nil } })) {
            Button("OK", role: .cancel) { appState.notice = nil }
        } message: {
            Text(appState.notice?.message ?? "")
        }
    }

    /// Recursive tree rows with controlled folder expansion (so auto-reveal can
    /// programmatically expand ancestors). AnyView breaks the recursive opaque type.
    @ViewBuilder private func treeRows(_ nodes: [FileNode]) -> some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                DisclosureGroup(isExpanded: expansionBinding(node.url)) {
                    AnyView(treeRows(node.children ?? []))
                } label: {
                    treeRow(node)
                }
            } else {
                treeRow(node)
            }
        }
    }

    @ViewBuilder private func treeRow(_ node: FileNode) -> some View {
        if renameTarget?.url == node.url {
            // Inline rename: edit in place; ⏎ commits, Esc cancels, blur commits.
            // For fresh items the field starts empty with the auto-name as the
            // placeholder, so the user just types the real name.
            TextField(displayName(node), text: $renameText)
                .textFieldStyle(.plain)
                .focused($renameFieldFocused)
                .onSubmit { commitRename() }
                .onExitCommand { renameTarget = nil }
                .onAppear {
                    // Asynchronously, after the List has settled, so the field
                    // actually receives the keyboard focus.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { renameFieldFocused = true }
                }
                .onChange(of: renameFieldFocused) { _, focused in
                    if !focused && renameTarget != nil { commitRename() }
                }
        } else {
            Label(displayName(node), systemImage: node.isDirectory ? "folder" : "doc.text")
                .contextMenu { contextMenu(for: node) }
                .draggable(node.url)
                .dropDestination(for: URL.self) { urls, _ in
                    // Dropping on a folder moves into it; on a file, into its parent.
                    handleDrop(urls, into: node.isDirectory ? node.url : node.url.deletingLastPathComponent())
                }
        }
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        renameTarget = nil
        // Empty (fresh item, nothing typed) or unchanged → keep the current name.
        guard !renameText.trimmingCharacters(in: .whitespaces).isEmpty,
              renameText != displayName(target) else { return }
        do { let url = try appState.rename(target.url, to: renameText); treeSelection = [url] }
        catch { fileErrorMessage = error.localizedDescription }
    }

    /// Expand every ancestor folder of `url` so its row is visible.
    private func expandAncestors(of url: URL) {
        guard let root = appState.vaultRoot else { return }
        let rootPath = root.standardizedFileURL.path
        var dir = url.deletingLastPathComponent()
        while dir.standardizedFileURL.path.hasPrefix(rootPath), dir.standardizedFileURL.path != rootPath {
            uiState.expandedFolders.insert(dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    /// Filter box above the tree: fuzzy match on names; folders with matching
    /// descendants stay visible and everything is force-expanded while filtering.
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
            TextField("Filter notes", text: $filterText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !filterText.isEmpty {
                Button { filterText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var visibleTree: [FileNode] {
        filterText.isEmpty ? appState.tree : filteredNodes(appState.tree)
    }

    private func filteredNodes(_ nodes: [FileNode]) -> [FileNode] {
        nodes.compactMap { node in
            if node.isDirectory {
                let kids = filteredNodes(node.children ?? [])
                if !kids.isEmpty {
                    var pruned = node
                    pruned.children = kids
                    return pruned
                }
                return FuzzyFilter.score(filterText, node.name) != nil ? node : nil
            }
            return FuzzyFilter.score(filterText, displayName(node)) != nil ? node : nil
        }
    }

    private func expansionBinding(_ url: URL) -> Binding<Bool> {
        Binding(get: { !filterText.isEmpty || uiState.expandedFolders.contains(url) },
                set: { expanded in
                    if expanded { uiState.expandedFolders.insert(url) } else { uiState.expandedFolders.remove(url) }
                })
    }

    /// Expand the note's ancestor folders, select it, and scroll it into view.
    private func reveal(_ url: URL, with proxy: ScrollViewProxy) {
        expandAncestors(of: url)
        if treeSelection != [url] { treeSelection = [url] }
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(url) } }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $appState.treeSort) {
                Text("File name (A \u{2192} Z)").tag(TreeSort.nameAsc)
                Text("File name (Z \u{2192} A)").tag(TreeSort.nameDesc)
                Text("Modified (new \u{2192} old)").tag(TreeSort.modifiedDesc)
                Text("Modified (old \u{2192} new)").tag(TreeSort.modifiedAsc)
                Text("Created (new \u{2192} old)").tag(TreeSort.createdDesc)
                Text("Created (old \u{2192} new)").tag(TreeSort.createdAsc)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort order")
    }

    @ViewBuilder private func contextMenu(for node: FileNode) -> some View {
        let targets = bulkTargets(including: node)
        if targets.count > 1 {
            Button("Move \(targets.count) Items to\u{2026}") { uiState.palette = .moveTo }
            Button("Delete \(targets.count) Items\u{2026}") { deleteTargets = targets }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url)) }
        } else {
            if node.isDirectory {
                Button("New Note") { newNote(in: node.url) }
                Button("New Folder") { newFolder(in: node.url) }
                Divider()
            }
            Button("Rename") { startRename(node) }
            Button("Duplicate") { _ = appState.duplicate(node.url) }
            Button("Move to\u{2026}") { treeSelection = [node.url]; uiState.palette = .moveTo }
            Button("Delete\u{2026}") { deleteTargets = [node] }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        }
    }

    /// When the right-clicked row is part of a multi-selection, act on all of it.
    private func bulkTargets(including node: FileNode) -> [FileNode] {
        guard treeSelection.contains(node.url), treeSelection.count > 1 else { return [node] }
        return treeSelection.compactMap { findNode($0, in: appState.tree) }
    }

    /// Folder that New note / New folder should target: the selected folder, the
    /// selected file's parent, or the vault root.
    private var targetFolder: URL? {
        guard treeSelection.count == 1, let sel = treeSelection.first,
              let node = findNode(sel, in: appState.tree) else { return nil }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func findNode(_ url: URL, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.url == url { return node }
            if let children = node.children, let hit = findNode(url, in: children) { return hit }
        }
        return nil
    }

    private func displayName(_ node: FileNode) -> String {
        node.isDirectory ? node.name : node.url.deletingPathExtension().lastPathComponent
    }

    /// Create with an auto-name, then immediately type the real one (Obsidian-style).
    private func newNote(in folder: URL?) {
        guard let url = appState.newNote(inFolder: folder) else { return }
        uiState.renameRequest = url
    }

    private func newFolder(in folder: URL?) {
        guard let url = appState.newFolder(inFolder: folder) else { return }
        uiState.renameRequest = url
    }

    private func startRename(_ node: FileNode, prefill: Bool = true) {
        renameText = prefill ? displayName(node) : ""
        renameTarget = node
    }

    /// Move dragged vault items into `folder` (vault root when nil). Items from
    /// outside the vault are imported when they are `.md`, and ignored otherwise.
    private func handleDrop(_ urls: [URL], into folder: URL?) -> Bool {
        guard let root = appState.vaultRoot, let dest = folder ?? appState.vaultRoot else { return false }
        let rootPrefix = root.standardizedFileURL.path + "/"
        // Vault-internal items move; external `.md` files are imported (copied in).
        var internalURLs = urls.filter { $0.standardizedFileURL.path.hasPrefix(rootPrefix) }
        let externalNotes = urls.filter { !$0.standardizedFileURL.path.hasPrefix(rootPrefix)
                                          && $0.pathExtension.lowercased() == "md" }
        // Dragging a row that is part of a multi-selection moves the whole selection.
        if internalURLs.count == 1, let u = internalURLs.first,
           treeSelection.contains(u), treeSelection.count > 1 {
            internalURLs = Array(treeSelection)
        }
        var acted = false
        if !internalURLs.isEmpty { performMove(internalURLs, to: dest); acted = true }
        if !externalNotes.isEmpty { acted = !appState.importNotes(externalNotes, into: dest).isEmpty || acted }
        return acted
    }

    /// Move several items into `folder`, keeping the selection on the moved items.
    private func performMove(_ urls: [URL], to folder: URL) {
        var newSelection = Set<URL>()
        for url in urls {
            do { newSelection.insert(try appState.move(url, into: folder)) }
            catch let error as VaultError {
                if case .cannotMoveIntoItself = error { continue }   // silent no-op, like Finder
                fileErrorMessage = error.localizedDescription
            } catch {
                fileErrorMessage = error.localizedDescription
            }
        }
        if !newSelection.isEmpty { treeSelection = newSelection }
    }

    @ViewBuilder private var editorPane: some View {
        VStack(spacing: 0) {
            // A fresh HSplitView is built when going to 2 panes so the split lays
            // out 50/50 (adding a child to an existing HSplitView would leave the
            // new pane ~0 wide). That rebuild tears the previous editor's NSTextView
            // out of the window — safe only because the structural ops resign the
            // editor's first responder first (AppState.resignEditorFocus); a
            // first-responder text view removed mid-update hangs the app.
            if appState.panes.count > 1 {
                HSplitView {
                    ForEach(appState.panes) { pane in paneView(pane) }
                }
            } else if let pane = appState.panes.first {
                paneView(pane)
            }
            statusBar
        }
        .toolbar {
            ToolbarItem { Button("Save", action: appState.save) }
            ToolbarItem {
                Button { uiState.rightSidebarVisible.toggle() } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help("Toggle right sidebar (⌥⌘B)")
                .disabled(pluginManager.sidebar.isEmpty)
            }
        }
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
                    }
                    .padding(8).background(Color.orange.opacity(0.15))
                }
                if isActivePane, appState.missingOnDisk {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("This note was moved or deleted on disk.")
                        Spacer()
                        Button("Close without saving") { appState.closeMissingNote() }
                        Button("Save again") { appState.restoreMissingNote() }
                    }
                    .padding(8).background(Color.orange.opacity(0.15))
                }
                MarkdownEditorView(
                    text: isActivePane ? $appState.activeText : .constant(tab.text),
                    renderers: appState.rendererRegistry, vaultRoot: appState.vaultRoot,
                    cursorOffset: $appState.pendingCursorOffset, fontSize: CGFloat(appState.fontSize),
                    onOpenLink: { appState.openLink($0) },
                    onFocus: { appState.focusPane(pane.id) },
                    isLive: isActivePane)
                .opacity(isActivePane ? 1 : 0.92)
            } else {
                Text("Open a vault, then select a note")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if appState.isSplit && isActivePane {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
    }

    /// Thin footer bar with plugin status items (e.g. word count).
    @ViewBuilder private var statusBar: some View {
        if appState.selectedFile != nil, !pluginManager.statusItems.isEmpty {
            Divider()
            HStack(spacing: 12) {
                Spacer()
                ForEach(pluginManager.statusItems) { item in
                    item.makeView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(.bar)
        }
    }

    @ViewBuilder private var sidebarPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(pluginManager.sidebar) { contribution in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contribution.title).font(.headline)
                        contribution.makeView()
                    }
                }
            }
            .padding()
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 320)
    }

    @ViewBuilder private var paletteOverlay: some View {
        if let mode = uiState.palette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.15).ignoresSafeArea().onTapGesture { uiState.palette = nil }
                paletteView(for: mode).padding(.top, 80)
            }
        }
    }

    private func paletteView(for mode: PaletteMode) -> some View {
        switch mode {
        case .commands:
            return PaletteView(placeholder: "Run a command…",
                               items: pluginManager.commands.map { c in
                                   PaletteItem(id: c.id, title: c.title, subtitle: nil, action: c.run)
                               },
                               onClose: { uiState.palette = nil })
        case .files:
            return PaletteView(placeholder: "Go to file…",
                               items: appState.files.map { f in
                                   PaletteItem(id: f.url.path, title: f.name, subtitle: nil,
                                               action: { appState.open(f) })
                               },
                               onClose: { uiState.palette = nil })
        case .moveTo:
            return PaletteView(placeholder: "Move to folder…",
                               items: folderItems(),
                               onClose: { uiState.palette = nil })
        }
    }

    /// Items being moved by the Move to… palette: the tree selection, else the open note.
    private func moveTargets() -> [URL] {
        if !treeSelection.isEmpty { return Array(treeSelection) }
        if let f = appState.selectedFile { return [f.url] }
        return []
    }

    /// Every folder in the vault (root first), as Move to… destinations.
    private func folderItems() -> [PaletteItem] {
        guard let root = appState.vaultRoot else { return [] }
        let targets = moveTargets()
        guard !targets.isEmpty else { return [] }
        var items = [PaletteItem(id: root.path, title: root.lastPathComponent, subtitle: "vault root",
                                 action: { performMove(targets, to: root) })]
        func walk(_ nodes: [FileNode], prefix: String) {
            for node in nodes where node.isDirectory {
                let title = prefix + node.name
                items.append(PaletteItem(id: node.url.path, title: title, subtitle: nil,
                                         action: { [url = node.url] in performMove(targets, to: url) }))
                walk(node.children ?? [], prefix: title + "/")
            }
        }
        walk(appState.tree, prefix: "")
        return items
    }

    private func openRecent(_ url: URL) {
        appState.openVault(at: url)
    }

    private func openVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.openVault(at: url)
        }
    }
}

/// Editable Obsidian-style inline title. Shows the file's name (no extension);
/// committing (Enter or blur) renames the file via `rename`. Resyncs whenever
/// the open file changes.
private struct InlineTitleView: View {
    let fileURL: URL
    let rename: (String) -> Void
    let enterBody: () -> Void
    @State private var title: String = ""
    @FocusState private var focused: Bool

    private var base: String { fileURL.deletingPathExtension().lastPathComponent }

    var body: some View {
        TextField("Untitled", text: $title)
            .textFieldStyle(.plain)
            .font(.system(size: 28, weight: .bold))
            .lineLimit(1)
            .focused($focused)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .background(Color(nsColor: .textBackgroundColor))   // match the editor body
            .onAppear { title = base }
            .onChange(of: fileURL) { _, _ in title = base }     // switched notes → resync
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            // Enter drops into the editor body. Space must NOT: titles have spaces
            // in them, and stealing the first one made multi-word titles unwritable.
            .onKeyPress(.return) { commit(); enterBody(); return .handled }
    }

    private func commit() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != base else { title = base; return }
        rename(trimmed)
    }
}
