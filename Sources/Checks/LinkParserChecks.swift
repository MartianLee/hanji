import Foundation
import MarkdownCore

func linkParserChecks() {
    func targets(_ s: String) -> [String] { LinkParser.links(in: s).map(\.target) }

    expectEqual(targets("A [[Plan]] B"), ["Plan"], "plain wikilink")
    expectEqual(targets("[[Plan|별칭]]"), ["Plan"], "alias cut at |")
    expectEqual(targets("[[Plan#섹션]]"), ["Plan"], "heading cut at #")
    expectEqual(targets("[[Projects/Plan]]"), ["Projects/Plan"], "path wikilink kept whole")
    expectEqual(targets("![[image.png]]"), [], "embed skipped")
    expectEqual(targets("[text](Projects/Plan.md)"), ["Projects/Plan.md"], "markdown link to .md")
    expectEqual(targets("[ext](https://example.com/a.md)"), [], "external link skipped")
    expectEqual(targets("![alt](note.md)"), [], "image markdown skipped")
    expectEqual(targets("[pic](photo.png)"), [], "non-md markdown link skipped")
    expectEqual(targets("```\n[[NotALink]]\n```\n[[Real]]"), ["Real"], "fenced code skipped")
    expectEqual(targets("[[A]] and [[B]]"), ["A", "B"], "multiple links in order")

    // Ranges are UTF-16 and cover the whole link token.
    let refs = LinkParser.links(in: "한글 [[Plan]] 끝")
    let ns = "한글 [[Plan]] 끝" as NSString
    expectEqual(refs.count, 1, "one link")
    if let r = refs.first {
        expectEqual(ns.substring(with: NSRange(location: r.range.lowerBound,
                                               length: r.range.upperBound - r.range.lowerBound)),
                    "[[Plan]]", "range covers the token")
    }
}
