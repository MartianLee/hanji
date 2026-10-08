import Foundation
import AppCore

/// The inline title's draft renames the note it was typed for, never the note
/// shown next: switching tabs or into reading mode mid-edit (#20) hands back the
/// pending rename for the old note before the title shows the new one.
func titleDraftChecks() {
    let a = URL(fileURLWithPath: "/vault/Alpha.md")
    let b = URL(fileURLWithPath: "/vault/Beta.md")

    var draft = TitleDraft(url: a)
    expectEqual(draft.text, "Alpha", "starts from the note's name")
    expect(draft.rename == nil, "nothing to rename while untouched")

    draft.text = "  Gamma "
    expectEqual(draft.rename, TitleDraft.Rename(url: a, name: "Gamma"), "an edit renames its own note, trimmed")

    let pending = draft.show(b)
    expectEqual(pending, TitleDraft.Rename(url: a, name: "Gamma"),
                "showing another note hands back the old note's pending rename")
    expectEqual(draft.url, b, "then the draft belongs to the new note")
    expectEqual(draft.text, "Beta", "and shows its name")
    expect(draft.rename == nil, "with nothing pending")

    expect(draft.show(a) == nil, "an untouched draft has nothing to hand back")

    draft.text = "   "
    expect(draft.rename == nil, "a blank title renames nothing")
    draft.revert()
    expectEqual(draft.text, "Alpha", "and reverts to the note's name")
    draft.text = "Alpha"
    expect(draft.rename == nil, "nor does the same name")
}
