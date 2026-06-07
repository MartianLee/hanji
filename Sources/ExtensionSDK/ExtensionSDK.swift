import SwiftUI
import Combine

/// A view a plugin contributes to the right sidebar.
public struct SidebarContribution: Identifiable {
    public let id: String
    public let title: String
    public let makeView: () -> AnyView
    public init(id: String, title: String, makeView: @escaping () -> AnyView) {
        self.id = id
        self.title = title
        self.makeView = makeView
    }
}

/// Surface ③ (UI): where plugins register sidebar views.
public protocol UIRegistry: AnyObject {
    func addSidebarView(id: String, title: String, _ make: @escaping () -> AnyView)
}

/// Read-only access to the active editor document.
public protocol EditorContext {
    /// Emits the current document text and every subsequent change.
    var activeText: AnyPublisher<String, Never> { get }
}

/// Capabilities handed to a plugin at activation (M0 subset of PluginHost).
public protocol PluginHost: AnyObject {
    var ui: UIRegistry { get }
    var editor: EditorContext { get }
    var renderers: RendererRegistry { get }
}

/// Surface ①: renders a fenced code block of a given language as a view.
public protocol CodeBlockRenderer {
    var language: String { get }
    func makeView(source: String) -> AnyView
}

/// Where plugins register code-block renderers (keyed by language).
public protocol RendererRegistry: AnyObject {
    func register(_ renderer: CodeBlockRenderer)
    func renderer(for language: String) -> CodeBlockRenderer?
}

/// A compile-time-loaded extension.
public protocol Plugin {
    static var id: String { get }
    init()
    func activate(host: PluginHost)
}
