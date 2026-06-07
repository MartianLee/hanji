import SwiftUI
import AppKit
import AppCore
import ExtensionSDK
import WordCountPlugin

@main
struct HanjiApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var pluginManager = PluginManager()
    @State private var activated = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(pluginManager)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    guard !activated else { return }
                    activated = true
                    let host = Host(appState: appState, pluginManager: pluginManager)
                    let plugins: [Plugin] = [WordCountPlugin()]   // compile-time loading (D5)
                    pluginManager.activate(plugins, host: host)
                }
        }
    }
}
