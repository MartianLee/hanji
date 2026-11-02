import AppKit
import SwiftUI
import EditorEngine
import MarkdownCore

/// A table as it's copied from a chat or a doc: a blank line first, no newline after.
private let copiedTable = """

| 번호 | 게시일 | 본문 첫 줄 |
|---|---|---|
| 37 | 04-14 | 내 짝꿍은 어땠더라☺️ |
| 49 | 06-11 | 📱💅🏾 |
| 52 | 06-26 | 💁‍♂️: 내 말랑이는 여기 있눈데 |
| 60 | 07-28 | 🫰❤️ |
"""

/// A pasted markdown table gets lines of its own: a newline after it when it
/// ends the paste, one before it when it's pasted mid-line. Other text is
/// pasted as it is.
func tablePasteChecks() {
    let tables = TableParser.tables(in: copiedTable)
    expectEqual(tables.first?.rows.last, ["60", "07-28", "🫰❤️"], "setup: the copied table parses, emoji and all")

    expectEqual(TablePaste.adjusted(copiedTable, atLineStart: true), copiedTable + "\n",
                "a table ending the paste gets a newline after it")
    let bare = "| a | b |\n|---|---|\n| 1 | 2 |"
    expectEqual(TablePaste.adjusted(bare, atLineStart: false), "\n" + bare + "\n",
                "pasted mid-line, it starts on a line of its own too")
    expectEqual(TablePaste.adjusted(bare + "\n", atLineStart: true), bare + "\n", "a newline already there is enough")
    expectEqual(TablePaste.adjusted(bare + "\nafter", atLineStart: true), bare + "\nafter", "text after the table: left alone")
    expectEqual(TablePaste.adjusted("a | b", atLineStart: false), "a | b", "a pipe that isn't a table: left alone")
    expectEqual(TablePaste.adjusted("```\n| a |\n|---|\n```", atLineStart: true), "```\n| a |\n|---|\n```",
                "nor a table inside code")
}

/// Pasting a table into the editor draws it straight away, with the caret on
/// the line below it.
func editorTablePasteChecks() {
    guard let h = EditorHarness("Intro\n", cursorOffset: 6) else { expect(false, "editor"); return }
    defer { h.close() }
    h.pump(0.3)
    let tv = h.textView
    // A private pasteboard: the general one is the user's clipboard.
    let pb = NSPasteboard(name: NSPasteboard.Name("mk-tablepaste-\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    pb.clearContents()
    pb.setString(copiedTable, forType: .string)
    _ = tv.readSelection(from: pb)
    h.pump(0.6)
    expectEqual(tv.string, "Intro\n" + copiedTable + "\n", "the table goes in with a newline after it")
    expectEqual(tv.selectedRange().location, (tv.string as NSString).length, "the caret below the table")
    expectEqual(tv.subviews.filter { $0 is NSHostingView<AnyView> }.count, 1, "and the table is drawn as a grid")
    tv.undoManager?.undo()
    h.pump(0.3)
    expectEqual(tv.string, "Intro\n", "one undo takes the whole paste back")
}
