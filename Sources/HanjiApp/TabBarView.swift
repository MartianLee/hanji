import SwiftUI
import AppCore

/// Horizontal strip of open-note tabs above the editor. The active tab's dirty
/// state comes from the live working buffer; other tabs from their snapshot.
struct TabBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if !appState.tabs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(appState.tabs) { tab in
                        tabItem(tab)
                        Divider().frame(height: 16)
                    }
                }
            }
            .frame(height: 32)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }

    private func tabItem(_ tab: OpenTab) -> some View {
        let isActive = tab.id == appState.activeTabID
        let dirty = isActive ? appState.isDirty : tab.isDirty
        return HStack(spacing: 6) {
            Text(tab.file.url.deletingPathExtension().lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
            if dirty {
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
            }
            Button { appState.closeTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { appState.switchTab(tab.id) }
    }
}
