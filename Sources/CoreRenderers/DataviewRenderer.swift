import SwiftUI
import ExtensionSDK
import VaultKit
import MarkdownCore

/// Dataview-lite renderer: supports `LIST FROM #tag`, rendering the titles of
/// notes carrying that tag (read from the current metadata index).
public struct DataviewRenderer: CodeBlockRenderer {
    public let language = "dataview"
    private let indexProvider: () -> MetadataIndex

    public init(indexProvider: @escaping () -> MetadataIndex) {
        self.indexProvider = indexProvider
    }

    public func makeView(source: String) -> AnyView {
        guard let tag = DataviewQuery.tagForListQuery(source) else {
            return AnyView(
                Text("Unsupported query — Dataview-lite supports: LIST FROM #tag")
                    .font(.callout).foregroundColor(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            )
        }
        let results = indexProvider().notes(withTag: tag)
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Text("LIST FROM #\(tag)").font(.caption).foregroundColor(.secondary)
                if results.isEmpty {
                    Text("(no results)").foregroundColor(.secondary)
                } else {
                    ForEach(results, id: \.path) { note in
                        Text("• \(note.title)")
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        )
    }
}
