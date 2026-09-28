import AppKit
import EditorEngine
import MarkdownCore

/// Keystroke cost in the real editor, for measuring (HANJI_PERF=1; build with
/// `-c release` for numbers that mean something). Prints, per note: median ms
/// and counters per action, including the work each key queues (restyle hops,
/// the widget pass). Asserts nothing — the regression guards live in
/// KeystrokeCost.
func editorPerfProbe() {
    guard ProcessInfo.processInfo.environment["HANJI_PERF"] != nil else { expect(true, "perf probe skipped (HANJI_PERF=1)"); return }
    func note(lines: Int, mixed: Bool) -> String {
        var out: [String] = [], i = 0
        while out.count < lines {
            out += ["## Section \(i)", "Paragraph \(i) with **bold**, `code`, a [[link]] and a #tag that wraps a little further.", "- item", ""]
            if mixed {
                if i % 15 == 3 { out += ["```swift", "let value = \(i)", "print(value)", "```", ""] }
                if i % 21 == 7 { out += ["---", ""] }
                if i % 25 == 11 { out += ["| a | b |", "|---|---|", "| \(i) | x |", ""] }
            }
            i += 1
        }
        return out.joined(separator: "\n")
    }
    func drain() { for _ in 0..<5 { RunLoop.main.run(mode: .default, before: Date()) } }
    struct Row { var ms: Double; var refreshes: Double; var full: Double; var chars: Double; var views: Double; var reserves: Double }
    func measure(_ h: EditorHarness, _ action: () -> Void) -> Row {
        var rows: [Row] = []
        for _ in 0..<15 {
            EditorMetrics.reset()
            let t = Date(); action(); drain()
            rows.append(Row(ms: Date().timeIntervalSince(t) * 1000, refreshes: Double(EditorMetrics.refreshes),
                            full: Double(EditorMetrics.fullRestyles), chars: Double(EditorMetrics.restyledCharacters),
                            views: Double(EditorMetrics.widgetViewsCreated), reserves: Double(EditorMetrics.reservationWrites)))
            h.pump(0.02)
        }
        func med(_ k: KeyPath<Row, Double>) -> Double { rows.map { $0[keyPath: k] }.sorted()[rows.count / 2] }
        return Row(ms: med(\.ms), refreshes: med(\.refreshes), full: med(\.full), chars: med(\.chars), views: med(\.views), reserves: med(\.reserves))
    }
    // Whole-note parses a keystroke may run, 20k-line mixed note, warm.
    do {
        var text = note(lines: 20000, mixed: true)
        let cache = TokenizerCache(); _ = cache.spans(in: text)
        text.insert("x", at: text.index(text.startIndex, offsetBy: text.count / 2))
        func ms(_ f: () -> Void) -> Double { (0..<3).map { _ in let t = Date(); f(); return Date().timeIntervalSince(t) * 1000 }.min()! }
        let copy = text
        print(String(format: "PARSE tokenizer %.1f  hr %.1f  images %.1f  tables %.1f  decorator %.1f  changed %.1f",
                     ms { _ = cache.spans(in: copy) }, ms { _ = HRParser.lines(in: copy) }, ms { _ = ImageParser.images(in: copy) },
                     ms { _ = TableParser.tables(in: copy) }, ms { _ = Decorator.decorations(spans: cache.spans(in: copy), selection: 10..<10) },
                     ms { _ = (copy as NSString).isEqual(to: text) }))
    }
    let only = ProcessInfo.processInfo.environment["HANJI_PERF_ONLY"]
    for (lines, mixed) in [(4000, false), (4000, true), (20000, false), (20000, true)] where only == nil || only == "\(lines / 1000)k \(mixed ? "mixed" : "plain")" {
        let text = note(lines: lines, mixed: mixed)
        guard let h = EditorHarness(text) else { continue }
        let len = (text as NSString).length
        h.caret(at: len / 2); h.pump(0.5)
        let mid = measure(h) { h.key("x", 0) }
        h.caret(at: 200); h.pump(0.3)
        let top = measure(h) { h.key("y", 0) }
        h.caret(at: len / 2); h.pump(0.3)
        let ret = measure(h) { h.key("\r", 36) }
        let move = measure(h) { h.key("\u{F701}", 125) }
        let name = "\(lines / 1000)k \(mixed ? "mixed" : "plain")"
        for (label, r) in [("key mid", mid), ("key top", top), ("return", ret), ("caret line", move)] {
            print(String(format: "PERF %-9@ %-10@ %8.1fms  refresh %.0f  full %.0f  restyled %7.0f  views %3.0f  reserves %4.0f",
                         name as NSString, label as NSString, r.ms, r.refreshes, r.full, r.chars, r.views, r.reserves))
        }
        h.close()
    }
}
