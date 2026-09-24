import AppKit
import SwiftUI
import EditorEngine

/// SwiftUI keeps one editor (and its coordinator) alive while the binding it is
/// handed changes — in split view a pane's editor flips between the live buffer
/// and a frozen snapshot as focus moves. Edits must reach the binding the view
/// holds *now*, never the one it was created with.
func editorBindingChecks() {
    var first = "note A"
    var second = "note B"
    let bindingA = Binding(get: { first }, set: { first = $0 })
    let bindingB = Binding(get: { second }, set: { second = $0 })

    let coordinator = MarkdownEditorView(text: bindingA).makeCoordinator()
    let textView = NSTextView()
    coordinator.textView = textView
    coordinator.sync(with: MarkdownEditorView(text: bindingB))

    textView.string = "typed"
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    expectEqual(second, "typed", "an edit lands in the binding the view holds now")
    expectEqual(first, "note A", "the binding it was created with is left alone")
}

/// An inactive split pane shows a snapshot, not the live buffer, so a click there
/// must not toggle a checkbox it can't save — it only focuses the pane. The live
/// editor still toggles on the first click.
func editorSnapshotClickChecks() {
    func click(live: Bool) -> (handled: Bool, bound: String, shown: String) {
        var text = "- [ ] task"
        let binding = Binding(get: { text }, set: { text = $0 })
        let view = MarkdownEditorView(text: binding, isLive: live)
        let coordinator = view.makeCoordinator()
        let textView = NSTextView()
        textView.string = text
        coordinator.textView = textView
        coordinator.sync(with: view)
        let handled = coordinator.handleClick(at: 3)
        return (handled, text, textView.string)
    }
    let live = click(live: true)
    expect(live.handled, "the live editor handles a checkbox click")
    expectEqual(live.bound, "- [x] task", "the live editor toggles and saves the checkbox")

    let snapshot = click(live: false)
    expect(!snapshot.handled, "a snapshot editor passes the click on, so it just focuses")
    expectEqual(snapshot.bound, "- [ ] task", "nothing is written through the snapshot binding")
    expectEqual(snapshot.shown, "- [ ] task", "and the checkbox doesn't look toggled either")
}
