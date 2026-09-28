import AppKit
import SwiftUI
import EditorEngine

/// Pasting tens of thousands of characters stays fast — a regression guard.
/// The paste goes through the same path ⌘V takes (`readSelection(from:)`), but
/// from a private pasteboard, so running the checks never touches the user's
/// clipboard. What's timed is how long the app is blocked: the paste itself
/// plus the restyle and widget pass it queues. Undoing the paste is timed too.
///
/// Two guards. Absolute limits for the debug build the checks run in, about 3×
/// what an M-series Mac measures today (best of 3: 50k pastes in ~365ms and
/// undoes in ~45ms; 200k in ~1.3s and ~185ms — tables and code blocks in it
/// each become a widget), 3× more on CI (`Check.timeSlack`), so a real
/// slowdown fails and a slow machine doesn't. And a scaling limit that holds on
/// any machine: 4× the text may cost at most 8× the time — linear is 4×, and an
/// accidental O(n²) (a restyle per line, a rescan per character) would be 16×.
func pastePerfChecks() {
    let board = NSPasteboard(name: NSPasteboard.Name("io.hanji.checks.paste-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }

    /// A realistic chunk of notes: headings, lists (with a nested code block),
    /// code, links, tags, a table row and Korean text.
    func payload(characters: Int) -> String {
        let block = """
        ## Section heading with **bold** and `code`

        Paragraph text with a [[Wiki Link]], a [link](https://example.com), #tag and some 한글 문장이 섞인 내용입니다.
        - list item one with *italic*
        - list item two
            ```swift
            let value = compute(42)
            ```
        1. ordered item
        - [ ] a task to do
        > a quote line

        ```python
        def f(x):
            return x * 2
        ```

        | a | b |
        |---|---|

        """
        var out = ""
        while (out as NSString).length < characters { out += block }
        return out
    }

    /// Seconds the main thread is busy for `work` and what it queues.
    func blocked(_ work: () -> Void) -> TimeInterval {
        let start = Date()
        work()
        // Drain what the paste queued (restyle hops, the widget pass).
        for _ in 0..<5 { RunLoop.main.run(mode: .default, before: Date()) }
        return Date().timeIntervalSince(start)
    }

    let intro = String(repeating: "Existing line of the note with some **markdown**.\n", count: 200)
    var pasteBySize: [Int: TimeInterval] = [:]
    for (size, limits) in [(50_000, (paste: 1.0, undo: 0.25)), (200_000, (paste: 4.0, undo: 0.5))] {
        let text = payload(characters: size)
        var pasteTimes: [TimeInterval] = [], undoTimes: [TimeInterval] = []
        var pastedRight = true
        for _ in 0..<3 {
            guard let h = EditorHarness(intro, cursorOffset: (intro as NSString).length) else {
                expect(false, "editor found"); return
            }
            h.caret(at: (intro as NSString).length)
            h.pump(0.3)
            board.clearContents()
            board.setString(text, forType: .string)
            pasteTimes.append(blocked { _ = h.textView.readSelection(from: board) })
            h.pump(0.2)
            pastedRight = pastedRight && h.text == intro + text
            undoTimes.append(blocked { h.textView.undoManager?.undo() })
            h.pump(0.2)
            pastedRight = pastedRight && h.text == intro
            h.close()
        }
        let paste = pasteTimes.min()!, undo = undoTimes.min()!
        pasteBySize[size] = paste
        if ProcessInfo.processInfo.environment["HANJI_PERF"] != nil {
            print(String(format: "PERF paste %dk  %.0fms  undo %.0fms", size / 1000, paste * 1000, undo * 1000))
        }
        expect(pastedRight, "\(size / 1000)k characters paste and undo exactly")
        let pasteLimit = limits.paste * Check.timeSlack, undoLimit = limits.undo * Check.timeSlack
        expect(paste < pasteLimit,
               "pasting \(size / 1000)k characters blocks for \(Int(paste * 1000))ms (limit \(Int(pasteLimit * 1000))ms)")
        expect(undo < undoLimit,
               "undoing it blocks for \(Int(undo * 1000))ms (limit \(Int(undoLimit * 1000))ms)")
    }
    if let small = pasteBySize[50_000], let large = pasteBySize[200_000] {
        expect(large < small * 8,
               "paste time grows linearly: 4× the text took \(String(format: "%.1f", large / small))× the time (limit 8×)")
    }
}
