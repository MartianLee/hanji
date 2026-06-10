import Foundation
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

/// A compact item a plugin contributes to the editor status bar (footer).
public struct StatusItem: Identifiable {
    public let id: String
    public let makeView: () -> AnyView
    public init(id: String, makeView: @escaping () -> AnyView) {
        self.id = id
        self.makeView = makeView
    }
}

/// Surface ③ (UI): where plugins register sidebar views and status-bar items.
public protocol UIRegistry: AnyObject {
    func addSidebarView(id: String, title: String, _ make: @escaping () -> AnyView)
    /// Register a small footer item shown in the editor status bar.
    func addStatusItem(id: String, _ make: @escaping () -> AnyView)
}

public extension Notification.Name {
    /// Posted by a block renderer when its rendered content changes height, so the
    /// editor can re-measure and re-reserve the inline widget's space.
    static let hanjiWidgetDidResize = Notification.Name("io.hanji.widgetDidResize")
}

/// Read-only access to the active editor document.
public protocol EditorContext {
    /// Emits the current document text and every subsequent change.
    var activeText: AnyPublisher<String, Never> { get }
    /// Vault-relative path of the open note (nil when none).
    var activeNotePath: AnyPublisher<String?, Never> { get }
}

/// Capabilities handed to a plugin at activation (M0 subset of PluginHost).
public protocol PluginHost: AnyObject {
    var ui: UIRegistry { get }
    var editor: EditorContext { get }
    var renderers: RendererRegistry { get }
    var commands: CommandRegistry { get }
    var workspace: WorkspaceActions { get }
    var query: MetadataQuerying { get }
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

/// Surface ③ (commands): a user-invokable action shown in the ⌘P palette.
///
/// - Note: A `run` closure that captures the host or one of its surfaces (e.g. `workspace`)
///   must capture it weakly (`[weak ws = host.workspace]`) — the host retains `PluginManager`,
///   which retains the registered commands, so a strong capture forms a retain cycle.
public struct Command: Identifiable {
    public let id: String
    public let title: String
    public let run: () -> Void
    public init(id: String, title: String, run: @escaping () -> Void) {
        self.id = id; self.title = title; self.run = run
    }
}

public protocol CommandRegistry: AnyObject {
    func register(_ command: Command)
}

/// Vault note actions handed to plugins (create/open notes, choose files).
public protocol WorkspaceActions: AnyObject {
    var vaultRoot: URL? { get }
    func noteExists(relativePath: String) -> Bool
    func readNote(relativePath: String) -> String?
    func createNote(relativePath: String, text: String, cursorOffset: Int?)
    func openNote(relativePath: String)
    func pickNote(title: String, startingFolder: String?) -> String?
    func promptNewNotePath(suggestedName: String) -> String?
}

/// One backlink (SDK-owned type — the index implementation stays hidden).
public struct SDKBacklink: Identifiable {
    public let sourcePath: String
    public let sourceTitle: String
    public let snippet: String
    public let matchRanges: [Range<Int>]   // UTF-16 ranges inside `snippet`
    public var id: String { sourcePath }
    public init(sourcePath: String, sourceTitle: String, snippet: String, matchRanges: [Range<Int>]) {
        self.sourcePath = sourcePath
        self.sourceTitle = sourceTitle
        self.snippet = snippet
        self.matchRanges = matchRanges
    }
}

/// Surface ② (metadata queries): read access to the vault index.
public protocol MetadataQuerying: AnyObject {
    func backlinks(toNoteAt relativePath: String) -> [SDKBacklink]
    /// Fires after the index absorbs changes (debounced upstream).
    var indexDidUpdate: AnyPublisher<Void, Never> { get }
}
