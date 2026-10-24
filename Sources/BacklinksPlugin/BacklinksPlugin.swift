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
    @State private var mentions: [SDKMention] = []
    @State private var showMentions = false

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
                        row(title: link.sourceTitle, snippet: link.snippet, ranges: link.matchRanges)
                    }
                    .buttonStyle(.plain)
                }
            }
            if currentPath != nil && !mentions.isEmpty {
                // Collapsed by default: a common name can be mentioned everywhere.
                DisclosureGroup("Unlinked mentions (\(mentions.count))", isExpanded: $showMentions) {
                    ForEach(mentions) { mention in
                        HStack(alignment: .top, spacing: 6) {
                            Button {
                                workspace.openNote(relativePath: mention.sourcePath)
                            } label: {
                                row(title: mention.sourceTitle, snippet: mention.snippet, ranges: mention.matchRanges)
                            }
                            .buttonStyle(.plain)
                            Button("Link") { link(mention) }
                                .controlSize(.small)
                                .help("Turn this mention into a link")
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(activePath) { path in
            currentPath = path
            refresh()
        }
        .onReceive(indexUpdates) { refresh() }
    }

    private func row(title: String, snippet: String, ranges: [Range<Int>]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium).lineLimit(1)
            Text(highlighted(snippet, ranges))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func link(_ mention: SDKMention) {
        guard let target = currentPath else { return }
        _ = workspace.linkMention(sourcePath: mention.sourcePath, range: mention.range, targetPath: target)
        refresh()
    }

    private func refresh() {
        guard let path = currentPath else { backlinks = []; mentions = []; return }
        backlinks = query.backlinks(toNoteAt: path)
        mentions = query.unlinkedMentions(ofNoteAt: path)
    }

    /// Slice the snippet by UTF-16 ranges, bolding each match.
    private func highlighted(_ snippet: String, _ matchRanges: [Range<Int>]) -> AttributedString {
        let ns = snippet as NSString
        var out = AttributedString()
        var cursor = 0
        for range in matchRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
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
