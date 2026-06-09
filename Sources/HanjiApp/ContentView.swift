import SwiftUI
import AppKit
import AppCore
import EditorEngine
import ExtensionSDK
import VaultKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var pluginManager: PluginManager
    @EnvironmentObject var uiState: UIState

    @State private var treeSelection = Set<URL>()
    @State private var expandedFolders = Set<URL>()
    @State private var renameTarget: FileNode?
    @State private var renameText = ""
    @State private var deleteTargets: [FileNode] = []
    @State private var fileErrorMessage: String?

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
        // Two columns until a plugin contributes a right-sidebar panel, then three.
        if pluginManager.sidebar.isEmpty {
            NavigationSplitView { fileListPane } detail: { editorPane }
        } else {
            NavigationSplitView { fileListPane } content: { editorPane } detail: { sidebarPane }
        }
    }

    @ViewBuilder private var fileListPane: some View {
        ScrollViewReader { proxy in
            List(selection: $treeSelection) {
                treeRows(appState.tree)
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
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil },
                                              set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    do { let url = try appState.rename(target.url, to: renameText); treeSelection = [url] }
                    catch { fileErrorMessage = error.localizedDescription }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text(renameTarget.map { "Rename \u{201C}\(displayName($0))\u{201D}" } ?? "")
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

    private func treeRow(_ node: FileNode) -> some View {
        Label(displayName(node), systemImage: node.isDirectory ? "folder" : "doc.text")
            .contextMenu { contextMenu(for: node) }
            .draggable(node.url)
            .dropDestination(for: URL.self) { urls, _ in
                // Dropping on a folder moves into it; on a file, into its parent.
                handleDrop(urls, into: node.isDirectory ? node.url : node.url.deletingLastPathComponent())
            }
    }

    private func expansionBinding(_ url: URL) -> Binding<Bool> {
        Binding(get: { expandedFolders.contains(url) },
                set: { expanded in
                    if expanded { expandedFolders.insert(url) } else { expandedFolders.remove(url) }
                })
    }

    /// Expand the note's ancestor folders, select it, and scroll it into view.
    private func reveal(_ url: URL, with proxy: ScrollViewProxy) {
        guard let root = appState.vaultRoot else { return }
        let rootPath = root.standardizedFileURL.path
        var dir = url.deletingLastPathComponent()
        while dir.standardizedFileURL.path.hasPrefix(rootPath), dir.standardizedFileURL.path != rootPath {
            expandedFolders.insert(dir)
            dir = dir.deletingLastPathComponent()
        }
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
            Button("Delete \(targets.count) Items\u{2026}") { deleteTargets = targets }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url)) }
        } else {
            if node.isDirectory {
                Button("New Note") { newNote(in: node.url) }
                Button("New Folder") { newFolder(in: node.url) }
                Divider()
            }
            Button("Rename\u{2026}") { startRename(node) }
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

    /// Create with an auto-name, then immediately offer the rename (Obsidian-style).
    private func newNote(in folder: URL?) {
        guard let url = appState.newNote(inFolder: folder) else { return }
        treeSelection = [url]
        startRename(FileNode(url: url, isDirectory: false, children: nil))
    }

    private func newFolder(in folder: URL?) {
        guard let url = appState.newFolder(inFolder: folder) else { return }
        startRename(FileNode(url: url, isDirectory: true, children: []))
    }

    private func startRename(_ node: FileNode) {
        renameText = displayName(node)
        renameTarget = node
    }

    /// Move dragged vault items into `folder` (vault root when nil). Items from
    /// outside the vault are ignored (import is out of scope for now).
    private func handleDrop(_ urls: [URL], into folder: URL?) -> Bool {
        guard let root = appState.vaultRoot, let dest = folder ?? appState.vaultRoot else { return false }
        // Dragging a row that is part of a multi-selection moves the whole selection.
        var toMove = urls
        if urls.count == 1, let u = urls.first, treeSelection.contains(u), treeSelection.count > 1 {
            toMove = Array(treeSelection)
        }
        var moved = false
        var newSelection = Set<URL>()
        for url in toMove {
            guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { continue }
            do {
                let newURL = try appState.move(url, into: dest)
                newSelection.insert(newURL)
                moved = true
            } catch let error as VaultError {
                if case .cannotMoveIntoItself = error { continue }   // silent no-op, like Finder
                fileErrorMessage = error.localizedDescription
            } catch {
                fileErrorMessage = error.localizedDescription
            }
        }
        if moved { treeSelection = newSelection }
        return moved
    }

    @ViewBuilder private var editorPane: some View {
        VStack(spacing: 0) {
            if appState.selectedFile != nil {
                MarkdownEditorView(text: $appState.activeText, renderers: appState.rendererRegistry, vaultRoot: appState.vaultRoot, cursorOffset: $appState.pendingCursorOffset)
            } else {
                Text("Open a vault, then select a note")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            statusBar
        }
        .toolbar {
            ToolbarItem { Button("Save", action: appState.save) }
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
        .frame(minWidth: 220)
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
        }
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
