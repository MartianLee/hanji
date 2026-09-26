import SwiftUI
import ExtensionSDK
import MarkdownCore

/// Renders a ```dataview block: LIST as bullets, TABLE as a grid. Queries run
/// through a closure so this stays decoupled from the index implementation.
public struct DataviewRenderer: CodeBlockRenderer {
    public let language = "dataview"
    let runQuery: (DataviewQuery.Parsed) -> [DataviewQuery.ResultRow]

    public init(query: @escaping (DataviewQuery.Parsed) -> [DataviewQuery.ResultRow]) {
        self.runQuery = query
    }

    public func makeView(source: String) -> AnyView {
        guard let parsed = DataviewQuery.parse(source) else {
            return AnyView(DataviewErrorView(source: source))
        }
        let rows = runQuery(parsed)
        switch parsed.kind {
        case .list:
            return AnyView(DataviewListView(rows: rows))
        case .table:
            return AnyView(DataviewTableView(columns: parsed.columns, rows: rows))
        }
    }
}

struct DataviewListView: View {
    let rows: [DataviewQuery.ResultRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if rows.isEmpty {
                Text("No results").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    Text("•  \(row.title)").font(.callout)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct DataviewTableView: View {
    let columns: [String]
    let rows: [DataviewQuery.ResultRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("No results").font(.callout).foregroundStyle(.secondary).padding(10)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("File").font(.caption.bold())
                        ForEach(columns, id: \.self) { Text($0).font(.caption.bold()) }
                    }
                    Divider()
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.title).font(.callout).lineLimit(1)
                            ForEach(Array(row.values.enumerated()), id: \.offset) { _, v in
                                Text(v ?? "—").font(.callout).monospacedDigit().lineLimit(1)
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct DataviewErrorView: View {
    let source: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("쿼리: 구문을 이해하지 못했어요").font(.caption).foregroundStyle(.red)
            Text(source.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
