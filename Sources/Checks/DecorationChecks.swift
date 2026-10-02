import MarkdownCore

func decorationChecks() {
    let spans = InlineTokenizer.spans(in: "**b**")   // bold on a single line 0..<5

    // Caret far away -> markers hidden, content styled bold
    let away = Decorator.decorations(spans: spans, selection: 100..<100)
    expectEqual(away.hidden, [0..<2, 3..<5], "markers hidden when caret off the line")
    expectEqual(away.styles.count, 1, "one style run")
    expectEqual(away.styles.first?.style, .bold, "bold style run")
    expectEqual(away.styles.first?.range, 0..<5, "style covers whole span incl markers")

    // Caret on the line -> markers revealed (not hidden)
    let on = Decorator.decorations(spans: spans, selection: 2..<2)
    expectEqual(on.hidden, [], "no markers hidden when caret is on the line")
    expectEqual(on.styles.first?.style, .bold, "content still styled on active line")

    // No caret at all (reading mode) -> every line hides its markers
    let none = Decorator.decorations(spans: spans, selection: nil)
    expectEqual(none.hidden, [0..<2, 3..<5], "no selection hides the markers on every line")
}
