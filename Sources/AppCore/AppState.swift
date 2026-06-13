import Foundation
import Combine
import VaultKit
import MKSearchKit

public final class AppState: ObservableObject {
    @Published public var vaultRoot: URL?
    @Published public var files: [MarkdownFile] = []
    @Published public var selectedFile: MarkdownFile?
    @Published public var activeText: String = ""
    /// Disk baseline of the open note; the buffer is dirty when it differs.
    @Published public var savedText: String = ""
    /// External (on-disk) version of the open note awaiting conflict resolution.
    @Published public var externalConflict: String? = nil
    public var isDirty: Bool { activeText != savedText }
    @Published public var index: MetadataIndex = MetadataIndex()
    @Published public var recentVaults: [URL] = []
    @Published public var pendingCursorOffset: Int?
    @Published public var tree: [FileNode] = []
    /// Sidebar sort order; persisted, applies on the next (immediate) reload.
    @Published public var treeSort: TreeSort = .nameAsc {
        didSet {
            defaults.set(treeSort.rawValue, forKey: Self.treeSortKey)
            reloadTree()
        }
    }

    /// Editor base font size (Settings ▸ Appearance ▸ Font size); persisted.
    @Published public var fontSize: Double = 15 {
        didSet { defaults.set(fontSize, forKey: Self.fontSizeKey) }
    }
    public let rendererRegistry = DefaultRendererRegistry()

    private var vault: Vault?
    private var watcher: VaultWatcher?
    private var autosaveCancellable: AnyCancellable?
    private var conflictPaused = false
    private let autosaveInterval: TimeInterval
    public private(set) var searchIndex: SearchIndex?
    /// Bumps whenever a background reindex completes (search panel refresh hook).
    @Published public private(set) var searchIndexUpdatedAt = Date()
    private let searchQueue = DispatchQueue(label: "io.hanji.searchindex", qos: .utility)
    private let defaults: UserDefaults
    private static let recentsKey = "io.hanji.recentVaults"
    private static let treeSortKey = "io.hanji.treeSort"
    private static let fontSizeKey = "io.hanji.fontSize"

    public init(defaults: UserDefaults = .standard, autosaveInterval: TimeInterval = 0.8) {
        self.defaults = defaults
        self.autosaveInterval = autosaveInterval
        let paths = (defaults.array(forKey: Self.recentsKey) as? [String]) ?? []
        recentVaults = paths.map { URL(fileURLWithPath: $0) }
        if let raw = defaults.string(forKey: Self.treeSortKey), let sort = TreeSort(rawValue: raw) {
            treeSort = sort
        }
        let storedSize = defaults.double(forKey: Self.fontSizeKey)
        if storedSize >= 10 && storedSize <= 30 { fontSize = storedSize }
        autosaveCancellable = $activeText
            .debounce(for: .seconds(autosaveInterval), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.flushPendingSave() }
    }

    public func openVault(at root: URL) {
        let v = Vault(root: root)
        vault = v
        vaultRoot = root
        files = (try? v.markdownFiles()) ?? []
        tree = (try? v.tree(sort: treeSort)) ?? []
        index = (try? MetadataIndex.build(from: v)) ?? MetadataIndex()
        selectedFile = nil
        activeText = ""
        savedText = ""
        externalConflict = nil
        conflictPaused = false
        addRecent(root)
        watcher?.stop()
        watcher = VaultWatcher(root: root) { [weak self] in self?.reloadTree() }
        searchIndex = try? SearchIndex(vaultRoot: root)
        scheduleReindex()
    }

    /// Rebuild tree/files/index from disk (our ops and the FS watcher both call
    /// this; it is idempotent). Clears the editor if the open note disappeared.
    public func reloadTree() {
        guard let v = vault else { return }
        tree = (try? v.tree(sort: treeSort)) ?? []
        files = (try? v.markdownFiles()) ?? files
        index = (try? MetadataIndex.build(from: v)) ?? index
        if let sel = selectedFile, !FileManager.default.fileExists(atPath: sel.url.path) {
            selectedFile = nil
            activeText = ""
        }
        scheduleReindex()
    }

    public func open(_ file: MarkdownFile) {
        flushPendingSave()                       // don't lose edits on the previous note
        selectedFile = file
        let text = (try? vault?.read(file)) ?? ""
        activeText = text
        savedText = text
        externalConflict = nil
        conflictPaused = false
    }

    /// Toolbar/menu "Save" — writes only if there are unsaved changes.
    public func save() { flushPendingSave() }

    /// Write the buffer if dirty and not paused for a conflict. Safe to call
    /// directly (tests, note switch, quit); idempotent when clean.
    public func flushPendingSave() {
        guard !conflictPaused, isDirty, let file = selectedFile, let vault else { return }
        try? vault.write(activeText, to: file)
        savedText = activeText
        scheduleReindex()
    }

    /// Background reindex. A full pass with mtime-skip is cheap and
    /// self-correcting, so every write path and the FS watcher just call this;
    /// the serial utility queue coalesces bursts.
    public func scheduleReindex() {
        guard let index = searchIndex, let root = vaultRoot else { return }
        searchQueue.async { [weak self] in
            guard (try? index.reindexAll(vault: root)) != nil else { return }
            DispatchQueue.main.async { self?.searchIndexUpdatedAt = Date() }
        }
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

    // MARK: - File management (file tree)

    /// An undoable sidebar file operation (see `undoLastFileOperation`).
    public enum FileOperation {
        case created(URL)
        case renamed(from: URL, to: URL)
        case moved(from: URL, to: URL)
        case trashed(original: URL, trashed: URL)
        case copied(URL)          // duplicate / import results
    }

    @Published public private(set) var fileOperations: [FileOperation] = []
    public var canUndoFileOperation: Bool { !fileOperations.isEmpty }

    /// Undo the most recent file operation (create/rename/move/trash/duplicate/import).
    public func undoLastFileOperation() {
        guard let op = fileOperations.popLast(), let v = vault else { return }
        let fm = FileManager.default
        switch op {
        case .created(let url), .copied(let url):
            try? v.delete(url)                              // to Trash, still recoverable
        case .renamed(let from, let to), .moved(let from, let to):
            try? fm.moveItem(at: to, to: from)
        case .trashed(let original, let trashed):
            try? fm.moveItem(at: trashed, to: original)
        }
        reloadTree()
    }

    /// Create an empty note (auto-named) in `folder` (vault root when nil) and open it.
    @discardableResult
    public func newNote(inFolder folder: URL? = nil, name: String? = nil) -> URL? {
        guard let v = vault, let url = try? v.createNote(inFolder: folder, name: name) else { return nil }
        fileOperations.append(.created(url))
        reloadTree()
        if let f = files.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { open(f) }
        return url
    }

    /// Create a folder (auto-named) in `folder` (vault root when nil).
    @discardableResult
    public func newFolder(inFolder folder: URL? = nil, name: String? = nil) -> URL? {
        guard let v = vault, let url = try? v.createFolder(inFolder: folder, name: name) else { return nil }
        fileOperations.append(.created(url))
        reloadTree()
        return url
    }

    /// Rename a note or folder; if the open note was renamed, keep it open.
    @discardableResult
    public func rename(_ url: URL, to newName: String) throws -> URL {
        guard let v = vault else { throw VaultError.invalidName }
        let wasOpen = selectedFile?.url.standardizedFileURL == url.standardizedFileURL
        let newURL = try v.rename(url, to: newName)
        if newURL.standardizedFileURL != url.standardizedFileURL {
            fileOperations.append(.renamed(from: url, to: newURL))
        }
        reloadTree()
        if wasOpen, let f = files.first(where: { $0.url.standardizedFileURL == newURL.standardizedFileURL }) { open(f) }
        return newURL
    }

    /// Move a note or folder into another folder; if the open note moved, keep it open.
    @discardableResult
    public func move(_ url: URL, into folder: URL) throws -> URL {
        guard let v = vault else { throw VaultError.invalidName }
        let wasOpen = selectedFile?.url.standardizedFileURL == url.standardizedFileURL
        let newURL = try v.move(url, into: folder)
        if newURL.standardizedFileURL != url.standardizedFileURL {
            fileOperations.append(.moved(from: url, to: newURL))
        }
        reloadTree()
        if wasOpen, let f = files.first(where: { $0.url.standardizedFileURL == newURL.standardizedFileURL }) { open(f) }
        return newURL
    }

    /// Move a note or folder to the Trash. Closes the editor if the open note went away.
    public func delete(_ url: URL) {
        guard let v = vault else { return }
        if let trashed = try? v.delete(url) {
            fileOperations.append(.trashed(original: url, trashed: trashed))
        }
        reloadTree()
    }

    /// Duplicate a note or folder next to the original.
    @discardableResult
    public func duplicate(_ url: URL) -> URL? {
        guard let v = vault, let copy = try? v.duplicate(url) else { return nil }
        fileOperations.append(.copied(copy))
        reloadTree()
        return copy
    }

    /// Copy external `.md` files into `folder` (vault root when nil); returns the new URLs.
    @discardableResult
    public func importNotes(_ sources: [URL], into folder: URL? = nil) -> [URL] {
        guard let v = vault else { return [] }
        var imported: [URL] = []
        for source in sources {
            if let url = try? v.importNote(from: source, into: folder) {
                fileOperations.append(.copied(url))
                imported.append(url)
            }
        }
        if !imported.isEmpty { reloadTree() }
        return imported
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
        reloadTree()
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
