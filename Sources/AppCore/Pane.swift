import Foundation

/// One editor pane: an ordered group of open tabs with an active tab. A plain
/// class — AppState owns the `@Published panes` array and fires objectWillChange
/// when a pane's contents change.
public final class Pane: Identifiable {
    public let id = UUID()
    public var tabs: [OpenTab]
    public var activeTabID: UUID?
    public init(tabs: [OpenTab] = [], activeTabID: UUID? = nil) {
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}
