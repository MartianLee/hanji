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
            if r.length > 0 { storage.addAttributes(attributes(for: run.style), range: r) }
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
        }
    }

    static func clamp(_ r: Range<Int>, length: Int) -> NSRange {
        let lo = max(0, min(r.lowerBound, length))
        let hi = max(lo, min(r.upperBound, length))
        return NSRange(location: lo, length: hi - lo)
    }
}
