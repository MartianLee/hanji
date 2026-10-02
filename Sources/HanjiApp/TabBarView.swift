import SwiftUI
import AppCore

/// Horizontal strip of one pane's open-note tabs. Tabs can be dragged to
/// reorder within the pane (insert-style); a trailing zone drops to the end.
struct TabBarView: View {
    @EnvironmentObject var appState: AppState
    let pane: Pane
    @State private var dropTarget: UUID?
    @State private var endTargeted = false

    var body: some View {
        if !pane.tabs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(pane.tabs) { tab in
                        tabItem(tab)
                        if tab.id != pane.tabs.last?.id { Divider().frame(height: 16) }
                    }
                    // Trailing drop zone → move to the end.
                    Color.clear
                        .frame(width: 40, height: 32)
                        .overlay(alignment: .leading) {
                            if endTargeted { Rectangle().fill(Color.accentColor).frame(width: 2) }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            endTargeted = false
                            guard let s = items.first, let dropped = UUID(uuidString: s) else { return false }
                            appState.moveTab(dropped, before: nil, in: pane)
                            return true
                        } isTargeted: { endTargeted = $0 }
                }
            }
            .frame(height: 32)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }

    private func tabItem(_ tab: OpenTab) -> some View {
        let isActive = pane.id == appState.activePaneID && tab.id == pane.activeTabID
        let dirty = isActive ? appState.isDirty : tab.isDirty
        return HStack(spacing: 6) {
            if tab.isReading {
                Image(systemName: "book").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Reading mode (⌘E)")
            }
            Text(tab.file.url.deletingPathExtension().lastPathComponent)
                .font(.callout).lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
            if dirty { Circle().fill(Color.secondary).frame(width: 6, height: 6) }
            if tab.isPinned {
                // Pinned: no close button — unpin first (click the pin, or the menu).
                Button { appState.togglePin(tab.id) } label: {
                    Image(systemName: "pin.fill").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Unpin")
            } else {
                Button { appState.focusPane(pane.id); appState.closeTab(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .overlay(alignment: .leading) {
            if dropTarget == tab.id {
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { appState.focusPane(pane.id); appState.switchTab(tab.id) }
        .contextMenu {
            Button(tab.isPinned ? "Unpin" : "Pin") { appState.togglePin(tab.id) }
            Divider()
            Button("Move to Left Pane") { appState.moveTabToSide(tab.id, .left) }
                .disabled(!appState.canMoveTab(tab.id, .left))
            Button("Move to Right Pane") { appState.moveTabToSide(tab.id, .right) }
                .disabled(!appState.canMoveTab(tab.id, .right))
        }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let dropped = UUID(uuidString: s) else { return false }
            appState.moveTab(dropped, before: tab.id, in: pane)
            return true
        } isTargeted: { hovering in
            if hovering { dropTarget = tab.id }
            else if dropTarget == tab.id { dropTarget = nil }
        }
    }
}
