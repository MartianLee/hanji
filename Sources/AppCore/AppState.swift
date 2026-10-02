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
    // The open note's working fields. They mirror its NoteBuffer — shared with
    // any other tab on the same note — and write straight through to it.
    @Published public var activeText: String = "" { didSet { liveBuffer?.text = activeText } }
    /// Disk baseline of the open note; the buffer is dirty when it differs.
    @Published public var savedText: String = "" { didSet { liveBuffer?.savedText = savedText } }
    /// External (on-disk) version of the open note awaiting conflict resolution.
    @Published public var externalConflict: String? = nil {
        didSet { liveBuffer?.externalConflict = externalConflict }
    }
    /// Something the user needs to know about — a note that couldn't be opened or
    /// saved, a close that would lose work. The UI shows it as an alert and clears it.
    public struct Notice: Equatable {
        public let title: String
        public let message: String
    }
    @Published public var notice: Notice? = nil
    /// Code units compared (NSString), not Unicode equivalence (String `!=`):
    /// asked on every update of the tab bar and the Save menu, and a note's
    /// bytes are what autosave writes.
    public var isDirty: Bool { !(activeText as NSString).isEqual(to: savedText) }
    /// The open note's file vanished while it had unsaved edits (see `reconcileTabs`).
    @Published public private(set) var missingOnDisk = false {
        didSet { liveBuffer?.missingOnDisk = missingOnDisk }
    }
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
    /// Light, dark, or whatever the system uses (Settings ▸ Appearance ▸ Theme).
    @Published public var theme: AppearanceTheme = .system {
        didSet { defaults.set(theme.rawValue, forKey: Self.themeKey) }
    }
    /// Body line height as a multiple of the font's (Settings ▸ Appearance).
    @Published public var lineHeight: Double = AppState.defaultLineHeight {
        didSet { defaults.set(lineHeight, forKey: Self.lineHeightKey) }
    }
    public static let defaultLineHeight = 1.3
    public static let lineHeightRange = 1.2...1.8
    /// Keep the text in a centred column (Settings ▸ Appearance), like Obsidian's
    /// "Readable line length"; off shows today's full width.
    @Published public var readableLineLength = false {
        didSet { defaults.set(readableLineLength, forKey: Self.readableKey) }
    }
    /// Editor fonts (Settings ▸ Appearance), as `EditorFonts` choices: "" is the
    /// system's (San Francisco / SF Mono), otherwise a family name.
    @Published public var textFont = "" {
        didSet { defaults.set(textFont, forKey: Self.textFontKey) }
    }
    @Published public var codeFont = "" {
        didSet { defaults.set(codeFont, forKey: Self.codeFontKey) }
    }
    /// The column width readable line length keeps.
    public static let readableLineWidth: Double = 700
    @Published public private(set) var panes: [Pane] = [Pane()]
    @Published public var activePaneID: UUID?
    public var activePane: Pane? { panes.first { $0.id == activePaneID } ?? panes.first }
    public var isSplit: Bool { panes.count > 1 }
    /// Active pane's tabs / active tab (proxies; views re-render via objectWillChange).
    public var tabs: [OpenTab] { activePane?.tabs ?? [] }
    public var activeTabID: UUID? { activePane?.activeTabID }
    /// The buffer the working fields mirror: the active pane's active tab's.
    private var liveBuffer: NoteBuffer? {
        activePane.flatMap { pane in pane.tabs.first { $0.id == pane.activeTabID }?.buffer }
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
    private let saveQueue = DispatchQueue(label: "io.hanji.save", qos: .utility)
    /// Notes with an autosave on the save queue, and the disk contents that are
    /// our own while it's there: the text before that save and the text it
    /// writes. Until it lands the note is only provisionally clean, so anything
    /// else on disk is someone else's change (a conflict), not a reason to reload.
    private var autosavesInFlight: [URL: [String]] = [:]
    /// Whether an autosave is still on its way to disk.
    public var hasSavesInFlight: Bool { !autosavesInFlight.isEmpty }
    /// Autosaves that failed on the save queue, not yet applied on main.
    /// Only touched on `saveQueue`.
    private var autosaveFailures: [(file: MarkdownFile, text: String, previous: String, error: Error)] = []
    private let defaults: UserDefaults
    private static let recentsKey = "io.hanji.recentVaults"
    private static let treeSortKey = "io.hanji.treeSort"
    private static let fontSizeKey = "io.hanji.fontSize"
    private static let themeKey = "io.hanji.theme"
    private static let lineHeightKey = "io.hanji.lineHeight"
    private static let readableKey = "io.hanji.readableLineLength"
    private static let textFontKey = "io.hanji.textFont"
    private static let codeFontKey = "io.hanji.codeFont"
    private static func readingKey(_ root: URL) -> String { "io.hanji.reading.\(root.standardizedFileURL.path)" }
    private static func pinsKey(_ root: URL) -> String { "io.hanji.pinned.\(root.standardizedFileURL.path)" }

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
        if let raw = defaults.string(forKey: Self.themeKey), let t = AppearanceTheme(rawValue: raw) { theme = t }
        let storedLineHeight = defaults.double(forKey: Self.lineHeightKey)
        if Self.lineHeightRange.contains(storedLineHeight) { lineHeight = storedLineHeight }
        readableLineLength = defaults.bool(forKey: Self.readableKey)
        textFont = defaults.string(forKey: Self.textFontKey) ?? ""
        codeFont = defaults.string(forKey: Self.codeFontKey) ?? ""
        activePaneID = panes.first?.id
        autosaveCancellable = $activeText
            .debounce(for: .seconds(autosaveInterval), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.autosave() }
    }

    public func openVault(at root: URL) {
        // Don't lose edits when switching vaults: save everything, and stay put if
        // some note's edits can't be written yet.
        let unsaved = saveAllForClose()
        guard unsaved.isEmpty else {
            notice = Notice(title: "Unsaved changes",
                            message: "Hanji couldn\u{2019}t save \(Self.list(unsaved)) yet, so it kept this vault open. Resolve or save \(unsaved.count == 1 ? "it" : "them") first.")
            return
        }
        resignEditorFocus()                      // editors are torn down as panes reset (avoid teardown-time hang)
        let v = Vault(root: root)
        vault = v
        vaultRoot = root
        files = (try? v.markdownFiles()) ?? []
        tree = (try? v.tree(sort: treeSort)) ?? []
        index = (try? MetadataIndex.build(from: v)) ?? MetadataIndex()
        panes = [Pane()]                         // first, so clearing the fields below
        activePaneID = panes[0].id               // can't write into the old vault's buffers
        selectedFile = nil
        activeText = ""
        savedText = ""
        externalConflict = nil
        missingOnDisk = false
        conflictPaused = false
        fileOperations = []                      // undo history belongs to the vault it came from
        addRecent(root)
        watcher?.stop()
        watcher = VaultWatcher(root: root) { [weak self] in self?.reloadTree() }
        searchIndex = try? SearchIndex(vaultRoot: root)
        scheduleReindex()
        restorePins()
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

    /// Reconcile every open note against disk after an FS change, once per note
    /// (its buffer), not per tab. A note whose file vanished closes if it was
    /// clean; with unsaved edits it stays open, flagged `missingOnDisk`, until the
    /// user saves it again or closes it (a git checkout or a sync client can
    /// remove a file mid-edit). For the rest, detect external edits: a clean note
    /// reloads, a dirty one raises the conflict banner.
    private func reconcileTabs() {
        guard let vault else { return }
        let fm = FileManager.default
        for buffer in openBuffers() {
            let gone = !fm.fileExists(atPath: buffer.file.url.path)
            let unsaved = buffer.isDirty || buffer.externalConflict != nil
            if gone && !unsaved && !buffer.missingOnDisk {
                closeTabs(of: buffer)
            } else if gone != buffer.missingOnDisk {
                buffer.missingOnDisk = gone
            }
        }
        for buffer in openBuffers() {
            if let own = autosavesInFlight[buffer.file.url] {
                if let disk = try? vault.read(buffer.file), !own.contains(disk) { buffer.externalConflict = disk }
                continue
            }
            guard let disk = try? vault.read(buffer.file), disk != buffer.savedText else { continue }
            if buffer.externalConflict != nil || buffer.isDirty {
                // (Changed again while the banner is up: offer what's on disk now,
                // or "Reload" would restore a version that's already gone.)
                buffer.externalConflict = disk
            } else {
                buffer.text = disk
                buffer.savedText = disk
            }
        }
        refreshLive()
        dedupeTabs()
        for pane in Array(panes) { closePaneIfEmpty(pane) }
    }

    /// Every open note's buffer, once each.
    private func openBuffers() -> [NoteBuffer] {
        var seen = Set<ObjectIdentifier>()
        return panes.flatMap(\.tabs).map(\.buffer).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func closeTabs(of buffer: NoteBuffer) {
        for pane in panes {
            for tab in pane.tabs where tab.buffer === buffer { removeTab(tab.id, in: pane) }
        }
    }

    /// Keep one copy of each note. Two buffers for one file (renamed away with
    /// unsaved text, then back) merge into the one holding unsaved work — both
    /// stay if they hold different unsaved text, so nothing is dropped. Then each
    /// pane keeps one tab per note (the active one, carrying any pin).
    private func dedupeTabs() {
        let byFile = Dictionary(grouping: openBuffers(), by: { $0.file.url.standardizedFileURL })
        for (_, group) in byFile where group.count > 1 {
            let unsaved = group.filter { $0.isDirty || $0.externalConflict != nil || $0.missingOnDisk }
            if Set(unsaved.map(\.text)).count > 1 { continue }
            let live = liveBuffer
            let keep = unsaved.first ?? group.first { $0 === live } ?? group[0]
            for pane in panes {
                for idx in pane.tabs.indices where group.contains(where: { $0 === pane.tabs[idx].buffer }) {
                    pane.tabs[idx].buffer = keep
                }
            }
        }
        for pane in panes {
            var kept: [ObjectIdentifier: UUID] = [:]
            var dropped = Set<UUID>()
            for tab in pane.tabs {
                let key = ObjectIdentifier(tab.buffer)
                guard let other = kept[key] else { kept[key] = tab.id; continue }
                if tab.id == pane.activeTabID { dropped.insert(other); kept[key] = tab.id }
                else { dropped.insert(tab.id) }
            }
            guard !dropped.isEmpty else { continue }
            objectWillChange.send()
            for tab in pane.tabs where dropped.contains(tab.id) && tab.isPinned {
                if let keeper = pane.tabs.firstIndex(where: { $0.id == kept[ObjectIdentifier(tab.buffer)] }) {
                    pane.tabs[keeper].isPinned = true
                }
            }
            pane.tabs.removeAll { dropped.contains($0.id) }
        }
        persistPins()
        refreshLive()
    }

    /// Remove a tab (no save — file gone) from a specific pane.
    private func removeTab(_ id: UUID, in pane: Pane) {
        guard let idx = pane.tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActiveTab = pane.id == activePaneID && id == pane.activeTabID
        objectWillChange.send()
        let wasPinned = pane.tabs[idx].isPinned
        pane.tabs.remove(at: idx)
        if wasPinned { persistPins() }
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

    /// Every note a `[[` link can point at: vault-relative paths without `.md`
    /// (what `openLink` resolves).
    public var linkTargets: [String] {
        guard let root = vaultRoot?.standardizedFileURL.path else { return [] }
        return files.map { file in
            let path = file.url.standardizedFileURL.path
            let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : file.url.lastPathComponent
            return rel.lowercased().hasSuffix(".md") ? String(rel.dropLast(3)) : rel
        }
    }

    /// Open the note a wiki/markdown link targets (filename base or vault-relative
    /// path, Obsidian-style, case-insensitive). No-op if nothing matches.
    public func openLink(_ target: String, newTab: Bool = false) {
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
            open(match, newTab: newTab)
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

    /// The open buffer for `file`, if any tab shows it.
    private func buffer(for file: MarkdownFile) -> NoteBuffer? {
        openBuffers().first { urlSameFile($0.file.url, file.url) }
    }

    /// Bring the working fields in line with the live buffer after a change made
    /// to buffers directly (reconcile, a background flush, a merge).
    private func refreshLive() {
        guard let b = liveBuffer else { return }
        if selectedFile?.url != b.file.url { selectedFile = b.file }
        if activeText != b.text { activeText = b.text }
        if savedText != b.savedText { savedText = b.savedText }
        if externalConflict != b.externalConflict { externalConflict = b.externalConflict }
        if missingOnDisk != b.missingOnDisk { missingOnDisk = b.missingOnDisk }
        conflictPaused = b.externalConflict != nil || b.missingOnDisk
    }

    /// Load the working fields from a tab's note (its buffer).
    private func hydrate(from tab: OpenTab) {
        selectedFile = tab.file
        activeText = tab.text
        savedText = tab.savedText
        externalConflict = tab.externalConflict
        missingOnDisk = tab.missingOnDisk
        conflictPaused = (tab.externalConflict != nil) || tab.missingOnDisk
        pendingCursorOffset = 0
        liveCaret = 0
    }

    private func clearActive() {
        activePane?.activeTabID = nil
        selectedFile = nil
        activeText = ""
        savedText = ""
        externalConflict = nil
        missingOnDisk = false
        conflictPaused = false
    }

    /// Synchronous write of a note's buffer if dirty. False when the edits are
    /// still only in memory (a failed write — the user has been told — or a
    /// conflict or missing file waiting on the user).
    @discardableResult
    private func flush(_ buffer: NoteBuffer) -> Bool {
        guard buffer.isDirty, let vault else { return true }
        guard buffer.externalConflict == nil, !buffer.missingOnDisk else { return false }
        switch write(buffer.text, to: buffer.file, with: vault, over: buffer.savedText) {
        case .failed: return false
        case .changedOnDisk(let disk):
            buffer.externalConflict = disk
            refreshLive()
            return false
        case .written: break
        }
        buffer.savedText = buffer.text
        refreshLive()
        scheduleReindex()
        return true
    }

    /// Open a note, Obsidian-style: in the current tab, which remembers the note
    /// it showed for Back — or in a new tab when asked, or when the current tab
    /// is pinned. A note already open in this pane just brings its tab forward.
    public func open(_ file: MarkdownFile, newTab: Bool = false) {
        guard let pane = activePane else { return }
        if let existing = pane.tabs.first(where: { urlSameFile($0.file.url, file.url) }) {
            switchTab(existing.id); return
        }
        if !newTab, let idx = pane.tabs.firstIndex(where: { $0.id == pane.activeTabID }), !pane.tabs[idx].isPinned {
            let leaving = here(pane.tabs[idx])
            guard show(file, inTabAt: idx, of: pane) else { return }
            pane.tabs[idx].back.append(leaving)
            if pane.tabs[idx].back.count > Self.historyLimit { pane.tabs[idx].back.removeFirst() }
            pane.tabs[idx].forward.removeAll()
            return
        }
        // Already open in the other pane: show the same note (its buffer).
        if let shared = openBuffers().first(where: { urlSameFile($0.file.url, file.url) }) {
            flushPendingSave()
            var tab = OpenTab(file: file, text: "")
            tab.buffer = shared
            objectWillChange.send()
            pane.tabs.append(tab)
            pane.activeTabID = tab.id
            hydrate(from: tab)
            return
        }
        // Read before touching the current buffer. A note that can't be decoded
        // (not UTF-8) must not open as an empty buffer — the first keystroke would
        // autosave over the original bytes.
        guard let text = readForOpening(file) else { return }
        flushPendingSave()
        let tab = OpenTab(file: file, text: text)
        objectWillChange.send()
        pane.tabs.append(tab)
        pane.activeTabID = tab.id
        hydrate(from: tab)
    }

    /// A note's text for opening, or nil (and the user told) when it can't be
    /// read. A note that can't be decoded (not UTF-8) must not open as an empty
    /// buffer — the first keystroke would autosave over the original bytes.
    private func readForOpening(_ file: MarkdownFile) -> String? {
        if let text = try? vault?.read(file) { return text }
        notice = Notice(title: "Couldn\u{2019}t open note",
                        message: "Hanji couldn\u{2019}t read \u{201C}\(file.name)\u{201D} as UTF-8 text, so it left the note closed rather than risk overwriting it.")
        return nil
    }

    // MARK: Back / forward

    /// How many notes a tab remembers behind it.
    static let historyLimit = 100
    /// Where the live editor's caret is; the editor reports each move, so Back
    /// can return to it.
    private var liveCaret = 0
    public func caretMoved(to offset: Int) { liveCaret = offset }

    private var activeTabIndex: Int? {
        activePane.flatMap { pane in pane.tabs.firstIndex { $0.id == pane.activeTabID } }
    }
    /// A pinned tab keeps its note, so it doesn't step through history either.
    public var canGoBack: Bool {
        activeTabIndex.map { !activePane!.tabs[$0].isPinned && !activePane!.tabs[$0].back.isEmpty } ?? false
    }
    public var canGoForward: Bool {
        activeTabIndex.map { !activePane!.tabs[$0].isPinned && !activePane!.tabs[$0].forward.isEmpty } ?? false
    }
    public func goBack() { step(back: true) }
    public func goForward() { step(back: false) }

    /// The live tab's note and caret, as a history entry.
    private func here(_ tab: OpenTab) -> NavigationEntry {
        NavigationEntry(url: tab.file.url, caret: min(max(liveCaret, 0), (activeText as NSString).length))
    }

    /// One step back or forward in the active tab's history. Notes deleted since
    /// are skipped; a note that's open in another tab of this pane brings that
    /// tab forward instead (a pane shows each note once).
    private func step(back: Bool) {
        guard let pane = activePane, let idx = activeTabIndex, !pane.tabs[idx].isPinned else { return }
        while let entry = back ? pane.tabs[idx].back.popLast() : pane.tabs[idx].forward.popLast() {
            guard let file = files.first(where: { urlSameFile($0.url, entry.url) }) else { continue }
            func putBack() {
                if back { pane.tabs[idx].back.append(entry) } else { pane.tabs[idx].forward.append(entry) }
            }
            if let other = pane.tabs.first(where: { $0.id != pane.activeTabID && urlSameFile($0.file.url, file.url) }) {
                putBack()
                switchTab(other.id)
                return
            }
            let leaving = here(pane.tabs[idx])
            guard show(file, inTabAt: idx, of: pane) else { putBack(); return }
            if back { pane.tabs[idx].forward.append(leaving) } else { pane.tabs[idx].back.append(leaving) }
            let caret = min(entry.caret, (activeText as NSString).length)
            pendingCursorOffset = caret
            liveCaret = caret
            return
        }
        objectWillChange.send()   // entries were dropped: the buttons may change
    }

    /// Show `file` in place of the note in the active pane's tab at `idx`. The
    /// note it leaves is saved first; if that can't happen (a conflict or a
    /// missing file waiting on the user, a failed write), the tab stays where it
    /// is — unless another tab still shows that note, which keeps it open.
    private func show(_ file: MarkdownFile, inTabAt idx: Int, of pane: Pane) -> Bool {
        let current = pane.tabs[idx]
        let buffer: NoteBuffer
        if let open = openBuffers().first(where: { urlSameFile($0.file.url, file.url) }) {
            buffer = open
        } else {
            guard let text = readForOpening(file) else { return false }
            buffer = NoteBuffer(file: file, text: text)
        }
        let stillShown = panes.contains { p in p.tabs.contains { $0.id != current.id && $0.buffer === current.buffer } }
        if stillShown {
            flushPendingSave()
        } else {
            if externalConflict != nil {
                notice = Notice(title: "Resolve the conflict first",
                                message: "\u{201C}\(current.file.name)\u{201D} changed on disk while it had unsaved edits. Choose \u{201C}Reload from disk\u{201D} or \u{201C}Keep my edits\u{201D} in the note before leaving it.")
                return false
            }
            if missingOnDisk {
                notice = Notice(title: "This note was removed on disk",
                                message: "\u{201C}\(current.file.name)\u{201D} was moved or deleted outside Hanji while it had unsaved edits. Choose \u{201C}Save again\u{201D} or \u{201C}Close without saving\u{201D} in the note before leaving it.")
                return false
            }
            guard flushPendingSave() else { return false }
        }
        objectWillChange.send()
        pane.tabs[idx].buffer = buffer
        hydrate(from: pane.tabs[idx])
        return true
    }

    /// After a rename or move of `old` (a note, or a folder of them), point every
    /// tab's history at the new place.
    private func retargetHistory(from old: URL, to new: URL) {
        let base = old.resolvingSymlinksInPath().path
        func moved(_ entry: NavigationEntry) -> NavigationEntry {
            let path = entry.url.resolvingSymlinksInPath().path
            var e = entry
            if path == base { e.url = new }
            else if path.hasPrefix(base + "/") { e.url = new.appendingPathComponent(String(path.dropFirst(base.count + 1))) }
            return e
        }
        for pane in panes {
            for i in pane.tabs.indices {
                pane.tabs[i].back = pane.tabs[i].back.map(moved)
                pane.tabs[i].forward = pane.tabs[i].forward.map(moved)
            }
        }
    }

    /// Make an already-open tab active.
    public func switchTab(_ id: UUID) {
        guard let pane = activePane, id != pane.activeTabID,
              let tab = pane.tabs.first(where: { $0.id == id }) else { return }
        flushPendingSave()
        objectWillChange.send()
        pane.activeTabID = id
        hydrate(from: tab)
    }

    /// Close a tab (saving it if dirty); a neighbor becomes active, or the
    /// editor clears if it was the last tab.
    public func closeTab(_ id: UUID) {
        guard let pane = activePane, let idx = pane.tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == pane.activeTabID
        // Pinned tabs stay until unpinned (⌘W and the tab's close button do nothing).
        if pane.tabs[idx].isPinned { return }
        // A tab still waiting on the "changed on disk" banner holds two versions the
        // user hasn't chosen between: closing would either drop the edits or write
        // them over the other version. Ask for the choice first.
        if (wasActive ? externalConflict : pane.tabs[idx].externalConflict) != nil {
            notice = Notice(title: "Resolve the conflict first",
                            message: "\u{201C}\(pane.tabs[idx].file.name)\u{201D} changed on disk while it had unsaved edits. Choose \u{201C}Reload from disk\u{201D} or \u{201C}Keep my edits\u{201D} in the note before closing it.")
            return
        }
        if wasActive ? missingOnDisk : pane.tabs[idx].missingOnDisk {
            notice = Notice(title: "This note was removed on disk",
                            message: "\u{201C}\(pane.tabs[idx].file.name)\u{201D} was moved or deleted outside Hanji while it had unsaved edits. Choose \u{201C}Save again\u{201D} or \u{201C}Close without saving\u{201D} in the note.")
            return
        }
        // A tab whose edits couldn't be saved stays open — closing it would throw them away.
        guard wasActive ? flushPendingSave() : flush(pane.tabs[idx].buffer) else { return }
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
            let wasActive = pane.id == activePaneID
            panes.removeAll { $0.id == pane.id }
            // The other pane closing leaves the live buffer — what's being typed — alone.
            guard wasActive else { return }
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
        activePaneID = id
        if let tab = target.tabs.first(where: { $0.id == target.activeTabID }) { hydrate(from: tab) }
        else { clearActive() }
    }

    /// Open the active document in a new right pane (no-op if already split or empty).
    public func splitRight() {
        guard panes.count == 1, let cur = activePane, let id = cur.activeTabID else { return }
        resignEditorFocus()   // the single-pane editor is rebuilt into a fresh HSplitView; resign FR first
        flushPendingSave()
        guard let original = cur.tabs.first(where: { $0.id == id }) else { return }
        let snapshot = OpenTab(sharing: original)   // same note, its own identity (pin, close, move)
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

        // The move ends in `hydrate(from:)`; the working fields already live in
        // their buffer, so nothing is lost. Save first, same order as focusPane.
        flushPendingSave()

        objectWillChange.send()
        let snapshot = src.tabs[tabIdx]
        let movedActive = tabID == src.activeTabID
        src.tabs.remove(at: tabIdx)
        if movedActive { src.activeTabID = src.tabs[safe: tabIdx]?.id ?? src.tabs.last?.id }

        let target: Pane
        if hasNeighbour {
            target = panes[neighbourIndex]
            if let existing = target.tabs.firstIndex(where: { $0.buffer === snapshot.buffer }) {
                // That pane already shows this note — the same buffer, so nothing
                // is lost by going to its tab (which takes over any pin).
                if snapshot.isPinned { target.tabs[existing].isPinned = true }
                target.tabs[existing].isReading = snapshot.isReading
                target.activeTabID = target.tabs[existing].id
                activePaneID = target.id
                hydrate(from: target.tabs[existing])
                persistPins()
                closePaneIfEmpty(src)
                return
            }
            if target.tabs.contains(where: { urlSameFile($0.file.url, snapshot.file.url) }) {
                // Same file, a different buffer (renamed away and back): dedupeTabs
                // keeps the copy holding unsaved work.
                target.tabs.append(snapshot)
                target.activeTabID = snapshot.id
                activePaneID = target.id
                hydrate(from: snapshot)
                dedupeTabs()
                closePaneIfEmpty(src)
                return
            }
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

    /// Save everything before the app quits or the vault closes: the open note
    /// (even mid-debounce), every other open note, and whatever autosave is still
    /// in flight. Returns the notes whose edits are still only in memory — a
    /// failed write or an unresolved conflict — so the caller can stop and say so.
    public func saveAllForClose() -> [String] {
        applyAutosaveFailures()                  // waits for in-flight autosaves too
        var unsaved: [String] = []
        if !flushPendingSave(), let file = selectedFile { unsaved.append(file.name) }
        let live = liveBuffer
        for buffer in openBuffers() where buffer !== live {
            if !flush(buffer) { unsaved.append(buffer.file.name) }
        }
        var seen = Set<String>()
        return unsaved.filter { seen.insert($0).inserted }
    }

    /// "“A.md”" / "“A.md” and “B.md”" / "“A.md”, “B.md” and 3 more".
    static func list(_ names: [String]) -> String {
        let quoted = names.map { "\u{201C}\($0)\u{201D}" }
        switch quoted.count {
        case 0: return ""
        case 1: return quoted[0]
        case 2, 3: return quoted.dropLast().joined(separator: ", ") + " and " + quoted.last!
        default: return quoted.prefix(2).joined(separator: ", ") + " and \(quoted.count - 2) more"
        }
    }

    /// Toolbar/menu "Save" — writes only if there are unsaved changes.
    public func save() { flushPendingSave() }

    /// Synchronous write — used for note switch, quit, and tests where the bytes
    /// must hit disk before the next step. Idempotent when clean. Returns false
    /// when the open note's edits are still only in memory: the write failed (the
    /// user has been told) or a conflict is waiting to be resolved.
    @discardableResult
    public func flushPendingSave() -> Bool {
        guard isDirty, let file = selectedFile, let vault else { return true }
        guard !conflictPaused else { return false }
        switch write(activeText, to: file, with: vault, over: savedText) {
        case .failed: return false
        case .changedOnDisk(let disk):
            externalConflict = disk          // someone else's change we hadn't seen yet
            conflictPaused = true
            return false
        case .written: break
        }
        savedText = activeText
        scheduleReindex()
        return true
    }

    /// Debounced autosave: write OFF the main thread so a save never blocks
    /// typing (iCloud writes can stall on file coordination). The baseline is
    /// marked clean immediately so a follow-up watcher fire sees no conflict;
    /// if the write then fails, the note is marked dirty again.
    private func autosave() {
        guard !conflictPaused, isDirty, let file = selectedFile, let vault else { return }
        let text = activeText
        let previous = savedText
        savedText = text
        autosavesInFlight[file.url, default: []] += [previous, text]
        saveQueue.async { [weak self] in
            // Never write over a change we haven't seen: the file must still hold
            // the version the note last saw (or already hold this text).
            if let current = try? vault.read(file), current != previous, current != text {
                DispatchQueue.main.async {
                    self?.autosaveBlocked(file: file, text: text, previous: previous, disk: current)
                    self?.autosaveLanded(file, previous, text)
                }
                return
            }
            do {
                try vault.write(text, to: file)
                DispatchQueue.main.async { self?.scheduleReindex(); self?.autosaveLanded(file, previous, text) }
            } catch {
                self?.autosaveFailures.append((file, text, previous, error))
                DispatchQueue.main.async { self?.applyAutosaveFailures(); self?.autosaveLanded(file, previous, text) }
            }
        }
    }

    /// An autosave finished (either way): its contents are no longer "ours in flight".
    private func autosaveLanded(_ file: MarkdownFile, _ previous: String, _ text: String) {
        var own = autosavesInFlight[file.url] ?? []
        for t in [previous, text] { if let i = own.firstIndex(of: t) { own.remove(at: i) } }
        autosavesInFlight[file.url] = own.isEmpty ? nil : own
    }

    /// The file changed on disk before the autosave could write: it didn't. Put
    /// the note back to unsaved and raise the conflict banner with that version.
    private func autosaveBlocked(file: MarkdownFile, text: String, previous: String, disk: String) {
        for buffer in openBuffers() where buffer.file.url == file.url {
            if buffer.savedText == text { buffer.savedText = previous }
            buffer.externalConflict = disk
        }
        refreshLive()
    }

    /// Apply every autosave failure recorded so far. Waiting on the serial save
    /// queue also lets any autosave still in flight finish (and record) first.
    private func applyAutosaveFailures() {
        let failures = saveQueue.sync { () -> [(file: MarkdownFile, text: String, previous: String, error: Error)] in
            defer { autosaveFailures = [] }
            return autosaveFailures
        }
        for f in failures { autosaveFailed(file: f.file, text: f.text, previous: f.previous, error: f.error) }
    }

    /// Put the dirty mark back on the note if it still claims `text` was saved
    /// (its buffer — whether it's still the open note or the user moved on).
    private func autosaveFailed(file: MarkdownFile, text: String, previous: String, error: Error) {
        for buffer in openBuffers() where buffer.file.url == file.url && buffer.savedText == text {
            buffer.savedText = previous
        }
        refreshLive()
        reportSaveFailure(file, error)
    }

    private enum WriteResult { case written, failed, changedOnDisk(String) }

    /// Every save goes through the serial save queue, so a synchronous save can't
    /// land before — and be overwritten by — an older autosave still in flight.
    /// With a `baseline` (the version the note last saw), a file that now holds
    /// something else isn't written over: that's a change we haven't seen.
    private func write(_ text: String, to file: MarkdownFile, with vault: Vault,
                       over baseline: String? = nil) -> WriteResult {
        do {
            let changed: String? = try saveQueue.sync {
                if let baseline, let current = try? vault.read(file), current != baseline, current != text {
                    return current
                }
                try vault.write(text, to: file)
                return nil
            }
            return changed.map(WriteResult.changedOnDisk) ?? .written
        } catch {
            reportSaveFailure(file, error)
            return .failed
        }
    }

    /// Before moving or rewriting files: let any in-flight autosave land (so it
    /// can't recreate a path that's about to move) and save the open note.
    private func settleSaves() {
        applyAutosaveFailures()
        flushPendingSave()
    }

    /// Open tabs showing `url` itself or — for a folder — a note inside it, with
    /// each one's path below `url` ("" for the item itself). Captured before a
    /// rename/move/undo so the tabs can follow the file to its new place.
    private func tabsFollowing(_ url: URL) -> [(pane: Pane, tabID: UUID, suffix: String)] {
        let base = url.resolvingSymlinksInPath().path
        var out: [(pane: Pane, tabID: UUID, suffix: String)] = []
        for pane in panes {
            for tab in pane.tabs {
                let path = tab.file.url.resolvingSymlinksInPath().path
                if path == base || urlSameFile(tab.file.url, url) {
                    out.append((pane, tab.id, ""))
                } else if path.hasPrefix(base + "/") {
                    out.append((pane, tab.id, String(path.dropFirst(base.count + 1))))
                }
            }
        }
        return out
    }

    private func retarget(_ followers: [(pane: Pane, tabID: UUID, suffix: String)], to newURL: URL) {
        for f in followers {
            guard let idx = f.pane.tabs.firstIndex(where: { $0.id == f.tabID }) else { continue }
            let file = MarkdownFile(url: f.suffix.isEmpty ? newURL : newURL.appendingPathComponent(f.suffix))
            f.pane.tabs[idx].file = file
            if f.pane.id == activePaneID && f.tabID == f.pane.activeTabID { selectedFile = file }
        }
        persistPins()
        dedupeTabs()
    }

    private func reportSaveFailure(_ file: MarkdownFile, _ error: Error) {
        guard notice == nil else { return }   // one alert at a time, not one per keystroke
        notice = Notice(title: "Couldn\u{2019}t save note",
                        message: "Hanji couldn\u{2019}t save \u{201C}\(file.name)\u{201D}: \(error.localizedDescription) Your edits are still open and will be saved once the note can be written.")
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

    // MARK: - Pinned tabs

    /// Pin or unpin a tab (in any pane).
    public func togglePin(_ tabID: UUID) {
        guard let pane = panes.first(where: { $0.tabs.contains { $0.id == tabID } }),
              let idx = pane.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        objectWillChange.send()
        pane.tabs[idx].isPinned.toggle()
        persistPins()
    }

    // MARK: - Reading mode

    /// Reading mode on or off for a tab (in any pane); remembered for pinned tabs.
    public func toggleReading(_ tabID: UUID) {
        guard let pane = panes.first(where: { $0.tabs.contains { $0.id == tabID } }),
              let idx = pane.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        objectWillChange.send()
        pane.tabs[idx].isReading.toggle()
        persistPins()
    }

    /// Whether the active tab is in reading mode (View ▸ Reading Mode's check).
    public var isActiveTabReading: Bool {
        activeTabIndex.map { activePane!.tabs[$0].isReading } ?? false
    }

    /// The vault's pinned notes, vault-relative, in tab order (left pane first),
    /// and which of them are in reading mode.
    private func persistPins() {
        guard let root = vaultRoot else { return }
        defaults.set(pinnedPaths(root) { _ in true }, forKey: Self.pinsKey(root))
        defaults.set(pinnedPaths(root) { $0.isReading }, forKey: Self.readingKey(root))
    }

    private func pinnedPaths(_ root: URL, where include: (OpenTab) -> Bool) -> [String] {
        let prefix = root.standardizedFileURL.path + "/"
        var seen = Set<String>()
        return panes.flatMap(\.tabs).filter { $0.isPinned && include($0) }.compactMap { tab -> String? in
            let path = tab.file.url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return nil }
            let rel = String(path.dropFirst(prefix.count))
            return seen.insert(rel).inserted ? rel : nil
        }
    }

    /// Reopen the vault's pinned notes as pinned tabs; the first one is shown.
    /// A pinned note that no longer exists is dropped from the list.
    private func restorePins() {
        guard let root = vaultRoot, let pane = activePane,
              let paths = defaults.stringArray(forKey: Self.pinsKey(root)), !paths.isEmpty else { return }
        let reading = Set(defaults.stringArray(forKey: Self.readingKey(root)) ?? [])
        for rel in paths {
            guard let url = urlInsideVault(rel), FileManager.default.fileExists(atPath: url.path) else { continue }
            openNote(relativePath: rel, newTab: true)
            if let idx = pane.tabs.firstIndex(where: { $0.file.url.standardizedFileURL == url.standardizedFileURL }) {
                pane.tabs[idx].isPinned = true
                pane.tabs[idx].isReading = reading.contains(rel)
            }
        }
        if let first = pane.tabs.first, first.id != pane.activeTabID { switchTab(first.id) }
        persistPins()
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
        /// A vault-wide replace, with each rewritten file's text before and after.
        /// One entry covers the whole batch so undo can't leave the vault
        /// half-replaced; the "after" text lets undo skip files changed since.
        case replaced([(url: URL, previous: String, replaced: String)])
    }

    @Published public private(set) var fileOperations: [FileOperation] = []
    /// How many operations ⌥⌘Z can walk back. Replace batches hold whole file
    /// texts, so the history can't be allowed to grow without bound.
    private static let undoLimit = 100

    private func record(_ op: FileOperation) {
        fileOperations.append(op)
        if fileOperations.count > Self.undoLimit { fileOperations.removeFirst(fileOperations.count - Self.undoLimit) }
    }
    public var canUndoFileOperation: Bool { !fileOperations.isEmpty }

    /// Undo the most recent file operation (create/rename/move/trash/duplicate/import).
    public func undoLastFileOperation() {
        guard let v = vault else { return }
        settleSaves()
        guard let op = fileOperations.popLast() else { return }
        let fm = FileManager.default
        switch op {
        case .created(let url), .copied(let url):
            // A created folder that has gained notes since (a sync client, a move)
            // isn't this operation's to throw away.
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir, let contents = try? fm.contentsOfDirectory(atPath: url.path),
               contents.contains(where: { !$0.hasPrefix(".") }) {
                notice = Notice(title: "Not undone",
                                message: "\u{201C}\(url.lastPathComponent)\u{201D} has notes in it now, so Hanji left it in place.")
                break
            }
            _ = try? v.delete(url)                          // to Trash, still recoverable
        case .renamed(let from, let to), .moved(let from, let to):
            let followers = tabsFollowing(to)
            if (try? fm.moveItem(at: to, to: from)) != nil { retarget(followers, to: from) }
        case .trashed(let original, let trashed):
            // Something new took its place meanwhile (a note created over it):
            // that goes to the Trash, so the undo still never destroys anything.
            if fm.fileExists(atPath: original.path) { _ = try? v.delete(original) }
            try? fm.moveItem(at: trashed, to: original)
        case .replaced(let entries):
            // Only files that still hold exactly what the replace wrote. One edited
            // since keeps the newer text, and one moved or deleted since stays
            // gone — an undo must not destroy newer work or resurrect a note.
            // Same atomic write path the replace used.
            var skipped: [String] = []
            for entry in entries {
                let file = MarkdownFile(url: entry.url)
                guard (try? v.read(file)) == entry.replaced else { skipped.append(file.name); continue }
                try? v.write(entry.previous, to: file)
            }
            if !skipped.isEmpty {
                notice = Notice(title: "Some notes weren\u{2019}t reverted",
                                message: "\(Self.list(skipped)) changed after the replace, so Hanji left \(skipped.count == 1 ? "it" : "them") as \(skipped.count == 1 ? "it is" : "they are").")
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
        settleSaves()
        var restore: [(url: URL, previous: String, replaced: String)] = []
        var occurrences = 0
        for file in (try? vault.markdownFiles()) ?? [] {
            guard let text = try? vault.read(file) else { continue }
            let hits = TextReplace.count(of: find, in: text, caseSensitive: caseSensitive)
            guard hits > 0,
                  let updated = TextReplace.apply(find, with: replacement, in: text,
                                                  caseSensitive: caseSensitive),
                  (try? vault.write(updated, to: file)) != nil
            else { continue }
            restore.append((file.url, text, updated))
            occurrences += hits
        }
        // Nothing written: leave the undo stack alone so a later ⌥⌘Z doesn't
        // revert some unrelated earlier operation.
        guard !restore.isEmpty else { return .none }
        record(.replaced(restore))
        reloadTree()
        return VaultReplaceSummary(files: restore.count, occurrences: occurrences)
    }

    /// Create an empty note (auto-named) in `folder` (vault root when nil) and open it.
    @discardableResult
    public func newNote(inFolder folder: URL? = nil, name: String? = nil) -> URL? {
        guard let v = vault, let url = try? v.createNote(inFolder: folder, name: name) else { return nil }
        record(.created(url))
        reloadTree()
        if let f = files.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { open(f, newTab: true) }
        return url
    }

    /// Create a folder (auto-named) in `folder` (vault root when nil).
    @discardableResult
    public func newFolder(inFolder folder: URL? = nil, name: String? = nil) -> URL? {
        guard let v = vault, let url = try? v.createFolder(inFolder: folder, name: name) else { return nil }
        record(.created(url))
        reloadTree()
        return url
    }

    /// Rename a note or folder; if the open note was renamed, keep it open.
    @discardableResult
    public func rename(_ url: URL, to newName: String) throws -> URL {
        guard let v = vault else { throw VaultError.invalidName }
        settleSaves()
        // Resolve which tabs follow `url` BEFORE the rename, while the file still
        // exists and stat(2) can compare inodes reliably — including every open
        // note inside a renamed folder.
        let followers = tabsFollowing(url)
        let newURL = try v.rename(url, to: newName)
        if newURL.standardizedFileURL != url.standardizedFileURL {
            record(.renamed(from: url, to: newURL))
            retarget(followers, to: newURL)
            retargetHistory(from: url, to: newURL)
        }
        reloadTree()
        return newURL
    }

    /// Move a note or folder into another folder; if the moved note is open in a
    /// tab, update that tab in place (no duplicate/stale tab).
    @discardableResult
    public func move(_ url: URL, into folder: URL) throws -> URL {
        guard let v = vault else { throw VaultError.invalidName }
        settleSaves()
        let followers = tabsFollowing(url)   // before the move, while inodes are valid
        let newURL = try v.move(url, into: folder)
        if newURL.standardizedFileURL != url.standardizedFileURL {
            record(.moved(from: url, to: newURL))
            retarget(followers, to: newURL)
            retargetHistory(from: url, to: newURL)
        }
        reloadTree()
        return newURL
    }

    /// Move a note or folder to the Trash, closing its tabs. Their edits are
    /// saved first, so the copy in the Trash is the latest one; if a save fails,
    /// nothing is deleted.
    public func delete(_ url: URL) {
        guard let v = vault else { return }
        settleSaves()
        let followers = tabsFollowing(url)
        for f in followers {
            guard let tab = f.pane.tabs.first(where: { $0.id == f.tabID }) else { continue }
            if !flush(tab.buffer) {
                if notice == nil {
                    notice = Notice(title: "Not moved to the Trash",
                                    message: "\u{201C}\(tab.file.name)\u{201D} has edits that couldn\u{2019}t be saved yet, so Hanji left it where it is.")
                }
                return
            }
        }
        if let trashed = try? v.delete(url) {
            record(.trashed(original: url, trashed: trashed))
            for f in followers { removeTab(f.tabID, in: f.pane) }
            for pane in Array(panes) { closePaneIfEmpty(pane) }
        }
        reloadTree()
    }

    /// Duplicate a note or folder next to the original.
    @discardableResult
    public func duplicate(_ url: URL) -> URL? {
        guard let v = vault, let copy = try? v.duplicate(url) else { return nil }
        record(.copied(copy))
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
                record(.copied(url))
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
        // Creating over an existing note (Templater's save panel can confirm
        // "Replace") sends the old one to the Trash first — ⌥⌘Z brings it back.
        if FileManager.default.fileExists(atPath: url.path) {
            guard let trashed = try? v.delete(url) else { return }
            record(.trashed(original: url, trashed: trashed))
        }
        // Ensure the parent folder exists, then write atomically via Vault (temp+rename).
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? v.write(text, to: MarkdownFile(url: url))
        reloadTree()
        pendingCursorOffset = cursorOffset
    }

    public func openNote(relativePath: String, newTab: Bool = false) {
        guard let root = vaultRoot else { return }
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        if let f = files.first(where: { $0.url.standardizedFileURL == target }) { open(f, newTab: newTab); return }
        if let v = vault { files = (try? v.markdownFiles()) ?? files }
        if let f = files.first(where: { $0.url.standardizedFileURL == target }) { open(f, newTab: newTab) }
    }

    /// Missing-note banner, "Save again": write the note back where it was.
    public func restoreMissingNote() {
        guard missingOnDisk, let file = selectedFile, let vault else { return }
        try? FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard case .written = write(activeText, to: file, with: vault) else { return }
        savedText = activeText
        missingOnDisk = false
        conflictPaused = externalConflict != nil
        reloadTree()
    }

    /// Missing-note banner, "Close without saving": drop the edits and the tab.
    public func closeMissingNote() {
        guard missingOnDisk, let buffer = liveBuffer else { return }
        closeTabs(of: buffer)                     // in every pane: the note is gone
        for pane in Array(panes) { closePaneIfEmpty(pane) }
    }

    // MARK: - Conflict resolution

    /// Conflict banner: discard my unsaved edits and take the on-disk version.
    public func resolveConflictReloadingDisk() {
        guard let recorded = externalConflict else { return }
        let diskText = selectedFile.flatMap { try? vault?.read($0) } ?? recorded   // what's there now
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

/// Settings ▸ Appearance ▸ Theme.
public enum AppearanceTheme: String, CaseIterable {
    case system, light, dark

    /// The appearance to force on the app, or nil to follow the system.
    public var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }
}
