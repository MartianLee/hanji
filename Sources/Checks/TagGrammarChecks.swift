import AppKit
import SwiftUI
import MarkdownCore
import EditorEngine
import MKSearchKit

/// `#tags` as their own thing: one grammar shared by the index and the editor.
func tagGrammarChecks() {
    func tags(_ s: String) -> [String] { Tags.occurrences(in: s).map(\.name) }
    let occ = Tags.occurrences(in: "todo #daily and #proj/sub")
    expectEqual(occ.map(\.name), ["daily", "proj/sub"], "names, nested tags included")
    expectEqual(occ.map(\.range), [5..<11, 16..<25], "UTF-16 ranges include the #")
    expectEqual(Tags.occurrences(in: "오늘 #일기 끝").map(\.range), [3..<6], "Korean tags, UTF-16 offsets")
    expectEqual(tags("#2026년 #123"), ["2026년"], "a tag needs a non-digit; #123 isn't one")
    expectEqual(tags("a#b http://x.com/#frag [[note#part]] [[#part]]"), [], "# inside words, URLs and links isn't a tag")
    expectEqual(tags("# Heading\n## Two\n#tag"), ["tag"], "headings aren't tags; #tag at line start is")
    expectEqual(tags("```\n#notatag\n```\n#yes"), ["yes"], "fenced code is skipped")
    expectEqual(tags("use `#notatag` or ``x #no`` and #yes"), ["yes"], "inline code is skipped")
    expectEqual(tags("#end."), ["end"], "trailing punctuation isn't part of the tag")
    expectEqual(Tags.extract(from: "#x #y #x"), ["x", "y"], "extract still dedups, in order")

    // Tokenizer: tags get their own span; the styler gives them their own look.
    let spans = InlineTokenizer.spans(in: "see #daily here")
    expect(spans.contains { $0.style == .tag && $0.content == 4..<10 }, "the tokenizer emits a tag span")
    expect(!InlineTokenizer.spans(in: "`#code`").contains { $0.style == .tag }, "not inside inline code")
    let storage = NSTextStorage(string: "see #daily here")
    LivePreviewStyler.apply(Decorator.decorations(spans: InlineTokenizer.spans(in: storage.string), selection: 0..<0),
                            to: storage)
    expect(storage.attribute(.backgroundColor, at: 5, effectiveRange: nil) != nil, "a tag is drawn as a pill")
    expect(storage.attribute(.backgroundColor, at: 1, effectiveRange: nil) == nil, "plain text isn't")
}

/// Clicking a tag in the editor reports it.
func editorTagClickChecks() {
    var text = "see #daily here"
    var opened: String?
    let view = MarkdownEditorView(text: Binding(get: { text }, set: { text = $0 }), onOpenTag: { opened = $0 })
    let coordinator = view.makeCoordinator()
    let textView = NSTextView()
    textView.delegate = coordinator
    textView.string = text
    coordinator.textView = textView
    coordinator.sync(with: view)
    expect(coordinator.handleClick(at: 6), "a click on a tag is handled")
    expectEqual(opened, "daily", "with the tag's name")
    opened = nil
    expect(!coordinator.handleClick(at: 1), "a click on plain text isn't")
    expectEqual(opened, nil, "and opens nothing")
}

/// Searching for exactly one tag lists the notes that carry it (nested tags
/// included), not every note whose text contains the characters.
func tagSearchChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-tagsearch-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)); try? fm.removeItem(at: vault) }
    for (name, body) in [("a.md", "today #daily"), ("b.md", "#project/hanji work"),
                         ("c.md", "the word daily, untagged"), ("d.md", "`#daily` in code"),
                         ("e.md", "#dailynotes is another tag")] {
        try? body.write(to: vault.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    guard let index = try? SearchIndex(vaultRoot: vault), (try? index.reindexAll(vault: vault)) != nil else {
        expect(false, "index opens"); return
    }
    expectEqual((try? index.search("#daily"))?.map(\.path), ["a.md"], "#daily finds the note tagged #daily only")
    expectEqual((try? index.search("#DAILY"))?.map(\.path), ["a.md"], "tags match case-insensitively")
    expectEqual((try? index.search("#project"))?.map(\.path), ["b.md"], "a parent tag finds nested tags")
    expect(((try? index.search("daily")) ?? []).count >= 2, "plain words still search the text")
}
