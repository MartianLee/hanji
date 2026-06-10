import SwiftUI
import Combine
import ExtensionSDK

/// First-party backlinks panel: lists notes linking to the active note, with
/// context snippets; updates when the note changes or the index refreshes.
public struct BacklinksPlugin: Plugin {
    public static let id = "io.hanji.backlinks"
    public init() {}

    public func activate(host: PluginHost) {
        // Weak: the sidebar registry lives in PluginManager, which the host
        // retains — a strong capture here would be a retain cycle.
        host.ui.addSidebarView(id: "backlinks", title: "Backlinks") { [weak host] in
            guard let host else { return AnyView(EmptyView()) }
            return AnyView(BacklinksView(query: host.query,
                                         workspace: host.workspace,
                                         activePath: host.editor.activeNotePath,
                                         indexUpdates: host.query.indexDidUpdate))
        }
    }
}

struct BacklinksView: View {
    let query: MetadataQuerying
    let workspace: WorkspaceActions
    let activePath: AnyPublisher<String?, Never>
    let indexUpdates: AnyPublisher<Void, Never>

    @State private var currentPath: String?
    @State private var backlinks: [SDKBacklink] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if currentPath == nil {
                Text("Open a note to see its backlinks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if backlinks.isEmpty {
                Text("No backlinks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(backlinks) { link in
                    Button {
                        workspace.openNote(relativePath: link.sourcePath)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.sourceTitle).fontWeight(.medium).lineLimit(1)
                            Text(highlighted(link))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(activePath) { path in
            currentPath = path
            refresh()
        }
        .onReceive(indexUpdates) { refresh() }
    }

    private func refresh() {
        guard let path = currentPath else { backlinks = []; return }
        backlinks = query.backlinks(toNoteAt: path)
    }

    /// Slice the snippet by UTF-16 ranges, bolding each match.
    private func highlighted(_ link: SDKBacklink) -> AttributedString {
        let ns = link.snippet as NSString
        var out = AttributedString()
        var cursor = 0
        for range in link.matchRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
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
