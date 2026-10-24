import SwiftUI
import AppKit
import MarkdownCore

/// A note shown inside another: its title and its text, rendered (see
/// `RenderedText`), behind an accent bar — an embed's widget and a link
/// preview's popover. `markdown == nil`: the note doesn't exist.
struct NoteCardView: View {
    let title: String
    let markdown: String?
    /// Show only this heading's section, when the note has it.
    var heading: String? = nil
    let width: CGFloat
    let maxHeight: CGFloat

    private static let padding: CGFloat = 12

    var body: some View {
        let text = rendered
        let textWidth = max(40, width - Self.padding * 2 - 3)
        let tall = text.map { measuredHeight($0, width: textWidth) + 40 > maxHeight } ?? false
        HStack(spacing: 0) {
            Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                if showsTitle {
                    Text(title).font(.headline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let text {
                    RenderedLabel(text: text, width: textWidth)
                } else {
                    Text("\u{201C}\(title)\u{201D} isn\u{2019}t a note in this vault")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(Self.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight, alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) {
            if tall {
                // Cut off, not squeezed: fade the last lines out.
                LinearGradient(colors: [Color(nsColor: .textBackgroundColor).opacity(0), Color(nsColor: .textBackgroundColor)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 40)
            }
        }
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(width: width, alignment: .leading)
    }

    private var source: String? {
        guard let markdown else { return nil }
        return heading.flatMap { NoteEmbeds.section($0, in: markdown) } ?? markdown
    }

    private var rendered: NSAttributedString? { source.map(RenderedText.attributed) }

    /// Not when the text opens with the same title as its heading.
    private var showsTitle: Bool { !(source.map { RenderedText.opensWithTitle(title, in: $0) } ?? false) }

    private func measuredHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
    }
}

/// Attributed text in a wrapping label: unlike SwiftUI's `Text`, it keeps the
/// editor's paragraph styles (indents, spacing).
private struct RenderedLabel: NSViewRepresentable {
    let text: NSAttributedString
    let width: CGFloat

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: text)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        label.attributedStringValue = text
        label.preferredMaxLayoutWidth = width
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView label: NSTextField, context: Context) -> CGSize? {
        label.preferredMaxLayoutWidth = width
        let h = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return CGSize(width: width, height: ceil(h) + 2)
    }
}
