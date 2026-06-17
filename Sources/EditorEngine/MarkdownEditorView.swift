import SwiftUI
import AppKit
import MarkdownCore
import ExtensionSDK

/// NSTextView that lets a callback handle a click (used for task checkboxes).
final class ClickableTextView: NSTextView {
    var onClick: ((Int) -> Bool)?
    var onBecameFirstResponder: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: p)
        if onClick?(idx) == true { return }
        super.mouseDown(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecameFirstResponder?() }
        return ok
    }
}

/// Layout fragment that paints a full-width background behind code-block
/// paragraphs, so a fenced block reads as one solid slab — leading between
/// lines, blank lines, and the (marker-hidden) ``` fence lines included.
final class CodeBlockFragment: NSTextLayoutFragment {
    /// First/last paragraph of the block → rounded top/bottom corners.
    var roundsTop = false
    var roundsBottom = false
    /// Text-container width, set by the layout delegate so the slab fills the
    /// whole code column (not just the glyph extent).
    var fillWidth: CGFloat = 0

    /// TextKit 2 clips fragment drawing to this rect, so expand it to the full
    /// code column — otherwise the slab is cut to each line's glyph width.
    override var renderingSurfaceBounds: CGRect {
        let base = super.renderingSurfaceBounds
        guard fillWidth > 0 else { return base }
        let originX = layoutFragmentFrame.origin.x
        return CGRect(x: -originX, y: 0, width: fillWidth, height: layoutFragmentFrame.height)
            .union(base)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        // Span the full container width: `point` is in container coordinates, so
        // container x=0 sits at local x = -point.x; the slab then runs the whole
        // code column (empty lines and line leading included, top/bottom rounded).
        let width = fillWidth > 0 ? fillWidth : renderingSurfaceBounds.width
        // Overdraw 1pt into the next line so adjacent bands overlap — fractional
        // line heights otherwise leave a hairline antialiased seam at the join.
        // The block's last line keeps its exact height (rounded bottom corner).
        let extra: CGFloat = roundsBottom ? 0 : 1
        let rect = CGRect(x: -point.x, y: 0, width: width, height: layoutFragmentFrame.height + extra)
        let radius: CGFloat = 8
        let path = CGMutablePath()
        let tl: CGFloat = roundsTop ? radius : 0
        let tr: CGFloat = roundsTop ? radius : 0
        let bl: CGFloat = roundsBottom ? radius : 0
        let br: CGFloat = roundsBottom ? radius : 0
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 { path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                                tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 { path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                                tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br) }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                                tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl) }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                                tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl) }
        path.closeSubpath()
        context.addPath(path)
        // Solid, appearance-aware code background: a dark slab so light text
        // reads in dark mode, a light slab so dark text reads in light mode.
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        context.setFillColor(isDark ? CGColor(gray: 0.17, alpha: 1.0) : CGColor(gray: 0.95, alpha: 1.0))
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// What a list/task line's marker should render as (the raw `-`/`[ ]` glyphs are
/// hidden but keep their width, so clicks/toggles still map to them).
enum MarkerKind: Equatable { case bullet; case task(Bool) }

/// Draws a bullet • or a checkbox over a list/task line's (hidden) marker.
final class MarkerFragment: NSTextLayoutFragment {
    var kind: MarkerKind = .bullet

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)   // glyphs first (the marker glyphs are clear)
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        let b = renderingSurfaceBounds
        let midY = b.midY
        let x = b.minX
        switch kind {
        case .bullet:
            let r: CGFloat = 2.4
            context.setFillColor(NSColor.secondaryLabelColor.cgColor)
            context.fillEllipse(in: CGRect(x: x + 3, y: midY - r, width: r * 2, height: r * 2))
        case .task(let done):
            let side: CGFloat = 13
            let rect = CGRect(x: x + 1, y: midY - side / 2, width: side, height: side)
            let box = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            if done {
                context.setFillColor(NSColor.controlAccentColor.cgColor)
                context.addPath(box); context.fillPath()
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(1.7); context.setLineCap(.round); context.setLineJoin(.round)
                context.move(to: CGPoint(x: rect.minX + 3, y: midY + 0.5))
                context.addLine(to: CGPoint(x: rect.minX + 5.4, y: midY + 3.2))
                context.addLine(to: CGPoint(x: rect.maxX - 2.8, y: midY - 3.2))
                context.strokePath()
            } else {
                context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
                context.setLineWidth(1.3)
                context.addPath(box); context.strokePath()
            }
        }
        context.restoreGState()
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
    public var fontSize: CGFloat
    /// Called when a wiki/markdown link is clicked, with the raw link target.
    public var onOpenLink: ((String) -> Void)?
    /// Called when the editor text view becomes first responder (user clicks or tabs into it).
    public var onFocus: (() -> Void)?

    public init(text: Binding<String>, renderers: RendererRegistry? = nil, vaultRoot: URL? = nil,
                cursorOffset: Binding<Int?> = .constant(nil), fontSize: CGFloat = 15,
                onOpenLink: ((String) -> Void)? = nil,
                onFocus: (() -> Void)? = nil) {
        self._text = text
        self.renderers = renderers
        self.vaultRoot = vaultRoot
        self._cursorOffset = cursorOffset
        self.fontSize = fontSize
        self.onOpenLink = onOpenLink
        self.onFocus = onFocus
    }

    public func makeNSView(context: Context) -> NSScrollView {
        LivePreviewStyler.baseFontSize = fontSize
        let textView = ClickableTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = LivePreviewStyler.baseFont
        textView.textContainerInset = NSSize(width: 24, height: 20)
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
        // Solid editor background so the inline title strip and the body read as
        // one continuous region (and the area below the text matches too).
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        textView.backgroundColor = .textBackgroundColor

        context.coordinator.textView = textView
        context.coordinator.renderers = renderers
        context.coordinator.vaultRoot = vaultRoot
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.onFocus = onFocus
        textView.textLayoutManager?.delegate = context.coordinator
        textView.onClick = { [weak coordinator = context.coordinator] idx in
            coordinator?.handleClick(at: idx) ?? false
        }
        textView.onBecameFirstResponder = { [weak coordinator = context.coordinator] in coordinator?.onFocus?() }
        context.coordinator.refresh()
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.renderers = renderers
        context.coordinator.vaultRoot = vaultRoot
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.onFocus = onFocus
        if LivePreviewStyler.baseFontSize != fontSize {
            LivePreviewStyler.baseFontSize = fontSize
            textView.font = LivePreviewStyler.baseFont
            context.coordinator.refresh()
        }
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

    public final class Coordinator: NSObject, NSTextViewDelegate, NSTextLayoutManagerDelegate {
        var parent: MarkdownEditorView
        weak var textView: NSTextView?
        var renderers: RendererRegistry?
        var vaultRoot: URL?
        var onOpenLink: ((String) -> Void)?
        var onFocus: (() -> Void)?
        private var overlays: [String: NSHostingView<AnyView>] = [:]
        /// Full UTF-16 ranges (incl. fences) of fenced code blocks, kept fresh by
        /// restyle() for the layout-fragment background fill.
        private var codeRegions: [Range<Int>] = []
        /// UTF-16 ranges currently shown as rendered widgets (code renderers,
        /// images, HR), kept fresh by updateWidgets() so a click on one snaps the
        /// caret to the block start instead of a hit-test guess on collapsed text.
        private var widgetRegions: [Range<Int>] = []
        /// Paragraph-start offset → marker to draw (bullet/checkbox), caret-aware.
        private var markerLines: [Int: MarkerKind] = [:]

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

        private var widgetUpdateScheduled = false

        func refresh() {
            restyle()
            scheduleWidgetUpdate()
        }

        /// Coalesce widget rebuilds: `updateWidgets` forces a full-document layout,
        /// so running it once per keystroke stutters typing. Collapse bursts into
        /// one pass on the next runloop tick.
        private func scheduleWidgetUpdate() {
            guard !widgetUpdateScheduled else { return }
            widgetUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.widgetUpdateScheduled = false
                self?.updateWidgets()
            }
        }

        /// Inline styling + caret-aware marker hiding (Live Preview).
        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let regions = CodeBlockParser.regions(in: storage.string)
            codeRegions = regions.map(\.full)
            let spans = InlineTokenizer.spans(in: storage.string)
            let sel = textView.selectedRange()
            let selection = sel.location..<(sel.location + sel.length)
            let deco = Decorator.decorations(spans: spans, selection: selection)
            LivePreviewStyler.apply(deco, to: storage)
            LivePreviewStyler.highlightCode(regions, in: storage)
            applyMarkers(spans: spans, sel: sel, storage: storage)
        }

        /// Hide list/task marker glyphs (keeping width so clicks/toggles still map)
        /// and record which lines should draw a bullet/checkbox. Caret-aware: the
        /// line being edited shows its raw `- [ ]` text.
        private func applyMarkers(spans: [MarkSpan], sel: NSRange, storage: NSTextStorage) {
            let ns = storage.string as NSString
            let caretLine = ns.paragraphRange(for: sel)
            var marks: [Int: MarkerKind] = [:]
            func onCaret(_ line: Range<Int>) -> Bool {
                let r = NSRange(location: line.lowerBound, length: line.upperBound - line.lowerBound)
                return NSLocationInRange(line.lowerBound, caretLine) || NSIntersectionRange(r, caretLine).length > 0
            }
            func firstNonSpace(_ from: Int, _ upTo: Int) -> Int {
                var i = from
                while i < upTo, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
                return i
            }
            func collapse(_ loc: Int, _ len: Int) {
                guard len > 0, loc >= 0, loc + len <= ns.length else { return }
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear],
                                      range: NSRange(location: loc, length: len))
            }
            func clearGlyph(_ loc: Int, _ len: Int) {
                guard len > 0, loc >= 0, loc + len <= ns.length else { return }
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: loc, length: len))
            }
            for span in spans {
                switch span.style {
                case .listItem:
                    guard !onCaret(span.line) else { continue }
                    let m = firstNonSpace(span.line.lowerBound, span.line.upperBound)
                    clearGlyph(m, 2)              // `- ` invisible (width kept); • drawn over it
                    marks[span.line.lowerBound] = .bullet
                case .task(let done):
                    guard !onCaret(span.line) else { continue }
                    let m = firstNonSpace(span.line.lowerBound, span.line.upperBound)
                    collapse(m, 2)               // `- `
                    clearGlyph(m + 2, 2)         // `[x` kept width = click target; box drawn over
                    collapse(m + 4, 1)           // `]` (trailing space stays as the gap)
                    marks[span.line.lowerBound] = .task(done)
                default:
                    break
                }
            }
            markerLines = marks
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

        /// Handle a mouse click before NSTextView's default caret placement.
        /// Checkbox toggles win first; a click on a rendered widget snaps the
        /// caret to the block's first line (so revealing the source is
        /// predictable, not a hit-test guess against the collapsed text behind
        /// the overlay). Returns true when handled (skip the default placement).
        func handleClick(at index: Int) -> Bool {
            if toggleCheckbox(at: index) { return true }
            // Clicking a wiki/markdown link follows it (Obsidian-style).
            if let onOpenLink, let text = textView?.string,
               let ref = LinkParser.links(in: text).first(where: { $0.range.lowerBound <= index && index < $0.range.upperBound }) {
                onOpenLink(ref.target)
                return true
            }
            if let region = widgetRegions.first(where: { $0.lowerBound <= index && index < $0.upperBound }),
               let textView {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: region.lowerBound, length: 0))
                return true
            }
            return false
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
            specs.append(contentsOf: hrWidgets(caret: caret, nstext: nstext))
            widgetRegions = specs.map(\.region)   // for click-to-reveal caret snapping

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

        /// Horizontal rules (`---` lines) drawn as real divider lines; the raw
        /// text reveals when the caret enters the line, like other widgets.
        func hrWidgets(caret: Range<Int>, nstext: NSString) -> [WidgetSpec] {
            var out: [WidgetSpec] = []
            for line in HRParser.lines(in: nstext as String) {
                if intersects(line, caret) { continue }
                let view = AnyView(
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(nsColor: .textBackgroundColor))
                )
                out.append(WidgetSpec(key: "hr-\(line.lowerBound)-\(line.upperBound)",
                                      region: line, view: view))
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

        // MARK: NSTextLayoutManagerDelegate — code blocks get a slab background.

        public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                                      textLayoutFragmentFor location: NSTextLocation,
                                      in textElement: NSTextElement) -> NSTextLayoutFragment {
            if let tcs = textLayoutManager.textContentManager as? NSTextContentStorage,
               let range = textElement.elementRange {
                let start = tcs.offset(from: tcs.documentRange.location, to: range.location)
                let end = tcs.offset(from: tcs.documentRange.location, to: range.endLocation)
                if let kind = markerLines[start] {
                    let f = MarkerFragment(textElement: textElement, range: textElement.elementRange)
                    f.kind = kind
                    return f
                }
                if let region = codeRegions.first(where: { $0.contains(start) }) {
                    let fragment = CodeBlockFragment(textElement: textElement, range: textElement.elementRange)
                    fragment.roundsTop = start <= region.lowerBound
                    fragment.roundsBottom = end >= region.upperBound
                    // Container width from the view bounds (reliable post-layout;
                    // the TLM's container can report 0 during the delegate call).
                    if let tv = textView {
                        let cw = textLayoutManager.textContainer?.size.width ?? 0
                        fragment.fillWidth = cw > 0 ? cw : tv.bounds.width - tv.textContainerInset.width * 2
                    }
                    return fragment
                }
            }
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            lastCaretParagraph = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
            refresh()
        }

        private var lastCaretParagraph: NSRange?

        public func textViewDidChangeSelection(_ notification: Notification) {
            // Marker reveal only depends on which line the caret is on — moving
            // within a line must not restyle the whole document (it re-laid out
            // everything and flickered).
            guard let textView else { return }
            let paragraph = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
            if paragraph == lastCaretParagraph { return }
            lastCaretParagraph = paragraph
            refresh()
        }
    }
}
