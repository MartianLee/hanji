import SwiftUI
import AppCore
import MKSearchKit

/// Obsidian-style sidebar search: debounced query over the vault FTS index,
/// snippets with highlighted matches, ⏎/click jumps to the match.
struct SearchPanelView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var uiState: UIState

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
                TextField("Search in vault", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($focused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()

            if query.isEmpty {
                Spacer()
                Text("Type to search the vault").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else if hits.isEmpty {
                Spacer()
                Text("No results").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(hits) { hit in
                    Button { open(hit) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title).fontWeight(.medium).lineLimit(1)
                            Text(highlighted(hit))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
        .onAppear {
            focused = true
            // Test/E2E hook: pre-fill a query for screenshot runs.
            if query.isEmpty, let q = ProcessInfo.processInfo.environment["HANJI_SEARCH"] {
                query = q
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200))   // debounce
            guard !Task.isCancelled else { return }
            runSearch()
        }
        .onChange(of: appState.searchIndexUpdatedAt) { _, _ in runSearch() }
        .onChange(of: uiState.searchFocusToken) { _, _ in focused = true }
    }

    private func runSearch() {
        guard !query.isEmpty, let index = appState.searchIndex else { hits = []; return }
        hits = (try? index.search(query)) ?? []
    }

    private func open(_ hit: SearchHit) {
        appState.openNote(relativePath: hit.path)
        appState.pendingCursorOffset = hit.firstMatchOffset
    }

    /// Rebuild the snippet as an AttributedString, bolding each match range
    /// (UTF-16 slicing — ranges may repeat, so slice rather than search).
    private func highlighted(_ hit: SearchHit) -> AttributedString {
        let ns = hit.snippet as NSString
        var out = AttributedString()
        var cursor = 0
        for range in hit.matchRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound >= cursor, range.upperBound <= ns.length else { continue }
            out += AttributedString(ns.substring(with: NSRange(location: cursor, length: range.lowerBound - cursor)))
            var match = AttributedString(ns.substring(with: NSRange(location: range.lowerBound,
                                                                    length: range.upperBound - range.lowerBound)))
            match.font = .caption.bold()
            match.foregroundColor = .accentColor
            out += match
            cursor = range.upperBound
        }
        out += AttributedString(ns.substring(from: cursor))
        return out
    }
}
