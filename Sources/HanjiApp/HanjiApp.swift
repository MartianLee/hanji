import SwiftUI
import AppKit
import AppCore
import ExtensionSDK
import WordCountPlugin
import PeriodicNotesPlugin
import TemplaterPlugin
import CoreRenderers
import VaultKit

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
                    h.renderers.register(DataviewRenderer(indexProvider: { [weak appState] in
                        appState?.index ?? MetadataIndex()
                    }))
                    let plugins: [Plugin] = [WordCountPlugin(), PeriodicNotesPlugin(), TemplaterPlugin()]
                    pluginManager.activate(plugins, host: h)

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
                Button("New Note") { appState.newNote() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Folder") { appState.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Command Palette") { uiState.palette = .commands }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Quick Switcher") { uiState.palette = .files }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
        Settings {
            SettingsView().environmentObject(appState)
        }
    }
}
