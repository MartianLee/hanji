import AppKit
import MarkdownCore
import EditorEngine

func noteEmbedChecks() {
    let text = "a\n![[Plan]]\n![[img.png]]\n  ![[Plan#Goals|g]]\n![alt](x.png)\n![[Note v1.2]]\n![[Doc.md]]"
    let e = NoteEmbeds.embeds(in: text)
    expectEqual(e.map(\.target), ["Plan", "Plan", "Note v1.2", "Doc.md"], "note embeds only, not images")
    expectEqual(e.map(\.heading), [nil, "Goals", nil, nil], "the #heading")
    expectEqual(e.first?.line, 2..<11, "the whole line")
    let note = "intro\n# Goals\nfirst\n## Sub\ndeeper\n# Next\nafter"
    expectEqual(NoteEmbeds.section("goals", in: note), "# Goals\nfirst\n## Sub\ndeeper", "to the next heading of its level")
    expectEqual(NoteEmbeds.section("Sub", in: note), "## Sub\ndeeper", "a subsection ends at a higher heading")
    expectEqual(NoteEmbeds.section("Missing", in: note), nil, "no such heading")
    expectEqual(NoteEmbeds.heading(inLink: "[[Plan#Goals|the plan]]"), "Goals", "wikilink heading")
    expectEqual(NoteEmbeds.heading(inLink: "[t](Plan.md#Goals)"), "Goals", "markdown link anchor")
    expectEqual(NoteEmbeds.heading(inLink: "[[Plan]]"), nil, "none")
}

func renderedTextChecks() {
    let md = "---\ntags: [a]\n---\n# Title\nSome **bold** and [[Link|alias]].\n- item\n- [ ] todo\n- [x] done\n```swift\nlet x = 1\n```"
    let r = RenderedText.attributed(md)
    expectEqual(r.string, "Title\nSome bold and alias.\n• item\n☐ todo\n☑ done\nlet x = 1", "markers, fences and frontmatter gone; bullets and boxes drawn")
    expectEqual(RenderedText.attributed("```\ncode\n```\nNext").string, "code\nNext", "a block mid-note joins the next line")
    expect(RenderedText.opensWithTitle("Plan", in: "---\na: 1\n---\n\n# plan\nx"), "a note opening with its title")
    expect(!RenderedText.opensWithTitle("Plan", in: "intro\n# Plan"), "a title further down doesn't count")
    expect(!RenderedText.opensWithTitle("Plan", in: "## Plan"), "nor a lower heading")
    let font = r.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    expect((font?.pointSize ?? 0) > LivePreviewStyler.baseFontSize, "the heading keeps its size")
    let bold = r.attribute(.font, at: (r.string as NSString).range(of: "bold").location, effectiveRange: nil) as? NSFont
    expect(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true, "bold stays bold")
}

func editorEmbedChecks() {
    let note = "Top\n![[Plan]]\nBelow\n![[Gone]]\nEnd"
    let ns = note as NSString
    let previews = ["Plan": NotePreview(title: "Plan", text: "# Plan\nThe plan's body.")]
    guard let h = EditorHarness(note, cursorOffset: ns.length, notePreview: { previews[$0] }) else { expect(false, "editor"); return }
    defer { h.close() }
    h.pump(0.5)
    let cards = h.textView.subviews.filter { $0.fittingSize.height > 30 }
    expectEqual(cards.count, 2, "both embeds are cards (a missing note too)")
    let below = ns.range(of: "Below").location
    func top(_ offset: Int) -> CGFloat { h.textView.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil).minY }
    let withCard = top(below)
    h.caret(at: ns.range(of: "![[Plan]]").location + 3); h.pump(0.4)
    expect(abs(top(below) - withCard) > 20, "the caret on the line brings the source back")
}

func editorLinkPreviewChecks() {
    let note = "See [[Plan]] and [[Gone]] here."
    let ns = note as NSString
    let at = ns.range(of: "Plan").location, gone = ns.range(of: "Gone").location
    let previews = ["Plan": NotePreview(title: "Plan", text: "Body")]
    guard let h = EditorHarness(note, cursorOffset: ns.length, notePreview: { previews[$0] }) else { expect(false, "editor"); return }
    defer { h.close() }
    guard let c = h.textView.delegate as? MarkdownEditorView.Coordinator else { expect(false, "coordinator"); return }
    c.hover(at: at, modifiers: []); h.pump(0.7)
    expect(!c.isPreviewShown, "editing: resting without ⌘ shows nothing")
    c.hover(at: at, modifiers: .command); h.pump(0.3)
    expect(!c.isPreviewShown, "not before the delay")
    h.pump(0.4)
    expect(c.isPreviewShown, "editing: ⌘ + rest shows the preview")
    c.hover(at: 0, modifiers: .command); h.pump(0.8)
    expect(!c.isPreviewShown, "leaving the link closes it")
    c.hover(at: gone, modifiers: .command); h.pump(0.7)
    expect(!c.isPreviewShown, "a missing note has no preview")
    h.isReading = true; h.rebuild()
    c.hover(at: at, modifiers: []); h.pump(0.7)
    expect(c.isPreviewShown, "reading: resting is enough")
    h.isReading = false; h.rebuild()
    expect(!c.isPreviewShown, "a mode switch closes it")
}
