import Foundation
import Combine
import AppKit
import VaultKit
import MKSearchKit
import MarkdownCore

public final class AppState: ObservableObject {
    @Published public var vaultRoot: URL?
    @Published public var files: [MarkdownFile] = []
    @Published public var selectedFile: MarkdownFile?
    @Published public var activeText: String = ""
    /// Disk baseline of the open note; the buffer is dirty when it differs.
    @Published public var savedText: String = ""
    /// External (on-disk) version of the open note awaiting conflict resolution.
    @Published public var externalConflict: String? = nil
    /// Set when a note couldn't be opened (e.g. not UTF-8); the UI shows it and clears it.
    @Published public var openError: String? = nil
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
    @Published public private(set) var panes: [Pane] = [Pane()]
    @Published public var activePaneID: UUID?
    public var activePane: Pane? { panes.first { $0.id == activePaneID } ?? panes.first }
    public var isSplit: Bool { panes.count > 1 }
    /// Active pane's tabs / active tab (proxies; views re-render via objectWillChange).
    public var tabs: [OpenTab] { activePane?.tabs ?? [] }
    public var activeTabID: UUID? { activePane?.activeTabID }
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
    private let saveQueue = DispatchQueue(label: "io.hanji.save", qos: .utility)
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
        activePaneID = panes.first?.id
        autosaveCancellable = $activeText
            .debounce(for: .seconds(autosaveInterval), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.autosave() }
    }

    public func openVault(at root: URL) {
        flushPendingSave()                       // don't lose edits when switching vaults
        resignEditorFocus()                      // editors are torn down as panes reset (avoid teardown-time hang)
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
        panes = [Pane()]
        activePaneID = panes[0].id
        addRecent(root)
        watcher?.stop()
        watcher = VaultWatcher(root: root) { [weak self] in self?.reloadTree() }
        searchIndex = try? SearchIndex(vaultRoot: root)
        scheduleReindex()
    }

    /// Rebuild tree/files/index from disk (our ops and the FS watcher both call
    /// this; it is idempotent). Reconciles every open tab against disk.
    public func reloadTree() {
        guard let v = vault else { return }
        tree = (try? v.tree(sort: treeSort)) ?? []
        files = (try? v.markdownFiles()) ?? files
        reconcileTabs()
        scheduleReindex()
    }

    /// Reconcile every open tab against disk after an FS change: close tabs whose
    /// file vanished; for surviving tabs detect external edits (the active tab
    /// uses the live working fields, others their snapshot).
    private func reconcileTabs() {
        guard let vault else { return }
        let fm = FileManager.default
        for pane in panes {
            for gone in pane.tabs.filter({ !fm.fileExists(atPath: $0.file.url.path) }) {
                removeTab(gone.id, in: pane)
            }
        }
        for pane in panes {
            let isActivePane = pane.id == activePaneID
            for idx in pane.tabs.indices {
                let isActiveTab = isActivePane && pane.tabs[idx].id == pane.activeTabID
                let baseline = isActiveTab ? savedText : pane.tabs[idx].savedText
                guard let disk = try? vault.read(pane.tabs[idx].file), disk != baseline else { continue }
                let conflicting = isActiveTab ? (externalConflict != nil) : (pane.tabs[idx].externalConflict != nil)
                if conflicting { continue }
                let dirty = isActiveTab ? isDirty : pane.tabs[idx].isDirty
                if dirty {
                    if isActiveTab { conflictPaused = true; externalConflict = disk }
                    else { pane.tabs[idx].externalConflict = disk }
                } else {
                    if isActiveTab { activeText = disk; savedText = disk }
                    else { pane.tabs[idx].text = disk; pane.tabs[idx].savedText = disk }
                }
            }
        }
        for pane in Array(panes) { closePaneIfEmpty(pane) }
    }

    /// Remove a tab (no save — file gone) from a specific pane.
    private func removeTab(_ id: UUID, in pane: Pane) {
        guard let idx = pane.tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActiveTab = pane.id == activePaneID && id == pane.activeTabID
        objectWillChange.send()
        pane.tabs.remove(at: idx)
        if wasActiveTab {
            if let next = pane.tabs[safe: idx] ?? pane.tabs.last {
                pane.activeTabID = next.id
                hydrate(from: next)
            } else {
                pane.activeTabID = nil
                if panes.count == 1 { clearActive() }
            }
        } else if id == pane.activeTabID {
            pane.activeTabID = pane.tabs[safe: idx]?.id ?? pane.tabs.last?.id
        }
    }

    /// Open the note a wiki/markdown link targets (filename base or vault-relative
    /// path, Obsidian-style, case-insensitive). No-op if nothing matches.
    public func openLink(_ target: String) {
        guard let root = vaultRoot else { return }
        var t = target.trimmingCharacters(in: .whitespaces)
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }   // drop heading anchor
        if t.lowercased().hasSuffix(".md") { t = String(t.dropLast(3)) }
        let wanted = t.lowercased()
        guard !wanted.isEmpty else { return }
        let prefix = root.standardizedFileURL.path + "/"
        func relBase(_ u: URL) -> String {
            let p = u.standardizedFileURL.path
            var r = p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : u.lastPathComponent
            if r.lowercased().hasSuffix(".md") { r = String(r.dropLast(3)) }
            return r.lowercased()
        }
        if let match = files.first(where: { relBase($0.url) == wanted
            || $0.url.deletingPathExtension().lastPathComponent.lowercased() == wanted }) {
            open(match)
        }
    }

    /// Compare two file URLs that may have different symlink representations (macOS /var ↔ /private/var).
    /// Compares inodes when the file exists; falls back to path comparison otherwise.
    private func urlSameFile(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        if stat(a.path, &sa) == 0, stat(b.path, &sb) == 0 {
            return sa.st_ino == sb.st_ino && sa.st_dev == sb.st_dev
        }
        // File doesn't exist yet or path is wrong — fall back to standardized comparison.
        return a.standardizedFileURL == b.standardizedFileURL
    }

    /// Copy the live working state into the active tab's snapshot.
    /// (`conflictPaused` is intentionally not stored — `hydrate` derives it from
    /// `externalConflict != nil`.)
    private func writeBackActive() {
        guard let pane = activePane, let id = pane.activeTabID,
              let idx = pane.tabs.firstIndex(where: { $0.id == id }) else { return }
        pane.tabs[idx].text = activeText
        pane.tabs[idx].savedText = savedText
        pane.tabs[idx].externalConflict = externalConflict
    }

    /// Load the working state from a tab snapshot.
    private func hydrate(from tab: OpenTab) {
        selectedFile = tab.file
        activeText = tab.text
        savedText = tab.savedText
        externalConflict = tab.externalConflict
        conflictPaused = (tab.externalConflict != nil)
        pendingCursorOffset = 0
    }

    private func clearActive() {
        activePane?.activeTabID = nil
        selectedFile = nil
        activeText = ""
        savedText = ""
        externalConflict = nil
        conflictPaused = false
    }

    /// Synchronous write of a non-active tab's snapshot if dirty.
    private func flush(_ tab: OpenTab) {
        guard tab.isDirty, let vault else { return }
        try? vault.write(tab.text, to: tab.file)
        scheduleReindex()
    }

    public func open(_ file: MarkdownFile) {
        guard let pane = activePane else { return }
        if let existing = pane.tabs.first(where: { urlSameFile($0.file.url, file.url) }) {
            switchTab(existing.id); return
        }
        // Read before touching the current buffer. A note that can't be decoded
        // (not UTF-8) must not open as an empty buffer — the first keystroke would
        // autosave over the original bytes.
        guard let text = try? vault?.read(file) else {
            openError = "Hanji couldn\u{2019}t read \u{201C}\(file.name)\u{201D} as UTF-8 text, so it left the note closed rather than risk overwriting it."
            return
        }
        flushPendingSave()
        writeBackActive()
        let tab = OpenTab(file: file, text: text)
        objectWillChange.send()
        pane.tabs.append(tab)
        pane.activeTabID = tab.id
        hydrate(from: tab)
    }

    /// Make an already-open tab active.
    public func switchTab(_ id: UUID) {
        guard let pane = activePane, id != pane.activeTabID,
              let tab = pane.tabs.first(where: { $0.id == id }) else { return }
        flushPendingSave()
        writeBackActive()
        objectWillChange.send()
        pane.activeTabID = id
        hydrate(from: tab)
    }

    /// Close a tab (saving it if dirty); a neighbor becomes active, or the
    /// editor clears if it was the last tab.
    public func closeTab(_ id: UUID) {
        guard let pane = activePane, let idx = pane.tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == pane.activeTabID
        if wasActive { flushPendingSave() } else { flush(pane.tabs[idx]) }
        objectWillChange.send()
        pane.tabs.remove(at: idx)
        if wasActive {
            if let next = pane.tabs[safe: idx] ?? pane.tabs.last {
                pane.activeTabID = next.id
                hydrate(from: next)
            } else {
                pane.activeTabID = nil
                closePaneIfEmpty(pane)
            }
        }
    }

    /// Remove an emptied pane and re-activate another; for the lone pane, clear.
    /// Resign the editor's first responder *now* (on the main thread, outside any
    /// SwiftUI view-graph update) before a structural change tears its NSTextView
    /// out of the window. If the text view is still first responder when SwiftUI
    /// removes it, AppKit deactivates its input context synchronously, pumping a
    /// nested runloop (IMK XPC) that re-enters SwiftUI's update → unbounded
    /// recursion that pins a core at 100% and hangs the app.
    private func resignEditorFocus() {
        NSApp?.keyWindow?.makeFirstResponder(nil)
    }

    private func closePaneIfEmpty(_ pane: Pane) {
        guard pane.tabs.isEmpty else { return }
        if panes.count > 1 {
            resignEditorFocus()   // the collapsing pane's editor view is about to be torn down
            panes.removeAll { $0.id == pane.id }
            let first = panes[0]
            activePaneID = first.id
            if let t = first.tabs.first(where: { $0.id == first.activeTabID }) { hydrate(from: t) }
            else { clearActive() }
        } else {
            clearActive()
        }
    }

    /// Focus another pane: persist the live working state into the current pane's
    /// active tab, then hydrate from the target pane's active tab.
    public func focusPane(_ id: UUID) {
        guard id != activePaneID, let target = panes.first(where: { $0.id == id }) else { return }
        flushPendingSave()
        writeBackActive()
        activePaneID = id
        if let tab = target.tabs.first(where: { $0.id == target.activeTabID }) { hydrate(from: tab) }
        else { clearActive() }
    }

    /// Open the active document in a new right pane (no-op if already split or empty).
    public func splitRight() {
        guard panes.count == 1, let cur = activePane, let id = cur.activeTabID else { return }
        resignEditorFocus()   // the single-pane editor is rebuilt into a fresh HSplitView; resign FR first
        flushPendingSave()
        writeBackActive()
        guard let snapshot = cur.tabs.first(where: { $0.id == id }) else { return }
        let right = Pane(tabs: [snapshot], activeTabID: snapshot.id)
        panes.append(right)
        activePaneID = right.id
        hydrate(from: snapshot)
    }

    /// Move `sourceID` to just before `targetID` within `pane` (insert-style);
    /// `targetID == nil` moves it to the end. Pure positional change — the active
    /// tab and the live working fields are untouched. No-op if source == target
    /// or either id is absent.
    public func moveTab(_ sourceID: UUID, before targetID: UUID?, in pane: Pane) {
        guard sourceID != targetID,
              let from = pane.tabs.firstIndex(where: { $0.id == sourceID }) else { return }
        objectWillChange.send()
        let moved = pane.tabs.remove(at: from)
        if let targetID, let to = pane.tabs.firstIndex(where: { $0.id == targetID }) {
            pane.tabs.insert(moved, at: to)
        } else {
            pane.tabs.append(moved)
        }
    }

    /// Which side a tab is sent to. Left = `panes[0]`, right = `panes[1]`.
    public enum PaneSide { case left, right }

    /// Whether `moveTabToSide(tabID, side)` would change anything: a neighbour
    /// pane on that side exists (merge), or there's room for a new pane
    /// (`panes.count < 2`) and the source keeps at least one tab.
    public func canMoveTab(_ tabID: UUID, _ side: PaneSide) -> Bool {
        guard let srcIndex = panes.firstIndex(where: { p in p.tabs.contains(where: { $0.id == tabID }) })
        else { return false }
        let neighbour = side == .right ? srcIndex + 1 : srcIndex - 1
        if neighbour >= 0 && neighbour < panes.count { return true }
        return panes.count < 2 && panes[srcIndex].tabs.count >= 2
    }

    /// Move the tab into the pane on `side`: merge into an existing neighbour, or
    /// create a new pane there (only when there's room and the source keeps a
    /// tab). The moved tab becomes that pane's active tab and the pane is focused;
    /// an emptied source pane collapses. No-op when the move is impossible.
    public func moveTabToSide(_ tabID: UUID, _ side: PaneSide) {
        guard let srcIndex = panes.firstIndex(where: { p in p.tabs.contains(where: { $0.id == tabID }) }),
              let tabIdx = panes[srcIndex].tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let src = panes[srcIndex]
        let neighbourIndex = side == .right ? srcIndex + 1 : srcIndex - 1
        let hasNeighbour = neighbourIndex >= 0 && neighbourIndex < panes.count
        guard hasNeighbour || (panes.count < 2 && src.tabs.count >= 2) else { return }
        resignEditorFocus()   // panes change rebuilds editor views (incl. 1→2 fresh HSplitView); resign FR first

        // The move ends in `hydrate(from:)`, so the live working state is always
        // replaced — persist it first. That matters even when the moved tab isn't
        // the live one (a background tab, or a tab in the other pane): the live
        // tab's unsaved buffer would otherwise be dropped. Same order as focusPane.
        flushPendingSave()
        writeBackActive()

        objectWillChange.send()
        let snapshot = src.tabs[tabIdx]
        let movedActive = tabID == src.activeTabID
        src.tabs.remove(at: tabIdx)
        if movedActive { src.activeTabID = src.tabs[safe: tabIdx]?.id ?? src.tabs.last?.id }

        let target: Pane
        if hasNeighbour {
            target = panes[neighbourIndex]
            target.tabs.append(snapshot)
        } else {
            let newPane = Pane(tabs: [snapshot], activeTabID: snapshot.id)
            panes.insert(newPane, at: side == .right ? srcIndex + 1 : srcIndex)
            target = newPane
        }
        target.activeTabID = snapshot.id
        activePaneID = target.id
        hydrate(from: snapshot)
        closePaneIfEmpty(src)
    }

    /// Toolbar/menu "Save" — writes only if there are unsaved changes.
    public func save() { flushPendingSave() }

    /// Synchronous write — used for note switch, quit, and tests where the bytes
    /// must hit disk before the next step. Idempotent when clean.
    public func flushPendingSave() {
        guard !conflictPaused, isDirty, let file = selectedFile, let vault else { return }
        try? vault.write(activeText, to: file)
        savedText = activeText
        scheduleReindex()
    }

    /// Debounced autosave: write OFF the main thread so a save never blocks
    /// typing (iCloud writes can stall on file coordination). The baseline is
    /// marked clean immediately so a follow-up watcher fire sees no conflict.
    private func autosave() {
        guard !conflictPaused, isDirty, let file = selectedFile, let vault else { return }
        let text = activeText
        savedText = text
        saveQueue.async { [weak self] in
            try? vault.write(text, to: file)
            DispatchQueue.main.async { self?.scheduleReindex() }
        }
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
        /// A vault-wide replace, with each rewritten file's previous text. One
        /// entry covers the whole batch so undo can't leave the vault half-replaced.
        case replaced([(url: URL, previous: String)])
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
        case .replaced(let entries):
            // Same atomic write path the replace used, so a half-written file
            // can't survive an undo either.
            for entry in entries {
                try? v.write(entry.previous, to: MarkdownFile(url: entry.url))
            }
        }
        reloadTree()
    }

    // MARK: - Vault-wide find & replace

    /// One file's share of a pending replace — drives the confirmation list.
    public struct ReplacePreviewRow: Identifiable {
        public let file: MarkdownFile
        public let count: Int
        public var id: URL { file.url }
    }

    public struct VaultReplaceSummary: Equatable {
        public let files: Int
        public let occurrences: Int
        public static let none = VaultReplaceSummary(files: 0, occurrences: 0)
    }

    /// What a replace would touch, without writing anything — the caller shows
    /// this before asking to go ahead.
    public func previewReplaceInVault(find: String, caseSensitive: Bool) -> [ReplacePreviewRow] {
        guard !find.isEmpty, let vault else { return [] }
        var rows: [ReplacePreviewRow] = []
        for file in (try? vault.markdownFiles()) ?? [] {
            guard let text = try? vault.read(file) else { continue }
            let hits = TextReplace.count(of: find, in: text, caseSensitive: caseSensitive)
            if hits > 0 { rows.append(ReplacePreviewRow(file: file, count: hits)) }
        }
        return rows.sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
    }

    /// Replace across every note in the vault.
    ///
    /// The open note's unsaved edits are flushed first so they take part rather
    /// than being clobbered by the rewrite, and `reloadTree()` afterwards lets the
    /// existing reconcile path refresh open tabs (dirty ones raise the usual
    /// conflict banner instead of losing work).
    @discardableResult
    public func replaceInVault(find: String, with replacement: String,
                               caseSensitive: Bool) -> VaultReplaceSummary {
        guard !find.isEmpty, let vault else { return .none }
        flushPendingSave()
        var restore: [(url: URL, previous: String)] = []
        var occurrences = 0
        for file in (try? vault.markdownFiles()) ?? [] {
            guard let text = try? vault.read(file) else { continue }
            let hits = TextReplace.count(of: find, in: text, caseSensitive: caseSensitive)
            guard hits > 0,
                  let updated = TextReplace.apply(find, with: replacement, in: text,
                                                  caseSensitive: caseSensitive),
                  (try? vault.write(updated, to: file)) != nil
            else { continue }
            restore.append((file.url, text))
            occurrences += hits
        }
        // Nothing written: leave the undo stack alone so a later ⌥⌘Z doesn't
        // revert some unrelated earlier operation.
        guard !restore.isEmpty else { return .none }
        fileOperations.append(.replaced(restore))
        reloadTree()
        return VaultReplaceSummary(files: restore.count, occurrences: occurrences)
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
        // Resolve which tab/selectedFile corresponds to `url` BEFORE the rename,
        // while the file still exists and stat(2) can compare inodes reliably.
        let wasOpen = selectedFile.map { urlSameFile($0.url, url) } ?? false
        // Capture which pane/tab indices match before the rename (inodes valid now).
        var paneTabMatches: [(Int, Int)] = []
        for (pi, pane) in panes.enumerated() {
            if let ti = pane.tabs.firstIndex(where: { urlSameFile($0.file.url, url) }) {
                paneTabMatches.append((pi, ti))
            }
        }
        let newURL = try v.rename(url, to: newName)
        if newURL.standardizedFileURL != url.standardizedFileURL {
            fileOperations.append(.renamed(from: url, to: newURL))
            let newFile = MarkdownFile(url: newURL)
            for (pi, ti) in paneTabMatches { panes[pi].tabs[ti].file = newFile }
            if wasOpen { selectedFile = newFile }
        }
        reloadTree()
        return newURL
    }

    /// Move a note or folder into another folder; if the moved note is open in a
    /// tab, update that tab in place (no duplicate/stale tab).
    @discardableResult
    public func move(_ url: URL, into folder: URL) throws -> URL {
        guard let v = vault else { throw VaultError.invalidName }
        let wasActiveFile = selectedFile.map { urlSameFile($0.url, url) } ?? false
        // Capture which pane/tab indices match before the move (inodes valid now).
        var paneTabMatches: [(Int, Int)] = []
        for (pi, pane) in panes.enumerated() {
            if let ti = pane.tabs.firstIndex(where: { urlSameFile($0.file.url, url) }) {
                paneTabMatches.append((pi, ti))
            }
        }
        let newURL = try v.move(url, into: folder)
        if newURL.standardizedFileURL != url.standardizedFileURL {
            fileOperations.append(.moved(from: url, to: newURL))
            let newFile = MarkdownFile(url: newURL)
            for (pi, ti) in paneTabMatches { panes[pi].tabs[ti].file = newFile }
            if wasActiveFile { selectedFile = newFile }
        }
        reloadTree()
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

    /// `relativePath` resolved under the vault, or nil if it climbs out of it.
    /// These paths come from vault content (a periodic-notes folder, a template
    /// path), so a shared vault must not be able to point them elsewhere.
    private func urlInsideVault(_ relativePath: String) -> URL? {
        guard let root = vaultRoot?.standardizedFileURL else { return nil }
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(prefix) ? url : nil
    }

    public func noteExists(relativePath: String) -> Bool {
        guard let url = urlInsideVault(relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func readNote(relativePath: String) -> String? {
        guard let url = urlInsideVault(relativePath) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public func createNote(relativePath: String, text: String, cursorOffset: Int?) {
        guard let url = urlInsideVault(relativePath), let v = vault else { return }
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

    // MARK: - Conflict resolution

    /// Conflict banner: discard my unsaved edits and take the on-disk version.
    public func resolveConflictReloadingDisk() {
        guard let diskText = externalConflict else { return }
        activeText = diskText
        savedText = diskText
        externalConflict = nil
        conflictPaused = false
    }

    /// Conflict banner: keep my edits and write them over the on-disk version.
    public func resolveConflictKeepingMine() {
        guard let diskText = externalConflict else { return }
        savedText = diskText                        // now activeText != savedText → dirty
        externalConflict = nil
        conflictPaused = false
        flushPendingSave()                          // write my version to disk
    }
}
