import SwiftUI

enum PaletteMode { case commands, files, moveTo }

enum SidebarMode { case files, search }

@MainActor
final class UIState: ObservableObject {
    @Published var palette: PaletteMode?
    /// Expanded sidebar folders (lives here so menu commands can collapse/expand all).
    @Published var expandedFolders: Set<URL> = []
    /// Ask the sidebar to start an inline rename for a just-created item (set by
    /// context menus and the ⌘N/⇧⌘N menu commands alike).
    @Published var renameRequest: URL?
    @Published var sidebarMode: SidebarMode = .files
    /// Incremented to ask the search panel to grab keyboard focus (⇧⌘F).
    @Published var searchFocusToken = 0
    /// A query for the search panel to run (clicking a `#tag` sets "#tag"); the
    /// panel takes it and clears it.
    @Published var searchRequest: String?

    /// Show the sidebar's search with `query` in it.
    func search(_ query: String) {
        sidebarMode = .search
        searchRequest = query
    }
    /// Whether the search panel shows its replace row (⌥⇧⌘F, or the toggle).
    @Published var replaceVisible = false
    /// Right plugin sidebar (Backlinks/Calendar) visibility; persisted, closed by default.
    @Published var rightSidebarVisible: Bool = UserDefaults.standard.object(forKey: "io.hanji.rightSidebar") as? Bool ?? false {
        didSet { UserDefaults.standard.set(rightSidebarVisible, forKey: "io.hanji.rightSidebar") }
    }
}
