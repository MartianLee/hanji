import SwiftUI
import ExtensionSDK
import AppCore

private struct TestPlugin: Plugin {
    static let id = "test.plugin"
    init() {}
    func activate(host: PluginHost) {
        host.ui.addSidebarView(id: "test.sidebar", title: "Test") { AnyView(Text("hi")) }
    }
}

func pluginLoopChecks() {
    let appState = AppState()
    let pm = PluginManager()
    let host = Host(appState: appState, pluginManager: pm)
    pm.activate([TestPlugin()], host: host)
    expectEqual(pm.sidebar.count, 1, "activate registers one sidebar contribution")
    expectEqual(pm.sidebar.first?.id ?? "", "test.sidebar", "contribution id")
    expectEqual(pm.sidebar.first?.title ?? "", "Test", "contribution title")
}
