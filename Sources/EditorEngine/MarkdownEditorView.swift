import SwiftUI
import AppKit

/// A plain (no Live Preview yet) markdown editing surface backed by
/// NSTextView on the TextKit 2 stack. Two-way bound to `text`.
public struct MarkdownEditorView: NSViewRepresentable {
    @Binding public var text: String
    public init(text: Binding<String>) { self._text = text }

    public func makeNSView(context: Context) -> NSScrollView {
        // `usingTextLayoutManager: true` opts into TextKit 2 (macOS 12+).
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        init(_ parent: MarkdownEditorView) { self.parent = parent }
        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
