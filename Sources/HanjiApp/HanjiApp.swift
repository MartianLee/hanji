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
                    let host = Host(appState: appState, pluginManager: pluginManager)
                    host.renderers.register(CardRenderer())
                    host.renderers.register(MermaidRenderer())
                    host.renderers.register(DataviewRenderer(indexProvider: { [weak appState] in
                        appState?.index ?? MetadataIndex()
                    }))
                    let plugins: [Plugin] = [WordCountPlugin(), PeriodicNotesPlugin(), TemplaterPlugin()]
                    pluginManager.activate(plugins, host: host)

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
