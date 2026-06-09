import SwiftUI
import MarkdownCore

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let action: () -> Void
}

struct PaletteView: View {
    let placeholder: String
    let items: [PaletteItem]
    let onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var filtered: [PaletteItem] {
        FuzzyFilter.filter(query, items, key: { $0.title })
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
                .onChange(of: query) { _, _ in selection = 0 }
            Divider()
            ScrollViewReader { proxy in
                List(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(idx == selection ? Color.accentColor.opacity(0.2) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { run(item) }
                    .id(idx)
                }
                .onChange(of: selection) { _, new in proxy.scrollTo(new) }
            }
        }
        .frame(width: 560, height: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 24)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, filtered.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.return) { if filtered.indices.contains(selection) { run(filtered[selection]) }; return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func run(_ item: PaletteItem) {
        onClose()
        item.action()
    }
}
