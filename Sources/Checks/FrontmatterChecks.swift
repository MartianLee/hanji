import Foundation
import MarkdownCore

func frontmatterChecks() {
    let doc = """
    ---
    status: active
    priority: 3
    title: "Quoted Title"
    nick: '단따옴표'
    done: true
    tags:
      - a
      - b
    empty:
    ---
    # Body
    key: not frontmatter
    """
    let fm = Frontmatter.parse(doc)
    expectEqual(fm["status"], "active", "unquoted string")
    expectEqual(fm["priority"], "3", "number kept as text")
    expectEqual(fm["title"], "Quoted Title", "double quotes stripped")
    expectEqual(fm["nick"], "단따옴표", "single quotes stripped")
    expectEqual(fm["done"], "true", "boolean kept as text")
    expect(fm["tags"] == nil, "list values skipped")
    expect(fm["- a"] == nil && fm["a"] == nil, "list items not keys")
    expect(fm["empty"] == nil, "empty value skipped")
    expect(fm["key"] == nil, "body lines not parsed")

    expectEqual(Frontmatter.parse("no frontmatter").count, 0, "no block → empty")
    expectEqual(Frontmatter.parse("---\nkey: v\nno close").count, 0, "unclosed block → empty")
    expectEqual(Frontmatter.parse("---\nKEY: v\n---\n").count, 1, "parses")
    expectEqual(Frontmatter.parse("---\nKEY: v\n---\n")["key"], "v", "keys lowercased")
}
