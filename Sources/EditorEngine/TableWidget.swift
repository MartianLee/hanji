import SwiftUI
import AppKit
import MarkdownCore

/// A pipe table drawn as a grid, in the editor's fonts: bold header on a faint
/// band, a rule between rows, cells aligned as the delimiter row says. Columns
/// are as wide as their widest cell; a table wider than the text column wraps
/// its widest columns (`TableParser.columnWidths`).
struct TableWidgetView: View {
    let table: MarkdownTable
    /// The text column's width (the overlay's): the grid sits at its leading edge.
    let width: CGFloat
    static let cellPadding = EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)

    var body: some View {
        let widths = columnWidths()
        VStack(alignment: .leading, spacing: 0) {
            row(table.header, widths: widths, bold: true)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
            ForEach(table.rows.indices, id: \.self) { r in
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                row(table.rows[r], widths: widths, bold: false)
            }
        }
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .padding(.vertical, 6)
        .frame(width: width, alignment: .leading)
        // Opaque, so the reserved (hidden) source never shows through.
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func row(_ cells: [String], widths: [CGFloat], bold: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(cells.indices, id: \.self) { c in
                Text(Self.attributed(cells[c], bold: bold))
                    .multilineTextAlignment(textAlignment(table.alignments[c]))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Self.cellPadding)
                    .frame(width: widths[c], alignment: frameAlignment(table.alignments[c]))
            }
        }
    }

    /// Each column's widest cell (unwrapped, padding included), fitted to the column.
    private func columnWidths() -> [CGFloat] {
        let padding = Self.cellPadding.leading + Self.cellPadding.trailing
        let ideal = table.alignments.indices.map { c -> Double in
            let cells = [(table.header[c], true)] + table.rows.map { ($0[c], false) }
            let widest = cells.map { Self.measured($0.0, bold: $0.1) }.max() ?? 0
            return Double(ceil(widest) + padding)
        }
        return TableParser.columnWidths(ideal: ideal, available: Double(width - 2)).map { CGFloat($0) }
    }

    /// The cell's one-line width in the fonts `attributed` draws it with.
    static func measured(_ markdown: String, bold: Bool) -> CGFloat {
        TableParser.runs(markdown).reduce(0) { sum, run in
            sum + (run.text as NSString).size(withAttributes: [.font: font(for: run.style, bold: bold)]).width
        }
    }

    private static func font(for style: CellRun.Style, bold: Bool) -> NSFont {
        let base = LivePreviewStyler.baseFont
        if style.contains(.code) { return LivePreviewStyler.codeFont(ofSize: max(4, base.pointSize - 1)) }
        var font = bold || style.contains(.bold) ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
        if style.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    /// A cell's markdown as styled text, markers dropped (see `TableParser.runs`).
    static func attributed(_ markdown: String, bold: Bool) -> AttributedString {
        var out = AttributedString()
        for run in TableParser.runs(markdown) {
            var piece = AttributedString(run.text)
            piece.font = Font(font(for: run.style, bold: bold) as CTFont)
            piece.foregroundColor = Color(nsColor: .textColor)
            if run.style.contains(.code) { piece.backgroundColor = Color(nsColor: .quaternaryLabelColor) }
            if run.style.contains(.link) {
                piece.foregroundColor = Color(nsColor: .linkColor)
                piece.underlineStyle = .single
            }
            if run.style.contains(.tag) {
                piece.foregroundColor = Color(nsColor: .controlAccentColor)
                piece.backgroundColor = Color(nsColor: NSColor.controlAccentColor.withAlphaComponent(0.14))
            }
            out += piece
        }
        return out
    }

    private func frameAlignment(_ a: MarkdownTable.Alignment) -> Alignment {
        switch a {
        case .center: return .top
        case .right: return .topTrailing
        case .left, .none: return .topLeading
        }
    }

    private func textAlignment(_ a: MarkdownTable.Alignment) -> TextAlignment {
        switch a {
        case .center: return .center
        case .right: return .trailing
        case .left, .none: return .leading
        }
    }
}
