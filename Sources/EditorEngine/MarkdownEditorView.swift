import SwiftUI
import AppKit
import MarkdownCore
import ExtensionSDK

/// NSTextView that lets a callback handle a click (used for task checkboxes).
final class ClickableTextView: NSTextView {
    var onClick: ((Int) -> Bool)?
    var onBecameFirstResponder: (() -> Void)?
    /// Whether an offset sits inside a fenced code block, answered by the coordinator
    /// (which keeps the regions fresh). Inside a fence a line like `- name: foo` is
    /// code, not a list, so Return and Tab must behave as they do in any editor.
    var isInsideCodeBlock: ((Int) -> Bool)?
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

    /// Return inside a list continues it: the next line opens with the same marker,
    /// numbers incremented. Return on an *empty* item drops the marker instead of
    /// adding another one, which is how you leave a list. Everything goes through
    /// insertText, so each step stays a normal undoable edit.
    override func insertNewline(_ sender: Any?) {
        guard let line = listLine(),
              // Only continue from the end of the item's own text; a mid-line
              // Return splits the line as usual.
              selectedRange().location == line.range.location + line.range.length
        else { return super.insertNewline(sender) }
        switch ListContinuation.action(for: line.text) {
        case .none:
            super.insertNewline(sender)
        case .continue(let marker):
            insertText("\n" + marker, replacementRange: selectedRange())
        case .end(let markerLength):
            insertText("", replacementRange: NSRange(location: line.range.location, length: markerLength))
        }
    }

    /// Tab nests the list item the caret is in one level deeper — including the
    /// empty item Return just made, which is where you reach for Tab. Outside a
    /// list it stays an ordinary Tab. The caret keeps its place in the text, so
    /// indenting from mid-word doesn't move you.
    override func insertTab(_ sender: Any?) {
        guard let line = listLine(), let unit = ListIndent.indent(for: line.text) else {
            return super.insertTab(sender)
        }
        let caret = selectedRange().location
        insertText(unit, replacementRange: NSRange(location: line.range.location, length: 0))
        setSelectedRange(NSRange(location: caret + (unit as NSString).length, length: 0))
    }

    /// Shift-Tab pulls the item back out one level.
    override func insertBacktab(_ sender: Any?) {
        guard let line = listLine() else { return super.insertBacktab(sender) }
        // Already outermost: swallow it. Handing Shift-Tab back to NSTextView would
        // move focus to the previous key view, i.e. out of the editor entirely —
        // a surprising exit from a key the user now presses to outdent.
        guard let drop = ListIndent.outdent(for: line.text) else { return }
        let caret = selectedRange().location
        insertText("", replacementRange: NSRange(location: line.range.location, length: drop))
        setSelectedRange(NSRange(location: max(line.range.location, caret - drop), length: 0))
    }

    /// The caret's line when it is a list item that list editing owns — nil inside a
    /// fenced code block, where `- ` and `1. ` are just code.
    private func listLine() -> (range: NSRange, text: String)? {
        guard let line = caretLine(), ListIndent.isListItem(line.text),
              isInsideCodeBlock?(line.range.location) != true else { return nil }
        return line
    }

    /// The caret's line: its range in the storage (trailing newline excluded) and
    /// its text. nil when something is selected rather than a plain caret sitting
    /// in the text — list editing keys then fall back to their default behaviour.
    private func caretLine() -> (range: NSRange, text: String)? {
        guard let storage = textStorage else { return nil }
        let sel = selectedRange()
        guard sel.length == 0 else { return nil }
        let ns = storage.string as NSString
        let para = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        var length = para.length
        while length > 0 {
            let c = ns.character(at: para.location + length - 1)
            guard c == 0x0A || c == 0x0D else { break }
            length -= 1
        }
        let range = NSRange(location: para.location, length: length)
        return (range, ns.substring(with: range))
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
    /// Character offset of the raw marker within the line — non-zero for a nested
    /// item, whose `- ` sits after the indent. The glyph is drawn there, so a
    /// nested bullet steps right with its text instead of hugging the margin.
    var markerCharIndex: Int = 0

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)   // glyphs first (the marker glyphs are clear)
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        // Anchor the marker to the FIRST text line's box, not the whole rendering
        // surface. Right after Return splits this paragraph, the surface can
        // transiently span the empty line below, dropping `renderingSurfaceBounds.midY`
        // into the inter-line gap — the bullet/checkbox then appears to fall onto the
        // line below until the next relayout. The first line fragment's typographic
        // bounds stay on this line regardless of the surface height.
        let lineFragment = textLineFragments.first
        let b = lineFragment?.typographicBounds ?? renderingSurfaceBounds
        // Not b.midY: `lineHeightMultiple` makes the line box taller than the text
        // and hangs the extra leading *above* it, so the box centre sits well above
        // the glyphs and the marker reads as floating. Centre on the font metrics
        // measured from the first glyph's baseline instead — x-height for the dot
        // (it should sit in the middle of the lowercase text it labels), cap height
        // for the checkbox (it stands as tall as the letters).
        let font = LivePreviewStyler.baseFont
        let baseline = b.minY + (lineFragment?.glyphOrigin.y ?? b.height * 0.8)
        let x = b.minX + (lineFragment?.locationForCharacter(at: markerCharIndex).x ?? 0)
        switch kind {
        case .bullet:
            let r: CGFloat = 2.4
            let midY = baseline - font.xHeight / 2
            context.setFillColor(NSColor.secondaryLabelColor.cgColor)
            context.fillEllipse(in: CGRect(x: x + 3, y: midY - r, width: r * 2, height: r * 2))
        case .task(let done):
            let midY = baseline - font.capHeight / 2
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
    /// Called when a `#tag` is clicked, with the tag's name (no `#`).
    public var onOpenTag: ((String) -> Void)?
    /// Called when the editor text view becomes first responder (user clicks or tabs into it).
    public var onFocus: (() -> Void)?
    /// False when `text` is a snapshot rather than the live buffer (an inactive
    /// split pane). Such an editor can't save an edit, so a click only focuses it.
    public var isLive: Bool

    public init(text: Binding<String>, renderers: RendererRegistry? = nil, vaultRoot: URL? = nil,
                cursorOffset: Binding<Int?> = .constant(nil), fontSize: CGFloat = 15,
                onOpenLink: ((String) -> Void)? = nil,
                onFocus: (() -> Void)? = nil, isLive: Bool = true,
                onOpenTag: ((String) -> Void)? = nil) {
        self.onOpenTag = onOpenTag
        self.isLive = isLive
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
        // Markdown is plain text: `---` is a rule or frontmatter and `"` is a
        // quote, so the system's smart dashes/quotes (on by default) must not
        // rewrite what's typed.
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.font = LivePreviewStyler.baseFont
        textView.typingAttributes = LivePreviewStyler.typingAttributes
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // In-note find/replace (⌘F). The find bar is AppKit's own NSTextFinder UI,
        // hosted by the enclosing scroll view; its match highlight rides on
        // temporary attributes, so LivePreviewStyler's full-document restyle
        // doesn't wipe it.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.string = text

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
        context.coordinator.onOpenTag = onOpenTag
        context.coordinator.onFocus = onFocus
        textView.textLayoutManager?.delegate = context.coordinator
        textView.onClick = { [weak coordinator = context.coordinator] idx in
            coordinator?.handleClick(at: idx) ?? false
        }
        textView.isInsideCodeBlock = { [weak coordinator = context.coordinator] offset in
            coordinator?.isInCodeRegion(offset) ?? false
        }
        textView.onBecameFirstResponder = { [weak coordinator = context.coordinator] in coordinator?.onFocus?() }
        context.coordinator.refresh()
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.sync(with: self)
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
            context.coordinator.revealCaretAfterLayout()
            DispatchQueue.main.async { self.cursorOffset = nil }
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, NSTextViewDelegate, NSTextLayoutManagerDelegate {
        var parent: MarkdownEditorView
        public weak var textView: NSTextView?
        var renderers: RendererRegistry?
        var vaultRoot: URL?
        var onOpenLink: ((String) -> Void)?
        var onOpenTag: ((String) -> Void)?
        var onFocus: (() -> Void)?
        private var overlays: [String: NSHostingView<AnyView>] = [:]
        /// Full UTF-16 ranges (incl. fences) of fenced code blocks, kept fresh by
        /// restyle() for the layout-fragment background fill.
        private var codeRegions: [Range<Int>] = []
        /// UTF-16 ranges currently shown as rendered widgets (code renderers,
        /// images, HR), kept fresh by updateWidgets() so a click on one snaps the
        /// caret to the block start instead of a hit-test guess on collapsed text.
        private var widgetRegions: [Range<Int>] = []
        /// Where a line's marker goes: what to draw, and how far into the line the
        /// raw marker sits (past any indent, so nested items draw in the right place).
        struct MarkerPlacement { let kind: MarkerKind; let charIndex: Int }
        /// Paragraph-start offset → marker to draw (bullet/checkbox), caret-aware.
        private var markerLines: [Int: MarkerPlacement] = [:]

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
            super.init()
            // A block renderer (e.g. mermaid) reports its real height asynchronously;
            // re-measure and re-reserve when that happens.
            NotificationCenter.default.addObserver(self, selector: #selector(widgetDidResize),
                                                   name: .hanjiWidgetDidResize, object: nil)
            // ⌘Z / ⇧⌘Z change the text without a textDidChange reaching us, so the
            // note would keep the undone text (and a later update would put it back).
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoRedoDidChange(_:)),
                                                       name: name, object: nil)
            }
        }

        @objc private func undoRedoDidChange(_ notification: Notification) {
            guard let textView, parent.isLive,
                  let manager = notification.object as? UndoManager, manager === textView.undoManager,
                  textView.string != parent.text else { return }
            parent.text = textView.string
            // Restyle one runloop hop later, as for selection changes: AppKit is
            // still settling the caret after the undo.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        /// Take the latest values SwiftUI handed the view — `parent` included: it
        /// carries the text binding, which in split view changes as focus moves
        /// between panes. A stale one sends edits to another note's buffer.
        public func sync(with view: MarkdownEditorView) {
            parent = view
            renderers = view.renderers
            vaultRoot = view.vaultRoot
            onOpenLink = view.onOpenLink
            onOpenTag = view.onOpenTag
            onFocus = view.onFocus
        }

        @objc private func widgetDidResize() {
            DispatchQueue.main.async { [weak self] in self?.updateWidgets() }
        }

        struct WidgetSpec { let key: String; let region: Range<Int>; let view: AnyView }

        private var widgetUpdateScheduled = false
        /// Set by an edit or a jump: once the widget pass has laid the document
        /// out for real, bring the caret back into view. AppKit scrolls to the
        /// caret right away, while the lines around it may still be estimated —
        /// after a paste or a jump deep into a long note that left it off screen.
        /// Only after an edit or a jump, so scrolling away from the caret isn't undone.
        private var revealCaret = false

        func revealCaretAfterLayout() {
            revealCaret = true
            scheduleWidgetUpdate()
        }

        func refresh() {
            restyle()
            settleLayoutBelowCaret()
            scheduleWidgetUpdate()
        }

        /// Lay out from the caret's line to the end now, not in the deferred widget
        /// pass. Until then the lines below are measured provisionally, so the
        /// document height AppKit sizes and scrolls against right after a keystroke
        /// is a few points off from the real one — typing at the end of a note
        /// (pinned to its bottom edge) scrolled down on Return and back up on the
        /// next key, shaking the lines at the bottom. Restyles only invalidate what
        /// changed (LivePreviewStyler.commit), so this re-lays out a few lines.
        private func settleLayoutBelowCaret() {
            guard let tlm = textView?.textLayoutManager else { return }
            tlm.ensureLayout(for: tlm.documentRange)
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
            codeRegions = CodeBlockParser.codeRanges(in: storage.string)   // unclosed fences too
            let spans = InlineTokenizer.spans(in: storage.string)
            let sel = textView.selectedRange()
            let selection = sel.location..<(sel.location + sel.length)
            let deco = Decorator.decorations(spans: spans, selection: selection)
            // Style a copy and commit only what changed (see LivePreviewStyler.commit):
            // rewriting unchanged ranges throws away their layout, and the viewport
            // jumps as TextKit 2 falls back to estimated heights.
            let styled = NSTextStorage(attributedString: storage)
            LivePreviewStyler.apply(deco, to: styled)
            LivePreviewStyler.highlightCode(regions, in: styled)
            applyMarkers(spans: spans, sel: sel, storage: styled)
            reapplyReservations(in: styled, caret: selection)
            LivePreviewStyler.commit(styled, to: storage)
            // The next line typed is body text until restyled: give it the body
            // metrics now (NSTextView otherwise carries whatever it picked up, e.g.
            // a rule's reserved height or no paragraph style at all).
            textView.typingAttributes = LivePreviewStyler.typingAttributes
        }

        /// Heights the widget pass is holding open, so a restyle can put them back.
        /// LivePreviewStyler.apply resets attributes across the whole document, which
        /// wipes them — the document collapses by however much the widgets were
        /// holding open, and the next widget pass re-opens it. Every caret move
        /// bounced the layout that way, throwing whatever sits below a widget (the
        /// caret included) around the viewport.
        /// Each entry carries the source it was measured from, so a reservation is
        /// only put back while that exact text is still sitting at that offset. A
        /// document-length check is not enough: replacing `---` with `abc` keeps the
        /// length and would hold a rule's height open over ordinary prose until the
        /// widget pass caught up.
        private var reservations: [(region: Range<Int>, height: CGFloat, source: String)] = []

        private func reapplyReservations(in storage: NSTextStorage, caret: Range<Int>) {
            guard !reservations.isEmpty else { return }
            let ns = storage.string as NSString
            for r in reservations {
                // A block the caret is inside shows its source instead of its widget.
                guard !intersects(r.region, caret) else { continue }
                let length = r.region.upperBound - r.region.lowerBound
                guard r.region.lowerBound >= 0, r.region.lowerBound + length <= ns.length,
                      ns.substring(with: NSRange(location: r.region.lowerBound, length: length)) == r.source
                else { continue }   // edited since: the widget pass re-measures it
                reserve(region: r.region, height: r.height, in: storage)
            }
        }

        /// Hide list/task marker glyphs (keeping width so clicks/toggles still map)
        /// and record which lines should draw a bullet/checkbox. Caret-aware: the
        /// line being edited shows its raw `- [ ]` text.
        private func applyMarkers(spans: [MarkSpan], sel: NSRange, storage: NSTextStorage) {
            let ns = storage.string as NSString
            let caretLine = ns.paragraphRange(for: sel)
            var marks: [Int: MarkerPlacement] = [:]
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
                    marks[span.line.lowerBound] = MarkerPlacement(kind: .bullet,
                                                                  charIndex: m - span.line.lowerBound)
                case .task(let done):
                    guard !onCaret(span.line) else { continue }
                    let m = firstNonSpace(span.line.lowerBound, span.line.upperBound)
                    collapse(m, 2)               // `- `
                    // Keep the width of the whole `[x]`, not just `[x`: the drawn box
                    // is narrower than those three glyphs, so the leftover — plus the
                    // trailing space — becomes the gap between the box and the label.
                    // Collapsing `]` (as before) left the text almost touching it.
                    clearGlyph(m + 2, 3)         // `[x]` kept width = click target; box drawn over
                    marks[span.line.lowerBound] = MarkerPlacement(kind: .task(done),
                                                                  charIndex: m - span.line.lowerBound)
                default:
                    break
                }
            }
            markerLines = marks
        }

        /// Toggle a task checkbox if the click landed on one. Returns true if handled.
        /// Inside a fenced code block `- [ ]` is code, so it doesn't toggle. The
        /// toggle goes through the text view's edit path, so ⌘Z takes it back and
        /// textDidChange carries it to the note.
        func toggleCheckbox(at index: Int) -> Bool {
            guard parent.isLive, let textView else { return false }
            let text = textView.string
            guard let t = TaskToggle.toggle(in: text, at: index),
                  !CodeBlockParser.codeRanges(in: text).contains(where: { $0.contains(t.offset) })
            else { return false }
            let range = NSRange(location: t.offset, length: 1)
            guard textView.shouldChangeText(in: range, replacementString: t.replacement) else { return false }
            textView.textStorage?.replaceCharacters(in: range, with: t.replacement)
            textView.didChangeText()
            return true
        }

        /// Handle a mouse click before NSTextView's default caret placement.
        /// Checkbox toggles win first; a click on a rendered widget snaps the
        /// caret to the block's first line (so revealing the source is
        /// predictable, not a hit-test guess against the collapsed text behind
        /// the overlay). Returns true when handled (skip the default placement).
        public func handleClick(at index: Int) -> Bool {
            if toggleCheckbox(at: index) { return true }
            // Clicking a #tag searches for it.
            if let onOpenTag, let text = textView?.string,
               let tag = Tags.occurrences(in: text).first(where: { $0.range.contains(index) }) {
                onOpenTag(tag.name)
                return true
            }
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

            reservations = placements.compactMap { pl in
                let length = pl.region.upperBound - pl.region.lowerBound
                guard pl.region.lowerBound >= 0, pl.region.lowerBound + length <= nstext.length else { return nil }
                let source = nstext.substring(with: NSRange(location: pl.region.lowerBound, length: length))
                return (region: pl.region, height: pl.h, source: source)
            }

            // Phase 2: re-layout (heights changed), then position each overlay. The
            // full-document ensureLayout also settles the caret's own line, so don't
            // skip it when there is nothing to place — without it the insertion point
            // is left unpainted after a restyle.
            tlm.ensureLayout(for: tcs.documentRange)
            if revealCaret {
                revealCaret = false
                textView.scrollRangeToVisible(textView.selectedRange())
            }
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

        /// Whether an offset falls inside a fenced code block (fences included).
        /// `codeRegions` is kept fresh by restyle().
        func isInCodeRegion(_ offset: Int) -> Bool {
            codeRegions.contains { $0.contains(offset) }
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
                if let placement = markerLines[start] {
                    let f = MarkerFragment(textElement: textElement, range: textElement.elementRange)
                    f.kind = placement.kind
                    f.markerCharIndex = placement.charIndex
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
            revealCaret = true
            lastCaretParagraph = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
            // Never while an input method is still composing. refresh() rewrites the
            // storage's attributes across the whole document — marked text included —
            // which pulls the composition out from under the IME: typing Hangul, every
            // jamo gets re-styled mid-composition and the text jumps and flickers.
            // Committing the composition sends another textDidChange, and that one
            // styles the finished text.
            guard !textView.hasMarkedText() else { return }
            refresh()
        }

        private var lastCaretParagraph: NSRange?

        public func textViewDidChangeSelection(_ notification: Notification) {
            // Marker reveal only depends on which line the caret is on — moving
            // within a line must not restyle the whole document (it re-laid out
            // everything and flickered).
            guard let textView else { return }
            // Not mid-composition: the selection moves with every jamo, and a
            // restyle would pull the marked text out from under the input method.
            // Committing the composition sends textDidChange, which restyles.
            guard !textView.hasMarkedText() else { return }
            let paragraph = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
            if paragraph == lastCaretParagraph { return }
            lastCaretParagraph = paragraph
            // Off this callback rather than inside it. refresh() rewrites the text
            // storage's attributes, and mutating the storage while AppKit is still
            // settling the new selection leaves the insertion point erased and never
            // repainted: arrowing up through a note made the caret vanish for good
            // (it stayed gone until some other edit brought it back, while arrowing
            // down happened to survive). One runloop hop later the storage edit lands
            // after AppKit has finished with the caret, and the marker reveal still
            // arrives in the same frame.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textView?.hasMarkedText() != true else { return }
                self.refresh()
            }
        }
    }
}
