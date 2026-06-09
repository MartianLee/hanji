import Foundation
import ExtensionSDK
import AppCore

private struct CommandPlugin: Plugin {
    static let id = "test.command"
    init() {}
    func activate(host: PluginHost) {
        host.commands.register(Command(id: "test.run", title: "Run Test") { })
    }
}

func commandRegistryChecks() {
    let appState = AppState(defaults: UserDefaults(suiteName: "mk-cmd-\(UUID().uuidString)")!)
    let pm = PluginManager()
    let host = Host(appState: appState, pluginManager: pm)
    pm.activate([CommandPlugin()], host: host)
    expectEqual(pm.commands.count, 1, "plugin registers one command")
    expectEqual(pm.commands.first?.title ?? "", "Run Test", "command title")

    // WorkspaceActions reaches AppState.
    expect(host.workspace.vaultRoot == nil, "no vault yet")
}
