import SwiftUI
import Combine
import ExtensionSDK
import MarkdownCore

/// First-party outline panel: the open note's headings; a click jumps to one,
/// and the heading of the section being read is highlighted.
public struct OutlinePlugin: Plugin {
    public static let id = "io.hanji.outline"
    public init() {}

    public func activate(host: PluginHost) {
        // Weak: the sidebar registry lives in PluginManager, which the host
        // retains — a strong capture here would be a retain cycle.
        host.ui.addSidebarView(id: "outline", title: "Outline") { [weak host] in
            guard let host else { return AnyView(EmptyView()) }
            // At most every 0.15s while typing; the first change after a pause
            // (a note switch included) shows at once.
            let notes = host.editor.activeNotePath.combineLatest(host.editor.activeText)
                .throttle(for: .seconds(0.15), scheduler: DispatchQueue.main, latest: true)
                .map { path, text in path == nil ? nil : Outline.headings(in: text) }
                .eraseToAnyPublisher()
            return AnyView(OutlineView(headings: notes, focus: host.editor.focusOffset,
                                       workspace: host.workspace))
        }
    }
}

struct OutlineView: View {
    /// nil: no note open.
    let headings: AnyPublisher<[OutlineHeading]?, Never>
    let focus: AnyPublisher<Int, Never>
    let workspace: WorkspaceActions

    @State private var items: [OutlineHeading]?
    @State private var focusOffset = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let items {
                if items.isEmpty {
                    Text("No headings").font(.caption).foregroundStyle(.secondary)
                } else {
                    let top = items.map(\.level).min() ?? 1
                    let current = Outline.current(in: items, at: focusOffset)
                    ForEach(Array(items.enumerated()), id: \.element.offset) { index, heading in
                        Button { workspace.reveal(offset: heading.offset) } label: {
                            Text(heading.title.isEmpty ? "Untitled" : heading.title)
                                .lineLimit(1)
                                .fontWeight(heading.level == top ? .medium : .regular)
                                .padding(.leading, CGFloat(heading.level - top) * 12)
                                .padding(.vertical, 2).padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(index == current ? Color.accentColor.opacity(0.18) : .clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Open a note to see its outline").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(headings) { items = $0 }
        .onReceive(focus) { focusOffset = $0 }
    }
}
