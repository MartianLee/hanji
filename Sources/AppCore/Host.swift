import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import ExtensionSDK
import MKSearchKit

/// Concrete host wiring AppState + PluginManager to the SDK surfaces.
public final class Host: PluginHost, UIRegistry, EditorContext, CommandRegistry, WorkspaceActions, MetadataQuerying {
    private let appState: AppState
    private let pluginManager: PluginManager

    public init(appState: AppState, pluginManager: PluginManager) {
        self.appState = appState
        self.pluginManager = pluginManager
    }

    // PluginHost
    public var ui: UIRegistry { self }
    public var editor: EditorContext { self }
    public var renderers: RendererRegistry { appState.rendererRegistry }
    public var commands: CommandRegistry { self }
    public var workspace: WorkspaceActions { self }
    public var query: MetadataQuerying { self }

    // UIRegistry
    public func addSidebarView(id: String, title: String, _ make: @escaping () -> AnyView) {
        pluginManager.addSidebar(SidebarContribution(id: id, title: title, makeView: make))
    }

    public func addStatusItem(id: String, _ make: @escaping () -> AnyView) {
        pluginManager.addStatusItem(StatusItem(id: id, makeView: make))
    }

    // EditorContext
    public var activeText: AnyPublisher<String, Never> { appState.$activeText.eraseToAnyPublisher() }

    public var activeNotePath: AnyPublisher<String?, Never> {
        appState.$selectedFile.combineLatest(appState.$vaultRoot)
            .map { file, root -> String? in
                guard let file, let root else { return nil }
                let prefix = root.standardizedFileURL.path + "/"
                let path = file.url.standardizedFileURL.path
                return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : file.name
            }
            .eraseToAnyPublisher()
    }

    // CommandRegistry
    public func register(_ command: Command) { pluginManager.addCommand(command) }

    // WorkspaceActions
    public var vaultRoot: URL? { appState.vaultRoot }
    public func noteExists(relativePath: String) -> Bool { appState.noteExists(relativePath: relativePath) }
    public func readNote(relativePath: String) -> String? { appState.readNote(relativePath: relativePath) }
    public func createNote(relativePath: String, text: String, cursorOffset: Int?) {
        appState.createNote(relativePath: relativePath, text: text, cursorOffset: cursorOffset)
    }
    public func openNote(relativePath: String) { appState.openNote(relativePath: relativePath) }

    public func pickNote(title: String, startingFolder: String?) -> String? {
        guard let root = appState.vaultRoot else { return nil }
        let panel = NSOpenPanel()
        panel.message = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        if let sf = startingFolder { panel.directoryURL = root.appendingPathComponent(sf) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Self.relativePath(of: url, under: root)
    }

    public func promptNewNotePath(suggestedName: String) -> String? {
        guard let root = appState.vaultRoot else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = root
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Self.relativePath(of: url, under: root)
    }

    private static func relativePath(of url: URL, under root: URL) -> String? {
        let r = root.standardizedFileURL.path
        let u = url.standardizedFileURL.path
        // Require a path-separator boundary so "/vault" doesn't match a sibling "/vault2/…".
        let sep = r.hasSuffix("/") ? r : r + "/"
        guard u.hasPrefix(sep) else { return nil }
        return String(u.dropFirst(sep.count))
    }

    // MARK: - MetadataQuerying

    public func backlinks(toNoteAt relativePath: String) -> [SDKBacklink] {
        let hits = (try? appState.searchIndex?.backlinks(of: relativePath)) ?? []
        return hits.map {
            SDKBacklink(sourcePath: $0.sourcePath, sourceTitle: $0.sourceTitle,
                        snippet: $0.snippet, matchRanges: $0.matchRanges)
        }
    }

    public var indexDidUpdate: AnyPublisher<Void, Never> {
        appState.$searchIndexUpdatedAt.map { _ in () }.eraseToAnyPublisher()
    }
}
