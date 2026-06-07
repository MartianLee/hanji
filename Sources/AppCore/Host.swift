import SwiftUI
import Combine
import ExtensionSDK

/// Concrete host wiring AppState + PluginManager to the SDK surfaces.
public final class Host: PluginHost, UIRegistry, EditorContext {
    private let appState: AppState
    private let pluginManager: PluginManager
    private let rendererRegistry = DefaultRendererRegistry()

    public init(appState: AppState, pluginManager: PluginManager) {
        self.appState = appState
        self.pluginManager = pluginManager
    }

    // PluginHost
    public var ui: UIRegistry { self }
    public var editor: EditorContext { self }
    public var renderers: RendererRegistry { rendererRegistry }

    // UIRegistry
    public func addSidebarView(id: String, title: String, _ make: @escaping () -> AnyView) {
        pluginManager.addSidebar(SidebarContribution(id: id, title: title, makeView: make))
    }

    // EditorContext
    public var activeText: AnyPublisher<String, Never> {
        appState.$activeText.eraseToAnyPublisher()
    }
}
