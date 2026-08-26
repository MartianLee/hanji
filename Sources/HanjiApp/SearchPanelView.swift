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

    // Vault-wide replace. The match count is only computed when the user asks to
    // replace — scanning every note on each keystroke would stall the panel, and
    // the confirmation sheet is the preview.
    @State private var replaceText = ""
    @State private var caseSensitive = true
    @State private var preview: [AppState.ReplacePreviewRow] = []
    @State private var confirming = false
    @State private var lastResult: String?

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
                Button {
                    uiState.replaceVisible.toggle()
                } label: {
                    Image(systemName: "arrow.2.squarepath")
                }
                .buttonStyle(.plain)
                .foregroundStyle(uiState.replaceVisible ? Color.accentColor : .secondary)
                .help("Replace in vault (⌥⇧⌘F)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            if uiState.replaceVisible {
                Divider()
                // Two rows, not one: the sidebar is ~280pt and a field plus two
                // controls on a single line truncates every label.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.2.squarepath")
                            .foregroundStyle(.secondary).imageScale(.small)
                        TextField("Replace with", text: $replaceText)
                            .textFieldStyle(.plain)
                            .font(.callout)
                    }
                    HStack(spacing: 6) {
                        Toggle("Aa", isOn: $caseSensitive)
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .help("Match case")
                        Spacer(minLength: 0)
                        Button("Replace All") { startReplace() }
                            .controlSize(.small)
                            .disabled(query.isEmpty)
                    }
                    if let lastResult {
                        Text(lastResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            }
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
        .alert("Replace in vault?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { }
            Button("Replace All", role: .destructive) { applyReplace() }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        let occurrences = preview.reduce(0) { $0 + $1.count }
        guard occurrences > 0 else { return "No notes contain “\(query)”." }
        let notes = preview.count == 1 ? "1 note" : "\(preview.count) notes"
        return "Replace \(occurrences) occurrence\(occurrences == 1 ? "" : "s") of “\(query)” "
             + "with “\(replaceText)” across \(notes).\n\nThis rewrites files on disk. "
             + "Undo with ⌥⌘Z."
    }

    /// Count first, then ask. The count is the preview, so the user never fires a
    /// vault-wide rewrite without seeing its size.
    private func startReplace() {
        guard !query.isEmpty else { return }
        preview = appState.previewReplaceInVault(find: query, caseSensitive: caseSensitive)
        lastResult = nil
        confirming = true
    }

    private func applyReplace() {
        let summary = appState.replaceInVault(find: query, with: replaceText,
                                              caseSensitive: caseSensitive)
        lastResult = summary.occurrences == 0
            ? "Nothing replaced."
            : "Replaced \(summary.occurrences) in \(summary.files) note\(summary.files == 1 ? "" : "s")."
        runSearch()
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
