import AppKit
import MarkdownCore

/// Applies a DecorationSet to an NSTextStorage. The marker-hiding technique
/// (M1 spike, R1) collapses marker glyphs with a near-zero font + clear color.
public enum LivePreviewStyler {
    public static let baseFont = NSFont.systemFont(ofSize: 14)

    public static func apply(_ deco: DecorationSet, to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.textColor], range: full)
        for run in deco.styles {
            let r = clamp(run.range, length: storage.length)
            guard r.length > 0 else { continue }
            var attrs = attributes(for: run.style)
            // Paragraph styles must cover whole paragraphs to survive attribute
            // fixing, so expand them to the run's paragraph range; other attributes
            // stay on the text range.
            if let pstyle = attrs[.paragraphStyle] {
                attrs[.paragraphStyle] = nil
                let para = (storage.string as NSString).paragraphRange(for: r)
                storage.addAttributes([.paragraphStyle: pstyle], range: para)
            }
            if !attrs.isEmpty { storage.addAttributes(attrs, range: r) }
        }
        for hiddenRange in deco.hidden {
            let r = clamp(hiddenRange, length: storage.length)
            if r.length > 0 {
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01),
                                       .foregroundColor: NSColor.clear], range: r)
            }
        }
        storage.endEditing()
    }

    static func attributes(for style: SpanStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case .heading(let level):
            let sizes: [Int: CGFloat] = [1: 28, 2: 24, 3: 20, 4: 18, 5: 16, 6: 15]
            return [.font: NSFont.boldSystemFont(ofSize: sizes[level] ?? 15)]
        case .bold:
            return [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)]
        case .italic:
            return [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)]
        case .inlineCode:
            return [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .backgroundColor: NSColor.quaternaryLabelColor]
        case .link:
            return [.foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .blockquote:
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = 16
            p.headIndent = 16
            return [.foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]
        case .frontmatter:
            return [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor]
        case .listItem:
            let p = NSMutableParagraphStyle()
            p.headIndent = 20
            return [.paragraphStyle: p]
        case .task(let done):
            let p = NSMutableParagraphStyle()
            p.headIndent = 20
            if done {
                return [.paragraphStyle: p,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.secondaryLabelColor]
            }
            return [.paragraphStyle: p]
        }
    }

    static func clamp(_ r: Range<Int>, length: Int) -> NSRange {
        let lo = max(0, min(r.lowerBound, length))
        let hi = max(lo, min(r.upperBound, length))
        return NSRange(location: lo, length: hi - lo)
    }
}
