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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(pluginManager)
                .environmentObject(uiState)
                .frame(minWidth: 900, minHeight: 560)
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
