import Foundation
import Combine
import VaultKit

public final class AppState: ObservableObject {
    @Published public var vaultRoot: URL?
    @Published public var files: [MarkdownFile] = []
    @Published public var selectedFile: MarkdownFile?
    @Published public var activeText: String = ""
    @Published public var index: MetadataIndex = MetadataIndex()
    @Published public var recentVaults: [URL] = []
    @Published public var pendingCursorOffset: Int?
    public let rendererRegistry = DefaultRendererRegistry()

    private var vault: Vault?
    private let defaults: UserDefaults
    private static let recentsKey = "io.hanji.recentVaults"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let paths = (defaults.array(forKey: Self.recentsKey) as? [String]) ?? []
        recentVaults = paths.map { URL(fileURLWithPath: $0) }
    }

    public func openVault(at root: URL) {
        let v = Vault(root: root)
        vault = v
        vaultRoot = root
        files = (try? v.markdownFiles()) ?? []
        index = (try? MetadataIndex.build(from: v)) ?? MetadataIndex()
        selectedFile = nil
        activeText = ""
        addRecent(root)
    }

    public func open(_ file: MarkdownFile) {
        selectedFile = file
        activeText = (try? vault?.read(file)) ?? ""
    }

    public func save() {
        guard let file = selectedFile, let vault else { return }
        try? vault.write(activeText, to: file)
    }

    // MARK: - Recent vaults

    private func addRecent(_ root: URL) {
        let std = root.standardizedFileURL
        var list = recentVaults.filter { $0.standardizedFileURL != std }
        list.insert(std, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        recentVaults = list
        persistRecents()
    }

    public func removeRecent(_ url: URL) {
        recentVaults.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        persistRecents()
    }

    public func clearRecents() {
        recentVaults = []
        persistRecents()
    }

    private func persistRecents() {
        defaults.set(recentVaults.map { $0.path }, forKey: Self.recentsKey)
    }

    // MARK: - Note operations (used by WorkspaceActions)

    public func noteExists(relativePath: String) -> Bool {
        guard let root = vaultRoot else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    public func readNote(relativePath: String) -> String? {
        guard let root = vaultRoot else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    public func createNote(relativePath: String, text: String, cursorOffset: Int?) {
        guard let root = vaultRoot, let v = vault else { return }
        let url = root.appendingPathComponent(relativePath)
        // Ensure the parent folder exists, then write atomically via Vault (temp+rename).
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? v.write(text, to: MarkdownFile(url: url))
        files = (try? v.markdownFiles()) ?? files
        index = (try? MetadataIndex.build(from: v)) ?? index
        pendingCursorOffset = cursorOffset
    }

    public func openNote(relativePath: String) {
        guard let root = vaultRoot else { return }
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        if let f = files.first(where: { $0.url.standardizedFileURL == target }) { open(f); return }
        if let v = vault { files = (try? v.markdownFiles()) ?? files }
        if let f = files.first(where: { $0.url.standardizedFileURL == target }) { open(f) }
    }
}
