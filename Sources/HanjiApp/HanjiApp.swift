import SwiftUI
import AppKit
import AppCore
import ExtensionSDK
import WordCountPlugin
import PeriodicNotesPlugin
import TemplaterPlugin
import CoreRenderers
import VaultKit
import BacklinksPlugin
import CalendarPlugin

@main
struct HanjiApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var pluginManager = PluginManager()
    @StateObject private var uiState = UIState()
    @State private var activated = false
    // Retained for the app's lifetime: plugin command closures capture the host weakly,
    // so without a strong reference here the Host would deallocate after activation and
    // every command would become a silent no-op.
    @State private var host: AppCore.Host?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(pluginManager)
                .environmentObject(uiState)
                .frame(minWidth: 900, minHeight: 560)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { appState.flushPendingSave() }
                }
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    guard !activated else { return }
                    activated = true
                    let h = Host(appState: appState, pluginManager: pluginManager)
                    host = h   // retain for the app's lifetime
                    h.renderers.register(CardRenderer())
                    h.renderers.register(MermaidRenderer())
                    h.renderers.register(DataviewRenderer(query: { [weak appState] parsed in
                        (try? appState?.searchIndex?.dataview(parsed)) ?? []
                    }))
                    let plugins: [any Plugin] = [WordCountPlugin(), PeriodicNotesPlugin(), TemplaterPlugin(), BacklinksPlugin(), CalendarPlugin()]
                    pluginManager.activate(plugins, host: h)
                    // First-party shell command: keyboard-driven move via the folder palette.
                    h.commands.register(Command(id: "file.moveTo", title: "Move note to folder\u{2026}") { [weak uiState, weak appState] in
                        guard appState?.selectedFile != nil else { return }
                        uiState?.palette = .moveTo
                    })

                    // Test/E2E hook: open the sidebar in search mode (screenshot runs).
                    if ProcessInfo.processInfo.environment["HANJI_SIDEBAR"] == "search" {
                        uiState.sidebarMode = .search
                    }
                    if let vaultPath = ProcessInfo.processInfo.environment["HANJI_OPEN_VAULT"] {
                        let url = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
                        appState.openVault(at: url)
                        if let first = appState.files.first { appState.open(first) }
                    } else if let recent = appState.recentVaults.first,
                              FileManager.default.fileExists(atPath: recent.path) {
                        appState.openVault(at: recent)   // reopen last vault; user picks a note via ⌘O / the list
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    if let url = appState.newNote() { uiState.renameRequest = url }
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("New Folder") {
                    if let url = appState.newFolder() { uiState.renameRequest = url }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .undoRedo) {
                Button("Undo File Operation") { appState.undoLastFileOperation() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                    .disabled(!appState.canUndoFileOperation)
            }
            CommandGroup(after: .saveItem) {
                Button("Save") { appState.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!appState.isDirty)
                Button("Close Tab") {
                    if let id = appState.activeTabID { appState.closeTab(id) }
                }
                .keyboardShortcut("w", modifiers: .command)
                Button("Split Right") { appState.splitRight() }
                    .keyboardShortcut("\\", modifiers: .command)
                Button("Move Tab Right") {
                    if let id = appState.activeTabID { appState.moveTabToSide(id, .right) }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
                Button("Move Tab Left") {
                    if let id = appState.activeTabID { appState.moveTabToSide(id, .left) }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
            }
            CommandGroup(after: .textEditing) {
                // Routed to whatever NSTextView is first responder; AppKit reads the
                // action off the sender's tag, so each item carries its own.
                Button("Find…") { Self.findAction(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { Self.findAction(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { Self.findAction(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Replace…") { Self.findAction(.showReplaceInterface) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
                Button("Find and Replace in Vault…") {
                    uiState.sidebarMode = .search
                    uiState.replaceVisible = true
                    uiState.searchFocusToken += 1
                }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Right Sidebar") { uiState.rightSidebarVisible.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Button("Collapse All Folders") { uiState.expandedFolders = [] }
                Button("Expand All Folders") { uiState.expandedFolders = Self.allFolders(in: appState.tree) }
            }
            CommandMenu("Go") {
                Button("Command Palette") { uiState.palette = .commands }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Quick Switcher") { uiState.palette = .files }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Search in Vault") {
                    uiState.sidebarMode = .search
                    uiState.searchFocusToken += 1
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(pluginManager)
        }
    }

    /// Drive AppKit's find bar on whichever text view is first responder.
    /// `performTextFinderAction(_:)` reads the requested action off the sender's
    /// `tag`, so we hand it a menu item carrying that tag.
    private static func findAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: nil, from: item)
    }

    private static func allFolders(in nodes: [FileNode]) -> Set<URL> {
        var out = Set<URL>()
        func walk(_ nodes: [FileNode]) {
            for node in nodes where node.isDirectory {
                out.insert(node.url)
                walk(node.children ?? [])
            }
        }
        walk(nodes)
        return out
    }
}
