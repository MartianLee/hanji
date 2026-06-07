import SwiftUI
import AppKit
import MarkdownCore
import ExtensionSDK

/// NSTextView that lets a callback handle a click (used for task checkboxes).
final class ClickableTextView: NSTextView {
    var onClick: ((Int) -> Bool)?
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: p)
        if onClick?(idx) == true { return }
        super.mouseDown(with: event)
    }
}

/// Markdown editing surface (TextKit 2) with incremental Live Preview:
/// inline styling + caret-aware marker hiding, plus inline rendering of fenced
/// code blocks whose language has a registered renderer (the source is preserved
/// and revealed when the caret enters the block).
public struct MarkdownEditorView: NSViewRepresentable {
    @Binding public var text: String
    public var renderers: RendererRegistry?

    public init(text: Binding<String>, renderers: RendererRegistry? = nil) {
        self._text = text
        self.renderers = renderers
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = ClickableTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = LivePreviewStyler.baseFont
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.string = text
        if let caretEnv = ProcessInfo.processInfo.environment["HANJI_CARET"], let caret = Int(caretEnv) {
            let len = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(max(0, caret), len), length: 0))
        }

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        context.coordinator.textView = textView
        context.coordinator.renderers = renderers
        textView.onClick = { [weak coordinator = context.coordinator] idx in
            coordinator?.toggleCheckbox(at: idx) ?? false
        }
        context.coordinator.refresh()
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.renderers = renderers
        if textView.string != text {
            textView.string = text
            context.coordinator.refresh()
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        weak var textView: NSTextView?
        var renderers: RendererRegistry?
        private var overlays: [String: NSHostingView<AnyView>] = [:]

        init(_ parent: MarkdownEditorView) { self.parent = parent }

        func refresh() {
            restyle()
            DispatchQueue.main.async { [weak self] in self?.updateBlockViews() }
        }

        /// Toggle a task checkbox if the click landed on one. Returns true if handled.
        func toggleCheckbox(at index: Int) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            guard let t = TaskToggle.toggle(in: storage.string, at: index) else { return false }
            storage.replaceCharacters(in: NSRange(location: t.offset, length: 1), with: t.replacement)
            parent.text = textView.string
            refresh()
            return true
        }

        /// Inline styling + caret-aware marker hiding (Live Preview).
        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let spans = InlineTokenizer.spans(in: storage.string)
            let sel = textView.selectedRange()
            let selection = sel.location..<(sel.location + sel.length)
            let deco = Decorator.decorations(spans: spans, selection: selection)
            LivePreviewStyler.apply(deco, to: storage)
        }

        /// Overlay rendered widgets for code blocks with a registered renderer.
        /// Non-mutating: positions an NSHostingView over the block's laid-out
        /// region; the raw source is revealed when the caret is inside the block.
        func updateBlockViews() {
            guard let textView else { return }
            let tlm = textView.textLayoutManager
            let tcs = tlm?.textContentManager as? NSTextContentStorage
            guard let tlm, let tcs, let registry = renderers else { clearOverlays(); return }
            tlm.ensureLayout(for: tcs.documentRange)

            let text = textView.string as NSString
            let sel = textView.selectedRange()
            let caret = sel.location..<(sel.location + sel.length)
            let origin = textView.textContainerOrigin
            var live: Set<String> = []

            for region in CodeBlockParser.regions(in: textView.string) {
                guard let renderer = registry.renderer(for: region.language) else { continue }
                if intersects(region.full, caret) { continue }   // editing: show source
                guard let textRange = textRange(region.full, in: tcs) else { continue }

                var rect = CGRect.null
                tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segFrame, _, _ in
                    rect = rect.isNull ? segFrame : rect.union(segFrame)
                    return true
                }
                if rect.isNull { continue }
                let frame = rect.offsetBy(dx: origin.x, dy: origin.y)

                let bodyLen = max(0, region.body.upperBound - region.body.lowerBound)
                let body = text.substring(with: NSRange(location: region.body.lowerBound, length: bodyLen))
                let key = "\(region.full.lowerBound)-\(region.full.upperBound)-\(region.language)"
                live.insert(key)

                let view = renderer.makeView(source: body)
                if let existing = overlays[key] {
                    existing.rootView = view
                    existing.frame = frame
                } else {
                    let host = NSHostingView(rootView: view)
                    host.frame = frame
                    textView.addSubview(host)
                    overlays[key] = host
                }
            }
            for (key, view) in overlays where !live.contains(key) {
                view.removeFromSuperview()
                overlays[key] = nil
            }
        }

        private func clearOverlays() {
            overlays.values.forEach { $0.removeFromSuperview() }
            overlays.removeAll()
        }

        private func textRange(_ r: Range<Int>, in tcs: NSTextContentStorage) -> NSTextRange? {
            guard let start = tcs.location(tcs.documentRange.location, offsetBy: r.lowerBound),
                  let end = tcs.location(start, offsetBy: r.upperBound - r.lowerBound) else { return nil }
            return NSTextRange(location: start, end: end)
        }

        private func intersects(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
            a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            refresh()
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            refresh()
        }
    }
}
