import Foundation
import MarkdownCore

/// `[[` link completion: when it's offered, what it suggests, and the edit a
/// pick makes.
func linkCompletionChecks() {
    func ctx(_ s: String) -> LinkCompletion.Context? {
        // `‸` marks the caret.
        let caret = (s as NSString).range(of: "‸").location
        let text = (s as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        return LinkCompletion.context(in: text as NSString, caret: caret)
    }
    expectEqual(ctx("See [[‸")?.query, "", "offered right after [[")
    expectEqual(ctx("See [[Al‸")?.query, "Al", "the query is what follows [[")
    expectEqual(ctx("See [[Al‸")?.queryRange, NSRange(location: 6, length: 2), "and its range")
    expectEqual(ctx("![[Pic‸")?.query, "Pic", "embeds too")
    expectEqual(ctx("See [[한글 노‸")?.query, "한글 노", "spaces and Hangul are part of the query")
    expect(ctx("See [‸") == nil, "not after a single [")
    expect(ctx("See [[Alpha]] and ‸") == nil, "not after a closed link")
    expect(ctx("See [[Alpha|al‸") == nil, "not once an alias is being typed")
    expect(ctx("See [[Alpha#He‸") == nil, "not once a heading is being typed")
    expect(ctx("[[Al\nmore‸") == nil, "not across a line break")
    expect(ctx("‸") == nil && ctx("a‸") == nil, "not at the start of a note")
    let editing = ctx("See [[Al‸pha]] now")
    expectEqual(editing?.query, "Al", "inside an existing link, the query is up to the caret")
    expectEqual(editing?.replace, NSRange(location: 6, length: 5), "but a pick replaces the whole target")
    expectEqual(editing?.closed, true, "which is already closed")
    expectEqual(ctx("See [[Al‸ and")?.closed, false, "an open link isn't closed")
    expectEqual(ctx("See [[Al‸ and")?.replace, NSRange(location: 6, length: 2), "and only the query is replaced")

    let notes = ["Alpha", "Projects/Alpha", "Projects/Plan", "Daily/2026-09-28", "Beta", "한글 노트", "Archive/Palette"]
    func names(_ q: String) -> [String] { LinkCompletion.suggestions(for: q, notes: notes).map(\.path) }
    expectEqual(names("plan").first, "Projects/Plan", "fuzzy match on the name")
    expectEqual(Array(names("alp").prefix(2)), ["Alpha", "Projects/Alpha"], "ties go to the shorter path")
    expect(names("projects").contains("Projects/Plan"), "a folder in the path matches too")
    expectEqual(names("pal").first, "Archive/Palette", "a name match beats a path-only one")
    expectEqual(names("한글").first, "한글 노트", "Hangul matches")
    let decomposed = "한글 노트".decomposedStringWithCanonicalMapping
    expectEqual(LinkCompletion.suggestions(for: "한글", notes: [decomposed]).count, 1,
                "a decomposed name from disk still matches a composed query")
    expectEqual(names("PLAN").first, "Projects/Plan", "case doesn't matter")
    expect(names("zzz").isEmpty, "nothing for no match")
    expectEqual(LinkCompletion.suggestions(for: "", notes: notes, limit: 3).map(\.path),
                ["Daily/2026-09-28", "Alpha", "Projects/Alpha"],
                "an empty query lists notes by name")
    expectEqual(LinkCompletion.suggestions(for: "", notes: notes, limit: 100).count, notes.count, "up to the limit")

    let s = LinkCompletion.suggestions(for: "beta", notes: notes)[0]
    expectEqual(s.linkText, "Beta", "a unique name links by name")
    let dup = LinkCompletion.suggestions(for: "alpha", notes: notes)
    expectEqual(dup.map(\.linkText), ["Alpha", "Projects/Alpha"], "a shared name links by path")
    expectEqual(dup[1].name, "Alpha", "name")
    expectEqual(dup[1].folder, "Projects", "folder")

    let open = LinkCompletion.accept(s, in: ctx("See [[be‸")!)
    expectEqual(open.range, NSRange(location: 6, length: 2), "a pick replaces the query")
    expectEqual(open.text, "Beta]]", "with the link text, closed")
    expectEqual(open.caret, 12, "and the caret lands after ]]")
    let closed = LinkCompletion.accept(s, in: ctx("See [[b‸ta]] now")!)
    expectEqual(closed.text, "Beta", "an already closed link isn't closed twice")
    expectEqual(closed.range, NSRange(location: 6, length: 3), "the old target goes")
    expectEqual(closed.caret, 12, "and the caret still lands after ]]")
}
