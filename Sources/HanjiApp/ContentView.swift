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

    @State private var treeSelection: URL?
    @State private var renameTarget: FileNode?
    @State private var renameText = ""
    @State private var deleteTarget: FileNode?
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
        List(appState.tree, children: \.children, selection: $treeSelection) { node in
            Label(displayName(node), systemImage: node.isDirectory ? "folder" : "doc.text")
                .contextMenu { contextMenu(for: node) }
                .draggable(node.url)
                .dropDestination(for: URL.self) { urls, _ in
                    // Dropping on a folder moves into it; on a file, into its parent.
                    handleDrop(urls, into: node.isDirectory ? node.url : node.url.deletingLastPathComponent())
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
        .onChange(of: treeSelection) { _, url in
            if let url, let f = appState.files.first(where: { $0.url == url }) { appState.open(f) }
        }
        .navigationTitle(appState.vaultRoot?.lastPathComponent ?? "Hanji")
        .toolbar {
            ToolbarItemGroup {
                Button(action: { newNote(in: targetFolder) }) { Image(systemName: "square.and.pencil") }
                    .help("New note")
                Button(action: { newFolder(in: targetFolder) }) { Image(systemName: "folder.badge.plus") }
                    .help("New folder")
                Button(action: openVault) { Image(systemName: "folder") }
                    .help("Open vault folder")
            }
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil },
                                              set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    do { let url = try appState.rename(target.url, to: renameText); treeSelection = url }
                    catch { fileErrorMessage = error.localizedDescription }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text(renameTarget.map { "Rename \u{201C}\(displayName($0))\u{201D}" } ?? "")
        }
        .alert("Move to Trash?", isPresented: Binding(get: { deleteTarget != nil },
                                                      set: { if !$0 { deleteTarget = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let target = deleteTarget { appState.delete(target.url) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget.map { "\u{201C}\(displayName($0))\u{201D} will be moved to the Trash." } ?? "")
        }
        .alert("Couldn\u{2019}t complete", isPresented: Binding(get: { fileErrorMessage != nil },
                                                                set: { if !$0 { fileErrorMessage = nil } })) {
            Button("OK", role: .cancel) { fileErrorMessage = nil }
        } message: {
            Text(fileErrorMessage ?? "")
        }
    }

    @ViewBuilder private func contextMenu(for node: FileNode) -> some View {
        if node.isDirectory {
            Button("New Note") { newNote(in: node.url) }
            Button("New Folder") { newFolder(in: node.url) }
            Divider()
        }
        Button("Rename\u{2026}") { startRename(node) }
        Button("Delete\u{2026}") { deleteTarget = node }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
    }

    /// Folder that New note / New folder should target: the selected folder, the
    /// selected file's parent, or the vault root.
    private var targetFolder: URL? {
        guard let sel = treeSelection, let node = findNode(sel, in: appState.tree) else { return nil }
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
        treeSelection = url
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
        var moved = false
        for url in urls {
            guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { continue }
            do {
                let newURL = try appState.move(url, into: dest)
                if treeSelection == url { treeSelection = newURL }
                moved = true
            } catch let error as VaultError {
                if case .cannotMoveIntoItself = error { continue }   // silent no-op, like Finder
                fileErrorMessage = error.localizedDescription
            } catch {
                fileErrorMessage = error.localizedDescription
            }
        }
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
