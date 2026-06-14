import AppKit
import MarkdownCore

/// Applies a DecorationSet to an NSTextStorage. The marker-hiding technique
/// (M1 spike, R1) collapses marker glyphs with a near-zero font + clear color.
public enum LivePreviewStyler {
    /// User-adjustable editor font size (Settings ▸ Appearance ▸ Font size,
    /// Obsidian-style). Every text role scales from this.
    public static var baseFontSize: CGFloat = 15
    public static var baseFont: NSFont { .systemFont(ofSize: baseFontSize) }

    /// Reading rhythm shared by all paragraph styles (body, lists, quotes, …):
    /// a roomier line height plus a visible gap between paragraphs, instead of
    /// AppKit's tight single-spaced default.
    static func bodyParagraph() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.3
        p.paragraphSpacing = 6
        return p
    }

    public static func apply(_ deco: DecorationSet, to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.textColor,
                               .paragraphStyle: bodyParagraph()], range: full)
        // Phase 1: absolute styles (fonts/colors/paragraphs). Trait styles wait
        // so they can compose with whatever font phase 1 set (bold inside a
        // heading keeps the heading size).
        for run in deco.styles where !isTraitStyle(run.style) {
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
        // Phase 2: trait styles (bold/italic/inline code) derived from the
        // current font at each position.
        for run in deco.styles where isTraitStyle(run.style) {
            let r = clamp(run.range, length: storage.length)
            guard r.length > 0 else { continue }
            applyTrait(run.style, in: r, to: storage)
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

    static func isTraitStyle(_ style: SpanStyle) -> Bool {
        switch style {
        case .bold, .italic, .inlineCode: return true
        default: return false
        }
    }

    /// Compose a trait style with the font already present (heading-size bold,
    /// heading-size inline code, …).
    static func applyTrait(_ style: SpanStyle, in range: NSRange, to storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            let current = (value as? NSFont) ?? baseFont
            switch style {
            case .bold:
                storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask), range: sub)
            case .italic:
                storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask), range: sub)
            case .inlineCode:
                let size = max(4, current.pointSize - 1)
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
                                       .backgroundColor: NSColor.quaternaryLabelColor], range: sub)
            default:
                break
            }
        }
    }

    static func attributes(for style: SpanStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case .heading(let level):
            // Heading sizes as multiples of the base, so the user's font-size
            // setting scales the whole hierarchy.
            let ratios: [Int: CGFloat] = [1: 1.85, 2: 1.6, 3: 1.35, 4: 1.2, 5: 1.05, 6: 1.0]
            let size = (baseFontSize * (ratios[level] ?? 1.0)).rounded()
            // Headings get breathing room above (more for higher levels).
            let p = bodyParagraph()
            p.paragraphSpacingBefore = [1: 16, 2: 12, 3: 10][level] ?? 8
            return [.font: NSFont.boldSystemFont(ofSize: size),
                    .paragraphStyle: p]
        case .bold:
            return [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)]
        case .italic:
            return [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)]
        case .inlineCode:
            return [.font: NSFont.monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular),
                    .backgroundColor: NSColor.quaternaryLabelColor]
        case .link:
            return [.foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .blockquote:
            let p = bodyParagraph()
            p.firstLineHeadIndent = 16
            p.headIndent = 16
            return [.foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]
        case .frontmatter:
            return [.font: NSFont.monospacedSystemFont(ofSize: baseFontSize - 3, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor]
        case .listItem:
            let p = bodyParagraph()
            p.headIndent = 20
            p.paragraphSpacing = 2     // list items sit closer than paragraphs
            return [.paragraphStyle: p]
        case .task(let done):
            let p = bodyParagraph()
            p.headIndent = 20
            p.paragraphSpacing = 2
            if done {
                return [.paragraphStyle: p,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.secondaryLabelColor]
            }
            return [.paragraphStyle: p]
        case .codeBlock:
            let p = bodyParagraph()
            p.lineHeightMultiple = 1.2   // code reads better a touch tighter
            p.paragraphSpacing = 0
            // No head indent: code aligns with body text (an indent here read as
            // an unwanted leading space). Background comes from CodeBlockFragment
            // (full-width slab), not per-glyph backgroundColor.
            return [.font: NSFont.monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular),
                    .paragraphStyle: p]
        case .callout:
            let p = bodyParagraph()
            p.firstLineHeadIndent = 16
            p.headIndent = 16
            return [.backgroundColor: NSColor.systemBlue.withAlphaComponent(0.12),
                    .paragraphStyle: p]
        }
    }

    static func clamp(_ r: Range<Int>, length: Int) -> NSRange {
        let lo = max(0, min(r.lowerBound, length))
        let hi = max(lo, min(r.upperBound, length))
        return NSRange(location: lo, length: hi - lo)
    }

    /// Syntax-highlight palette (system colors adapt to light/dark).
    static func codeColor(_ kind: CodeHighlighter.TokenKind) -> NSColor {
        switch kind {
        case .keyword: return .systemPink
        case .type:    return .systemTeal
        case .string:  return .systemGreen
        case .number:  return .systemOrange
        case .comment: return .secondaryLabelColor
        }
    }

    /// Add foreground colors to syntax tokens inside each code block's body.
    /// Runs after `apply` (which resets colors), leaving the mono font + slab
    /// background untouched. `regions` come from `CodeBlockParser.regions`.
    public static func highlightCode(_ regions: [CodeBlockRegion], in storage: NSTextStorage) {
        let ns = storage.string as NSString
        storage.beginEditing()
        for region in regions where region.body.upperBound > region.body.lowerBound {
            let loc = region.body.lowerBound
            let len = region.body.upperBound - region.body.lowerBound
            guard loc >= 0, loc + len <= ns.length else { continue }
            let body = ns.substring(with: NSRange(location: loc, length: len))
            for token in CodeHighlighter.tokens(in: body, language: region.language) {
                let r = NSRange(location: loc + token.range.lowerBound,
                                length: token.range.upperBound - token.range.lowerBound)
                guard r.location >= 0, r.location + r.length <= ns.length else { continue }
                storage.addAttribute(.foregroundColor, value: codeColor(token.kind), range: r)
            }
        }
        storage.endEditing()
    }
}
