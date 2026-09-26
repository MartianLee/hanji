import SwiftUI
import MarkdownCore

/// Ranks vault paths for a picker as the user types.
public enum PathCompletion {
    /// A match on the file or folder *name* beats one that only matches through
    /// its parent folders ("daily" → `Templates/Daily` before
    /// `Journal/Daily/2026-06-09`); ties go to the shorter path. An empty query
    /// lists the first few; a query that already is one of the paths needs no list.
    public static func suggestions(for query: String, in candidates: [String], limit: Int = 8) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(candidates.prefix(limit)) }
        if candidates.contains(q) { return [] }
        let ranked: [(String, Int)] = candidates.compactMap { path in
            let name = (path as NSString).lastPathComponent
            if let s = FuzzyFilter.score(q, name) { return (path, s) }
            return FuzzyFilter.score(q, path).map { (path, 1000 + $0) }
        }
        return ranked
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.count < $1.0.count }
            .prefix(limit)
            .map(\.0)
    }
}

/// A text field that suggests vault paths as you type: ↑/↓ to move, Return or
/// Tab to take one, a click to pick one, Esc to close the list (a second Esc
/// then reaches the window, e.g. to close Settings).
struct CompletionField: View {
    let placeholder: String
    @Binding var text: String
    let candidates: () -> [String]

    @State private var all: [String] = []
    @State private var open = false
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var suggestions: [String] { PathCompletion.suggestions(for: text, in: all) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(placeholder, text: $text)
                .focused($focused)
                .onChange(of: text) { _, _ in highlighted = 0; if focused { open = true } }
                .onChange(of: focused) { _, isFocused in
                    if isFocused { all = candidates() } else { open = false }
                }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.return) { accept() }
                .onKeyPress(.tab) { accept() }
                .onKeyPress(.escape) {
                    guard open, !suggestions.isEmpty else { return .ignored }
                    open = false
                    return .handled
                }
            if open, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { i, path in
                        Text(path)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(i == highlighted ? Color.accentColor.opacity(0.25) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { text = path; open = false }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            }
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard open, !suggestions.isEmpty else { return .ignored }
        highlighted = (highlighted + delta + suggestions.count) % suggestions.count
        return .handled
    }

    private func accept() -> KeyPress.Result {
        guard open, suggestions.indices.contains(highlighted) else { return .ignored }
        text = suggestions[highlighted]
        open = false
        return .handled
    }
}
