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

/// Hosting view for inline widgets that is transparent to hit-testing, so clicks and
/// scroll fall through to the text view beneath: clicking a rendered block places the
/// caret in it (revealing the source, like arrow keys do) and scrolling over it scrolls
/// the editor instead of being swallowed by the widget (e.g. a mermaid WKWebView).
final class PassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Markdown editing surface (TextKit 2): incremental Live Preview (inline styling
/// + caret-aware marker hiding) + inline widget rendering for fenced code blocks
/// (via the registered renderers) and images. Widgets reserve the height they need
/// (measured via NSHostingView.fittingSize) and reveal raw source when edited.
public struct MarkdownEditorView: NSViewRepresentable {
    @Binding public var text: String
    public var renderers: RendererRegistry?
    public var vaultRoot: URL?
    @Binding public var cursorOffset: Int?

    public init(text: Binding<String>, renderers: RendererRegistry? = nil, vaultRoot: URL? = nil, cursorOffset: Binding<Int?> = .constant(nil)) {
        self._text = text
        self.renderers = renderers
        self.vaultRoot = vaultRoot
        self._cursorOffset = cursorOffset
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
        context.coordinator.vaultRoot = vaultRoot
        textView.onClick = { [weak coordinator = context.coordinator] idx in
            coordinator?.toggleCheckbox(at: idx) ?? false
        }
        context.coordinator.refresh()
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.renderers = renderers
        context.coordinator.vaultRoot = vaultRoot
        if textView.string != text {
            textView.string = text
            context.coordinator.refresh()
        }
        if let offset = cursorOffset,
           let tv = nsView.documentView as? NSTextView {
            let clamped = max(0, min(offset, (tv.string as NSString).length))
            tv.setSelectedRange(NSRange(location: clamped, length: 0))
            tv.scrollRangeToVisible(NSRange(location: clamped, length: 0))
            tv.window?.makeFirstResponder(tv)
            DispatchQueue.main.async { self.cursorOffset = nil }
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        weak var textView: NSTextView?
        var renderers: RendererRegistry?
        var vaultRoot: URL?
        private var overlays: [String: NSHostingView<AnyView>] = [:]

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
            super.init()
            // A block renderer (e.g. mermaid) reports its real height asynchronously;
            // re-measure and re-reserve when that happens.
            NotificationCenter.default.addObserver(self, selector: #selector(widgetDidResize),
                                                   name: .hanjiWidgetDidResize, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func widgetDidResize() {
            DispatchQueue.main.async { [weak self] in self?.updateWidgets() }
        }

        struct WidgetSpec { let key: String; let region: Range<Int>; let view: AnyView }

        func refresh() {
            restyle()
            DispatchQueue.main.async { [weak self] in self?.updateWidgets() }
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

        /// Toggle a task checkbox if the click landed on one. Returns true if handled.
        func toggleCheckbox(at index: Int) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            guard let t = TaskToggle.toggle(in: storage.string, at: index) else { return false }
            storage.replaceCharacters(in: NSRange(location: t.offset, length: 1), with: t.replacement)
            parent.text = textView.string
            refresh()
            return true
        }

        /// Render block widgets (code-block renderers + images) as inline overlays,
        /// reserving the height each needs and hiding the raw source behind them.
        func updateWidgets() {
            guard let textView else { return }
            let tlm = textView.textLayoutManager
            let tcs = tlm?.textContentManager as? NSTextContentStorage
            guard let tlm, let tcs, let storage = textView.textStorage else { clearOverlays(); return }

            let sel = textView.selectedRange()
            let caret = sel.location..<(sel.location + sel.length)
            let nstext = textView.string as NSString

            var specs: [WidgetSpec] = []
            if let registry = renderers {
                for region in CodeBlockParser.regions(in: textView.string) {
                    guard let renderer = registry.renderer(for: region.language) else { continue }
                    if intersects(region.full, caret) { continue }
                    let bodyLen = max(0, region.body.upperBound - region.body.lowerBound)
                    let body = nstext.substring(with: NSRange(location: region.body.lowerBound, length: bodyLen))
                    specs.append(WidgetSpec(key: "cb-\(region.full.lowerBound)-\(region.full.upperBound)-\(region.language)",
                                            region: region.full, view: renderer.makeView(source: body)))
                }
            }
            specs.append(contentsOf: imageWidgets(caret: caret, nstext: nstext))

            let inset = textView.textContainerInset.width
            let width = max(50, textView.bounds.width - inset * 2)
            var live: Set<String> = []
            var placements: [(region: Range<Int>, host: NSHostingView<AnyView>, h: CGFloat)] = []

            // Phase 1: host + measure (fittingSize) + reserve height in the text.
            for spec in specs {
                live.insert(spec.key)
                let host: NSHostingView<AnyView>
                if let existing = overlays[spec.key] { host = existing; host.rootView = spec.view }
                else { host = PassthroughHostingView(rootView: spec.view); textView.addSubview(host); overlays[spec.key] = host }
                host.frame.size.width = width
                let h = min(max(20, host.fittingSize.height), 600)
                reserve(region: spec.region, height: h, in: storage)
                placements.append((spec.region, host, h))
            }

            // Phase 2: re-layout (heights changed), then position each overlay.
            tlm.ensureLayout(for: tcs.documentRange)
            let origin = textView.textContainerOrigin
            for pl in placements {
                guard let tr = textRange(pl.region, in: tcs) else { continue }
                var rect = CGRect.null
                tlm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, f, _, _ in
                    rect = rect.isNull ? f : rect.union(f); return true
                }
                if rect.isNull { continue }
                pl.host.frame = CGRect(x: origin.x, y: rect.minY + origin.y, width: width, height: pl.h)
            }

            for (key, view) in overlays where !live.contains(key) {
                view.removeFromSuperview()
                overlays[key] = nil
            }
        }

        /// Image widgets (own-line `![[...]]` / `![alt](path)`), resolved relative
        /// to the vault root and loaded as NSImage.
        func imageWidgets(caret: Range<Int>, nstext: NSString) -> [WidgetSpec] {
            guard let root = vaultRoot else { return [] }
            var out: [WidgetSpec] = []
            for ref in ImageParser.images(in: nstext as String) {
                if intersects(ref.line, caret) { continue }
                let url = root.appendingPathComponent(ref.path)
                guard let image = NSImage(contentsOf: url) else { continue }
                let view = AnyView(
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 320)
                        .frame(maxWidth: .infinity, alignment: .leading)
                )
                out.append(WidgetSpec(key: "img-\(ref.line.lowerBound)-\(ref.line.upperBound)",
                                      region: ref.line, view: view))
            }
            return out
        }

        /// Reserve `height` for a block: force the first line to that height and
        /// collapse the remaining lines; hide the source (the overlay covers it).
        private func reserve(region: Range<Int>, height: CGFloat, in storage: NSTextStorage) {
            let ns = storage.string as NSString
            let upper = min(region.upperBound, ns.length)
            guard region.lowerBound < upper else { return }
            var firstEnd = region.lowerBound
            while firstEnd < upper && ns.character(at: firstEnd) != 0x0A { firstEnd += 1 }
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = height
            p.maximumLineHeight = height
            storage.addAttributes([.paragraphStyle: p, .foregroundColor: NSColor.clear],
                                  range: NSRange(location: region.lowerBound, length: firstEnd - region.lowerBound))
            if firstEnd < upper {
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear],
                                      range: NSRange(location: firstEnd, length: upper - firstEnd))
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
