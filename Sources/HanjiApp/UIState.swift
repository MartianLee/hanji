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
}
