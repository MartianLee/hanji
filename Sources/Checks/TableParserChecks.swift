import Foundation
import MarkdownCore

func tableParserChecks() {
    let text = """
    Intro
    | Name | Qty | Note |
    |:-----|:---:|-----:|
    | **apple** | 3 | [[fruit\\|Fruit]] |
    | pear |
    after the table
    """
    let tables = TableParser.tables(in: text)
    expectEqual(tables.count, 1, "one table")
    guard let t = tables.first else { return }
    let ns = text as NSString
    expectEqual(ns.substring(with: NSRange(location: t.range.lowerBound, length: t.range.count)),
                "| Name | Qty | Note |\n|:-----|:---:|-----:|\n| **apple** | 3 | [[fruit\\|Fruit]] |\n| pear |",
                "range runs from the header to the last row, stopping at a line without a pipe")
    expectEqual(t.alignments, [.left, .center, .right], "alignment from the colons")
    expectEqual(t.header, ["Name", "Qty", "Note"], "header cells trimmed")
    expectEqual(t.rows, [["**apple**", "3", "[[fruit|Fruit]]"], ["pear", "", ""]],
                "\\| is unescaped inside a cell, short rows padded")

    // Leading/trailing pipes are optional; extra cells are dropped.
    let bare = TableParser.tables(in: "a | b\n--- | ---\n1 | 2 | 3")
    expectEqual(bare.first?.header, ["a", "b"], "table without outer pipes")
    expectEqual(bare.first?.rows, [["1", "2"]], "excess cells dropped")
    expectEqual(bare.first?.alignments, [MarkdownTable.Alignment.none, .none], "no colons, no alignment")

    // Not tables.
    expectEqual(TableParser.tables(in: "| a | b |\n|---|\n| 1 | 2 |").count, 0, "header and delimiter cell counts must match")
    expectEqual(TableParser.tables(in: "| a |\nplain line").count, 0, "no delimiter row")
    expectEqual(TableParser.tables(in: "a\n---").count, 0, "a rule under a line is not a delimiter row")
    expectEqual(TableParser.tables(in: "| a |\n| x |").count, 0, "a delimiter row is dashes only")
    expectEqual(TableParser.tables(in: "    | a |\n    |---|").count, 0, "4 spaces of indent is not a table")
    expectEqual(TableParser.tables(in: "```\n| a |\n|---|\n```").count, 0, "no tables in fenced code")
    expectEqual(TableParser.tables(in: "```\n| a |\n|---|").count, 0, "nor in a fence still open")
    expectEqual(TableParser.tables(in: "---\nk: | a |\n|---|\n---\n").count, 0, "nor in frontmatter")

    // A blank line ends the body; a table right after code still counts.
    let two = TableParser.tables(in: "```\ncode\n```\n| a |\n| - |\n| 1 |\n\n| b |\n| - |")
    expectEqual(two.map(\.header), [["a"], ["b"]], "two tables, split by a blank line")
    expectEqual(two.first?.rows, [["1"]], "the blank line is not a row")

    // CRLF: \r is not part of any cell, and the range stops before it.
    let crlf = TableParser.tables(in: "| a | b |\r\n|---|--:|\r\n| 1 | 2 |\r\nnext")
    expectEqual(crlf.first?.header, ["a", "b"], "CRLF header")
    expectEqual(crlf.first?.alignments, [MarkdownTable.Alignment.none, .right], "CRLF delimiter")
    expectEqual(crlf.first?.rows, [["1", "2"]], "CRLF row")
    expectEqual(crlf.first?.range, 0..<31, "CRLF range excludes the last \\r\\n")

    // Cell markdown → runs, markers gone.
    expectEqual(TableParser.runs("**b** and [[note|alias]]"),
                [CellRun(text: "b", style: .bold), CellRun(text: " and ", style: []), CellRun(text: "alias", style: .link)],
                "bold and aliased link")
    expectEqual(TableParser.runs("`a|b` #tag"),
                [CellRun(text: "a|b", style: .code), CellRun(text: " ", style: []), CellRun(text: "#tag", style: .tag)],
                "code and tag")
    expectEqual(TableParser.runs("# not a heading"),
                [CellRun(text: "# not a heading", style: [])],
                "block syntax stays literal in a cell")
    expectEqual(TableParser.runs(""), [], "empty cell")
    expectEqual(TableParser.cells("| a \\| b | c |"), ["a | b", "c"], "escaped pipe splits nothing")
    expectEqual(TableParser.cells("| 한글 | 😀 |"), ["한글", "😀"], "non-ASCII cells")

    // Column widths: as wished when they fit, else the wide columns share what's left.
    expectEqual(TableParser.columnWidths(ideal: [50, 100], available: 300), [50, 100], "fits: ideal widths")
    expectEqual(TableParser.columnWidths(ideal: [50, 900, 60], available: 400), [50, 290, 60], "one wide column takes the rest")
    expectEqual(TableParser.columnWidths(ideal: [500, 900], available: 400), [200, 200], "two wide columns split it")
    expectEqual(TableParser.columnWidths(ideal: [], available: 400), [], "no columns")
}
