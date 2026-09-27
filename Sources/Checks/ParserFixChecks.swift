import Foundation
import MarkdownCore
import TemplateKit
import MKSearchKit

/// CRLF files (Windows-synced vaults) are markdown too.
func crlfChecks() {
    expectEqual(Frontmatter.parse("---\r\ntitle: Hello\r\n---\r\nbody"), ["title": "Hello"], "CRLF frontmatter parses")
    let spans = InlineTokenizer.spans(in: "---\r\ntitle: x\r\n---\r\n# T\r\n```\r\n#no\r\n```\r\n#yes")
    expectEqual(spans.filter { $0.style == .frontmatter }.count, 3, "CRLF frontmatter is styled")
    expect(spans.contains { $0.style == .heading(1) }, "the heading after it is a heading")
    expectEqual(spans.filter { $0.style == .codeBlock }.count, 3, "a CRLF fence opens and closes")
    expectEqual(Tags.extract(from: "```\r\n#no\r\n```\r\n#yes"), ["yes"], "tags skip a CRLF fence")
}

/// Fences as CommonMark has them: ``` or ~~~, up to 3 spaces of indent, closed
/// only by a bare run of the same character at least as long.
func fenceChecks() {
    expectEqual(CodeBlockParser.regions(in: "~~~py\nx\n~~~").map(\.language), ["py"], "~~~ fences")
    expectEqual(CodeBlockParser.regions(in: "  ```\nx\n  ```").count, 1, "indented fences")
    expectEqual(CodeBlockParser.regions(in: "    ```\nx\n    ```").count, 0, "4 spaces is not a fence")
    let early = "```\na\n```js\nb\n```"
    expectEqual(CodeBlockParser.regions(in: early).map(\.full), [0..<17], "```js doesn't close a block")
    expectEqual(CodeBlockParser.regions(in: "````\n```\n````").map(\.full), [0..<13], "a shorter run doesn't close")
    expectEqual(Tags.extract(from: "~~~\n#include <x>\n~~~\n#tag"), ["tag"], "no tags in ~~~ code")
    expect(!InlineTokenizer.spans(in: "~~~\n# not a heading\n~~~").contains { $0.style == .heading(1) },
           "the tokenizer knows ~~~ fences too")
    expectEqual(Tags.extract(from: "---\ncolor: #ffaa00\n---\n#real"), ["real"], "no tags from YAML frontmatter")
}

/// Templates keep text they can't render, and accept Templater's common forms.
func templateFixChecks() {
    let utc = TimeZone(identifier: "UTC")!
    var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
    let ctx = TemplateContext(now: cal.date(from: DateComponents(year: 2026, month: 9, day: 27))!, title: "Note",
                              creationDate: Date(), timeZone: utc)
    func r(_ t: String) -> String { TemplateEngine.render(t, ctx).text }
    expectEqual(r("# <% tp.file.title\n## Tasks"), "# <% tp.file.title\n## Tasks", "an unterminated tag keeps the rest")
    expectEqual(r("<% tp.date.now('YYYY') %>"), "2026", "single-quoted arguments")
    expectEqual(r("<% tp.date.now (\"YYYY\") %>"), "2026", "a space before the parenthesis")
    expectEqual(r("a\n<%- tp.file.title %>"), "aNote", "<%- trims the newline before")
    expectEqual(r("<% tp.file.title -%>\nb"), "Noteb", "-%> trims the newline after")
    expectEqual(r("a  \n  <%_ tp.file.title _%>  \n  b"), "aNoteb", "_ trims all whitespace")
}

/// Dataview sources agree with search: `FROM #tag` includes nested tags, and a
/// folder written with a trailing slash is the same folder.
func dataviewSourceChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-dvsrc-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault.appendingPathComponent("p"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)); try? fm.removeItem(at: vault) }
    for (name, body) in [("a.md", "#proj"), ("b.md", "#proj/sub and #proj/sub/deep"), ("c.md", "#project"), ("p/x.md", "x")] {
        try? body.write(to: vault.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    guard let index = try? SearchIndex(vaultRoot: vault), (try? index.reindexAll(vault: vault)) != nil else {
        expect(false, "index opens"); return
    }
    func list(_ q: String) -> [String] {
        guard let parsed = DataviewQuery.parse(q) else { return ["parse failed"] }
        return ((try? index.dataview(parsed)) ?? []).map(\.path).sorted()
    }
    expectEqual(list("LIST FROM #proj"), ["a.md", "b.md"], "FROM #proj includes #proj/sub, once, and not #project")
    expectEqual(list("LIST FROM \"p/\""), ["p/x.md"], "a folder with a trailing slash")
}
