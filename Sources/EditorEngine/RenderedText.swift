import AppKit
import MarkdownCore

/// A note's Markdown as reading mode shows it, with the markers taken out
/// rather than collapsed — for embeds and link previews, which show the text
/// in a label, not in the editor. `- ` becomes `•`, a task box `☐` / `☑`;
/// fence lines and frontmatter go. Text only: code, tables, math and images
/// stay styled source.
public enum RenderedText {
    /// Whether `markdown` opens (after any frontmatter) with a top-level heading
    /// saying `title` — a card showing it needn't repeat the title above it.
    public static func opensWithTitle(_ title: String, in markdown: String) -> Bool {
        guard let first = Outline.headings(in: markdown).first, first.level == 1,
              first.title.caseInsensitiveCompare(title) == .orderedSame else { return false }
        let start = Frontmatter.range(in: markdown)?.upperBound ?? 0
        let before = (markdown as NSString).substring(with: NSRange(location: min(start, first.offset),
                                                                    length: max(0, first.offset - start)))
        return before.allSatisfy(\.isWhitespace)
    }

    public static func attributed(_ markdown: String) -> NSAttributedString {
        var text = markdown
        if let front = Frontmatter.range(in: text) {
            let rest = (text as NSString).substring(from: min(front.upperBound, (text as NSString).length))
            text = String(rest.drop { $0 == "\n" || $0 == "\r" })
        }
        let ns = text as NSString
        let storage = NSTextStorage(string: text)
        let spans = InlineTokenizer.spans(in: text)
        let deco = Decorator.decorations(spans: spans, selection: nil)
        LivePreviewStyler.apply(deco, to: storage)

        var edits: [(range: NSRange, text: String)] = deco.hidden.map { (NSRange(location: $0.lowerBound, length: $0.count), "") }
        func firstNonBlank(_ line: Range<Int>) -> Int {
            var i = line.lowerBound
            while i < line.upperBound, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
            return i
        }
        for span in spans {
            switch span.style {
            case .listItem: edits.append((NSRange(location: firstNonBlank(span.line), length: 2), "• "))
            case .task(let done): edits.append((NSRange(location: firstNonBlank(span.line), length: 6), done ? "☑ " : "☐ "))
            default: break
            }
        }
        for region in CodeBlockParser.regions(in: text) {
            edits.append((NSRange(location: region.full.lowerBound, length: region.body.lowerBound - region.full.lowerBound), ""))
            edits.append((NSRange(location: region.body.upperBound, length: region.full.upperBound - region.body.upperBound), ""))
        }
        var applied: [NSRange] = []
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) where edit.range.length > 0 {
            guard NSMaxRange(edit.range) <= storage.length,
                  !applied.contains(where: { NSIntersectionRange($0, edit.range).length > 0 }) else { continue }
            storage.replaceCharacters(in: edit.range, with: edit.text)
            applied.append(edit.range)
        }
        return storage
    }
}
