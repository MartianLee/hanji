import SwiftUI
import AppKit
import MarkdownCore
import ExtensionSDK

/// NSTextView that lets a callback handle a click (used for task checkboxes).
final class ClickableTextView: NSTextView {
    /// Readable line length: keep the text in a centred column this wide (nil:
    /// full width). The side insets follow the view's width.
    var maxLineWidth: CGFloat? { didSet { if oldValue != maxLineWidth { updateColumn() } } }
    /// Called when the column moves (resize, width change): overlays follow it.
    var onColumnChange: (() -> Void)?
    static let sideInset: CGFloat = 24

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateColumn()
    }

    private func updateColumn() {
        let side = maxLineWidth.map { max(Self.sideInset, (bounds.width - $0) / 2) } ?? Self.sideInset
        guard abs(textContainerInset.width - side) > 0.5 else { return }
        textContainerInset = NSSize(width: side, height: textContainerInset.height)
        onColumnChange?()
    }

    var onClick: ((Int) -> Bool)?
    var onBecameFirstResponder: (() -> Void)?
    var onResignedFirstResponder: (() -> Void)?
    /// Offered each key command (↑, Return, Esc, …) first; true means it was
    /// handled — the `[[` suggestion list uses it while it's open.
    var onCommand: ((Selector) -> Bool)?

    override func doCommand(by selector: Selector) {
        if onCommand?(selector) == true { return }
        super.doCommand(by: selector)
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onResignedFirstResponder?() }
        return ok
    }
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
    /// The slab's width: the whole code column (not just the glyph extent),
    /// read from the text container when drawing. A fragment can be created
    /// before the view has a width (a note's first layout) and is kept, not
    /// recreated, once it has one — a width fixed at creation stayed at 0 or
    /// below and the slab didn't show until the block was edited.
    var fillWidth: CGFloat {
        let live = textLayoutManager?.textContainer?.size.width ?? 0
        return live > 0 ? live : fallbackWidth
    }
    /// The delegate's estimate, for when the container can't tell yet.
    var fallbackWidth: CGFloat = 0
    /// Where the slab starts: 0 for a top-level block, the code's own indent
    /// for one nested in a list item (it sits under the item's text).
    @objc var slabInset: CGFloat = 0

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
        let rect = CGRect(x: -point.x + slabInset, y: 0, width: max(0, width - slabInset),
                          height: layoutFragmentFrame.height + extra)
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
    /// Body line height, as a multiple (Settings ▸ Appearance).
    public var lineHeight: CGFloat
    /// Readable line length: the text column's width, or nil for the full width.
    public var maxLineWidth: CGFloat?
    /// Text and code fonts, as `EditorFonts` choices ("" = the system's).
    public var textFont: String
    public var codeFont: String
    /// Notes a `[[` link can point at (vault-relative paths without `.md`),
    /// asked for when the suggestion list opens.
    public var linkTargets: (() -> [String])?
    /// Called when a wiki/markdown link is clicked, with the raw link target.
    public var onOpenLink: ((String) -> Void)?
    /// Called when a `#tag` is clicked, with the tag's name (no `#`).
    public var onOpenTag: ((String) -> Void)?
    /// Called when the editor text view becomes first responder (user clicks or tabs into it).
    public var onFocus: (() -> Void)?
    /// Called with the caret's offset whenever it moves (live editor only), so
    /// navigation history can come back to it.
    public var onCaretMove: ((Int) -> Void)?
    /// False when `text` is a snapshot rather than the live buffer (an inactive
    /// split pane). Such an editor can't save an edit, so a click only focuses it.
    public var isLive: Bool

    public init(text: Binding<String>, renderers: RendererRegistry? = nil, vaultRoot: URL? = nil,
                cursorOffset: Binding<Int?> = .constant(nil), fontSize: CGFloat = 15,
                lineHeight: CGFloat = 1.3, maxLineWidth: CGFloat? = nil,
                textFont: String = "", codeFont: String = "",
                linkTargets: (() -> [String])? = nil,
                onOpenLink: ((String) -> Void)? = nil,
                onFocus: (() -> Void)? = nil, isLive: Bool = true,
                onOpenTag: ((String) -> Void)? = nil,
                onCaretMove: ((Int) -> Void)? = nil) {
        self.onOpenTag = onOpenTag
        self.onCaretMove = onCaretMove
        self.isLive = isLive
        self._text = text
        self.renderers = renderers
        self.vaultRoot = vaultRoot
        self._cursorOffset = cursorOffset
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.maxLineWidth = maxLineWidth
        self.textFont = textFont
        self.codeFont = codeFont
        self.linkTargets = linkTargets
        self.onOpenLink = onOpenLink
        self.onFocus = onFocus
    }

    public func makeNSView(context: Context) -> NSScrollView {
        LivePreviewStyler.baseFontSize = fontSize
        LivePreviewStyler.lineHeightMultiple = lineHeight
        LivePreviewStyler.textFont = textFont
        LivePreviewStyler.codeFont = codeFont
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
        textView.textContainerInset = NSSize(width: ClickableTextView.sideInset, height: 20)
        textView.maxLineWidth = maxLineWidth
        textView.onColumnChange = { [weak coordinator = context.coordinator] in coordinator?.columnDidMove() }
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
        textView.onResignedFirstResponder = { [weak coordinator = context.coordinator] in coordinator?.closeLinkCompletion() }
        textView.onCommand = { [weak coordinator = context.coordinator] selector in
            coordinator?.handleLinkCompletionCommand(selector) ?? false
        }
        // The suggestion list follows its link when the note scrolls.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.clipViewDidScroll),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.refresh()
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.sync(with: self)
        if LivePreviewStyler.baseFontSize != fontSize || LivePreviewStyler.lineHeightMultiple != lineHeight
            || LivePreviewStyler.textFont != textFont || LivePreviewStyler.codeFont != codeFont {
            LivePreviewStyler.baseFontSize = fontSize
            LivePreviewStyler.lineHeightMultiple = lineHeight
            LivePreviewStyler.textFont = textFont
            LivePreviewStyler.codeFont = codeFont
            textView.font = LivePreviewStyler.baseFont
            context.coordinator.needsFullRestyle = true
            context.coordinator.refresh()
        }
        (textView as? ClickableTextView)?.maxLineWidth = maxLineWidth
        if textView.string != text {
            textView.string = text
            context.coordinator.needsFullRestyle = true
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

        deinit {
            NotificationCenter.default.removeObserver(self)
            linkPopup.close()
        }

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

        struct WidgetSpec {
            let key: String; let region: Range<Int>; let view: AnyView
            /// Tallest the widget may reserve; a table runs as long as it is.
            var maxHeight: CGFloat = 600
        }

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
        /// The text column moved (readable width, window resized): overlays are
        /// placed from its origin, so place them again.
        func columnDidMove() { scheduleWidgetUpdate() }

        private func settleLayoutBelowCaret() {
            // Not before the view is in a window: laying the note out at no width
            // is wasted work (and made fragments that kept that width).
            guard let tv = textView, tv.window != nil, let tlm = tv.textLayoutManager else { return }
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

        /// The text as of the last restyle, and the caret's paragraph then: what an
        /// edit or a caret move is measured against, to restyle only what it touched.
        private var styledText: NSString?
        private var styledCaretParagraph: NSRange?
        /// The code ranges as of the last restyle.
        private var styledCodeRanges: [Range<Int>] = []
        /// Restyle everything next time (first load, font size, text replaced).
        var needsFullRestyle = true
        /// Spans and code blocks, remembered per line (see TokenizerCache).
        private let tokenizer = TokenizerCache()

        /// Inline styling + caret-aware marker hiding (Live Preview) — for the
        /// paragraphs an edit or caret move touched, or the whole note when the
        /// change can reach past them (see `dirtyParagraphs`). Restyling every
        /// paragraph on every keystroke made typing in a long note slow: 135ms a key
        /// at 4,000 lines in a release build, nearly all of it re-applying and
        /// re-comparing attributes nothing had changed.
        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let text = NSString(string: storage.string)
            // Line-by-line cache: after an edit only changed lines are tokenized.
            let spans = tokenizer.spans(in: storage.string)
            let regions = tokenizer.codeBlockRegions
            codeRegions = tokenizer.codeRanges                            // unclosed fences too
            let sel = textView.selectedRange()
            let selection = sel.location..<(sel.location + sel.length)
            let deco = Decorator.decorations(spans: spans, selection: selection)
            let caretParagraph = text.paragraphRange(for: sel)
            let everything = NSRange(location: 0, length: text.length)
            let scopes = needsFullRestyle ? [everything]
                : dirtyParagraphs(in: text, caret: caretParagraph, regions: regions) ?? [everything]
            needsFullRestyle = false
            for scope in scopes where scope.length > 0 {
                restyle(scope, of: storage, text: text, deco: deco, regions: regions,
                        spans: spans, sel: sel, caret: selection)
            }
            markerLines = markerPlacements(spans: spans, sel: sel, text: text)
            styledText = text
            styledCaretParagraph = caretParagraph
            styledCodeRanges = codeRegions
            // The next line typed is body text until restyled: give it the body
            // metrics now (NSTextView otherwise carries whatever it picked up, e.g.
            // a rule's reserved height or no paragraph style at all).
            textView.typingAttributes = LivePreviewStyler.typingAttributes
        }

        /// Style one paragraph-aligned stretch on a copy and commit what changed
        /// (LivePreviewStyler.commit): rewriting unchanged ranges throws away their
        /// layout, and the viewport jumps as TextKit 2 falls back to estimated heights.
        private func restyle(_ scope: NSRange, of storage: NSTextStorage, text: NSString, deco: DecorationSet,
                             regions: [CodeBlockRegion], spans: [MarkSpan], sel: NSRange, caret: Range<Int>) {
            let range = scope.location..<NSMaxRange(scope)
            let local = NSTextStorage(attributedString: storage.attributedSubstring(from: scope))
            LivePreviewStyler.apply(deco.clipped(to: range), to: local)
            let inside = regions.filter { $0.full.lowerBound >= range.lowerBound && $0.full.upperBound <= range.upperBound }
                .map { r in CodeBlockRegion(language: r.language,
                                            body: (r.body.lowerBound - scope.location)..<(r.body.upperBound - scope.location),
                                            full: (r.full.lowerBound - scope.location)..<(r.full.upperBound - scope.location)) }
            LivePreviewStyler.highlightCode(inside, in: local)
            hideMarkers(spans: spans, sel: sel, text: text, in: local, offset: scope.location)
            reapplyReservations(in: local, text: text, caret: caret, offset: scope.location)
            LivePreviewStyler.commit(local, to: storage, at: scope.location)
        }

        /// Paragraph-aligned ranges of the current text that an edit or caret move
        /// since the last restyle touched: the changed paragraphs and the caret's
        /// old and new paragraphs (markers only show on the caret's line), widened
        /// to whole code blocks (highlighting runs over a block). nil when the change
        /// can restyle lines beyond those — a fence, a `---` line or a `>` line
        /// opens or closes a block that runs on — so the whole note is restyled.
        private func dirtyParagraphs(in text: NSString, caret: NSRange, regions: [CodeBlockRegion]) -> [NSRange]? {
            guard let old = styledText, let oldCaret = styledCaretParagraph else { return nil }
            let (oldChanged, newChanged) = Self.changedRanges(old, text)
            let edited = oldChanged.length > 0 || newChanged.length > 0
            var ranges = [caret]
            if edited {
                let oldParas = old.paragraphRange(for: oldChanged)
                let newParas = text.paragraphRange(for: newChanged)
                if Self.isStructural(old.substring(with: oldParas)) || Self.isStructural(text.substring(with: newParas)) {
                    return nil
                }
                // An edit can change what's code away from itself: taking a list
                // marker off turns the fence nested under it back into text.
                if Self.codeMovedBeyond(old: styledCodeRanges, new: codeRegions, oldEdit: oldParas, newEdit: newParas) {
                    return nil
                }
                ranges.append(newParas)
            }
            // The caret's old paragraph, carried through the edit (one overlapping
            // the edit is already inside the changed paragraphs).
            if NSMaxRange(oldCaret) <= oldChanged.location || !edited {
                ranges.append(oldCaret)
            } else if oldCaret.location >= NSMaxRange(oldChanged) {
                ranges.append(NSRange(location: oldCaret.location + text.length - old.length, length: oldCaret.length))
            }
            let widened = ranges.compactMap { r -> NSRange? in
                guard NSMaxRange(r) <= text.length else { return nil }
                var lo = r.location, hi = NSMaxRange(r)
                for region in regions where region.full.lowerBound <= hi && lo <= region.full.upperBound {
                    lo = min(lo, region.full.lowerBound); hi = max(hi, region.full.upperBound)
                }
                return text.paragraphRange(for: NSRange(location: lo, length: hi - lo))
            }.sorted { $0.location < $1.location }
            var merged: [NSRange] = []
            for r in widened {
                if let last = merged.last, r.location <= NSMaxRange(last) {
                    merged[merged.count - 1] = NSUnionRange(last, r)
                } else {
                    merged.append(r)
                }
            }
            return merged
        }

        /// Whether the code ranges clear of an edit differ before and after it
        /// (those after it shifted by the length change).
        static func codeMovedBeyond(old: [Range<Int>], new: [Range<Int>], oldEdit: NSRange, newEdit: NSRange) -> Bool {
            let delta = NSMaxRange(newEdit) - NSMaxRange(oldEdit)
            func clear(_ ranges: [Range<Int>], of edit: NSRange, shift: Int) -> [Range<Int>] {
                ranges.compactMap { r in
                    if r.upperBound < edit.location { return r }
                    if r.lowerBound > NSMaxRange(edit) { return (r.lowerBound + shift)..<(r.upperBound + shift) }
                    return nil
                }
            }
            return clear(old, of: oldEdit, shift: delta) != clear(new, of: newEdit, shift: 0)
        }

        /// Where two texts differ: the common prefix and suffix trimmed off, as a
        /// range in each.
        static func changedRanges(_ old: NSString, _ new: NSString) -> (old: NSRange, new: NSRange) {
            let oldLength = old.length, newLength = new.length
            var a = [unichar](repeating: 0, count: oldLength)
            var b = [unichar](repeating: 0, count: newLength)
            old.getCharacters(&a, range: NSRange(location: 0, length: oldLength))
            new.getCharacters(&b, range: NSRange(location: 0, length: newLength))
            let shorter = min(oldLength, newLength)
            var prefix = 0
            while prefix < shorter && a[prefix] == b[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < shorter - prefix && a[oldLength - 1 - suffix] == b[newLength - 1 - suffix] { suffix += 1 }
            return (NSRange(location: prefix, length: oldLength - suffix - prefix),
                    NSRange(location: prefix, length: newLength - suffix - prefix))
        }

        /// Lines whose change can restyle lines after them: fences (code runs on),
        /// `---` (frontmatter, or a rule), `>` (quotes and callouts run on).
        static func isStructural(_ lines: String) -> Bool {
            (lines as NSString).components(separatedBy: "\n").contains { raw in
                let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                // Any indent: a fence nested in a list item runs on too.
                return Fence.opening(line, inList: true) != nil || line.trimmingCharacters(in: .whitespaces) == "---"
                    || line.hasPrefix(">")
            }
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

        /// Put back the reservations inside `storage`, a stretch of `text` starting
        /// at `offset`.
        private func reapplyReservations(in storage: NSTextStorage, text: NSString, caret: Range<Int>, offset: Int) {
            guard !reservations.isEmpty else { return }
            for r in reservations {
                // A block the caret is inside shows its source instead of its widget.
                guard !intersects(r.region, caret),
                      r.region.lowerBound >= offset, r.region.upperBound <= offset + storage.length else { continue }
                let length = r.region.upperBound - r.region.lowerBound
                guard r.region.lowerBound + length <= text.length,
                      text.substring(with: NSRange(location: r.region.lowerBound, length: length)) == r.source
                else { continue }   // edited since: the widget pass re-measures it
                reserve(region: (r.region.lowerBound - offset)..<(r.region.upperBound - offset),
                        height: r.height, in: storage)
            }
        }

        /// Hide list/task marker glyphs (keeping width so clicks/toggles still map)
        /// inside one restyled stretch; `markerPlacements` records where the
        /// bullets/checkboxes are drawn. Caret-aware: the line being edited shows
        /// its raw `- [ ]` text.
        private func hideMarkers(spans: [MarkSpan], sel: NSRange, text: NSString, in storage: NSTextStorage, offset: Int) {
            let caretLine = text.paragraphRange(for: sel)
            let window = offset..<(offset + storage.length)
            // Writes land in `storage` (a stretch of `text` starting at `offset`).
            func collapse(_ loc: Int, _ len: Int) {
                guard len > 0, loc >= window.lowerBound, loc + len <= window.upperBound else { return }
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear],
                                      range: NSRange(location: loc - offset, length: len))
            }
            func clearGlyph(_ loc: Int, _ len: Int) {
                guard len > 0, loc >= window.lowerBound, loc + len <= window.upperBound else { return }
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: loc - offset, length: len))
            }
            for span in spans where span.line.lowerBound >= window.lowerBound && span.line.lowerBound < window.upperBound {
                guard !Self.onCaret(span.line, caretLine) else { continue }
                let m = Self.firstNonSpace(text, span.line.lowerBound, span.line.upperBound)
                switch span.style {
                case .listItem:
                    clearGlyph(m, 2)              // `- ` invisible (width kept); • drawn over it
                case .task:
                    collapse(m, 2)               // `- `
                    // Keep the width of the whole `[x]`, not just `[x`: the drawn box
                    // is narrower than those three glyphs, so the leftover — plus the
                    // trailing space — becomes the gap between the box and the label.
                    // Collapsing `]` (as before) left the text almost touching it.
                    clearGlyph(m + 2, 3)         // `[x]` kept width = click target; box drawn over
                default:
                    break
                }
            }
        }

        /// Where to draw a bullet or checkbox, for the whole note (lines off the
        /// caret; the caret's line shows its raw `- [ ]`).
        private func markerPlacements(spans: [MarkSpan], sel: NSRange, text: NSString) -> [Int: MarkerPlacement] {
            let caretLine = text.paragraphRange(for: sel)
            var marks: [Int: MarkerPlacement] = [:]
            for span in spans where !Self.onCaret(span.line, caretLine) {
                let m = Self.firstNonSpace(text, span.line.lowerBound, span.line.upperBound)
                switch span.style {
                case .listItem: marks[span.line.lowerBound] = MarkerPlacement(kind: .bullet, charIndex: m - span.line.lowerBound)
                case .task(let done): marks[span.line.lowerBound] = MarkerPlacement(kind: .task(done), charIndex: m - span.line.lowerBound)
                default: break
                }
            }
            return marks
        }

        private static func onCaret(_ line: Range<Int>, _ caretLine: NSRange) -> Bool {
            let r = NSRange(location: line.lowerBound, length: line.upperBound - line.lowerBound)
            return NSLocationInRange(line.lowerBound, caretLine) || NSIntersectionRange(r, caretLine).length > 0
        }

        private static func firstNonSpace(_ text: NSString, _ from: Int, _ upTo: Int) -> Int {
            var i = from
            while i < upTo, text.character(at: i) == 0x20 || text.character(at: i) == 0x09 { i += 1 }
            return i
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
                // The restyle just parsed this text; reuse its code blocks if unchanged.
                let unchanged = styledText.map { $0.isEqual(to: textView.string) } ?? false
                for region in unchanged ? tokenizer.codeBlockRegions : CodeBlockParser.regions(in: textView.string) {
                    guard let renderer = registry.renderer(for: region.language) else { continue }
                    if intersects(region.full, caret) { continue }
                    let body = region.bodyText(in: nstext)
                    specs.append(WidgetSpec(key: "cb-\(region.full.lowerBound)-\(region.full.upperBound)-\(region.language)",
                                            region: region.full, view: renderer.makeView(source: body)))
                }
            }
            specs.append(contentsOf: imageWidgets(caret: caret, nstext: nstext))
            specs.append(contentsOf: hrWidgets(caret: caret, nstext: nstext))
            let inset = textView.textContainerInset.width
            let width = max(50, textView.bounds.width - inset * 2)
            specs.append(contentsOf: tableWidgets(caret: caret, nstext: nstext, width: width))
            widgetRegions = specs.map(\.region)   // for click-to-reveal caret snapping

            var live: Set<String> = []
            var placements: [(region: Range<Int>, host: NSHostingView<AnyView>, h: CGFloat)] = []

            // Phase 1: host + measure (fittingSize) + reserve height in the text.
            for spec in specs {
                live.insert(spec.key)
                let host: NSHostingView<AnyView>
                if let existing = overlays[spec.key] { host = existing; host.rootView = spec.view }
                else { host = PassthroughHostingView(rootView: spec.view); textView.addSubview(host); overlays[spec.key] = host }
                host.frame.size.width = width
                let h = min(max(20, host.fittingSize.height), spec.maxHeight)
                reserve(region: spec.region, height: h, in: storage)
                placements.append((spec.region, host, h))
            }

            let before = reservations
            reservations = placements.compactMap { pl in
                let length = pl.region.upperBound - pl.region.lowerBound
                guard pl.region.lowerBound >= 0, pl.region.lowerBound + length <= nstext.length else { return nil }
                let source = nstext.substring(with: NSRange(location: pl.region.lowerBound, length: length))
                return (region: pl.region, height: pl.h, source: source)
            }
            // A widget that's gone (a rule edited away, a fence now running over it)
            // leaves its reserved, invisible styling on the text, and a restyle
            // limited to what was edited wouldn't reach it: restyle everything once.
            if before.contains(where: { old in !reservations.contains { $0.region == old.region && $0.source == old.source } }) {
                needsFullRestyle = true
                restyle()
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

        /// Pipe tables drawn as a grid; like other widgets, the source comes back
        /// while the caret is anywhere in the table.
        func tableWidgets(caret: Range<Int>, nstext: NSString, width: CGFloat) -> [WidgetSpec] {
            TableParser.tables(in: nstext as String).compactMap { table in
                if intersects(table.range, caret) { return nil }
                return WidgetSpec(key: "tbl-\(table.range.lowerBound)-\(table.range.upperBound)", region: table.range,
                                  view: AnyView(TableWidgetView(table: table, width: width)),
                                  maxHeight: .greatestFiniteMagnitude)
            }
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
            // The collapsed lines keep no paragraph spacing: body text's 6pt a line
            // left a gap under a table as tall as it had rows.
            if firstEnd + 1 < upper {
                storage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default,
                                     range: NSRange(location: firstEnd + 1, length: upper - firstEnd - 1))
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

        /// How far in a code block's slab starts: the x of its fence's first
        /// character when the fence is nested in a list item (indented 4+
        /// columns), else 0 — a top-level block's slab spans the column as before.
        private func slabInset(forBlockAt offset: Int) -> CGFloat {
            guard let text = textView?.string as NSString?, offset < text.length else { return 0 }
            var x: CGFloat = 0, columns = 0, i = offset
            let space = (" " as NSString).size(withAttributes: [.font: LivePreviewStyler.codeFont(ofSize: LivePreviewStyler.baseFontSize - 1)]).width
            let tabStop: CGFloat = 28   // NSParagraphStyle's default tab stops
            while i < text.length {
                let c = text.character(at: i)
                if c == 0x20 { x += space; columns += 1 }
                else if c == 0x09 { x = (floor(x / tabStop) + 1) * tabStop; columns = (columns / 4 + 1) * 4 }
                else { break }
                i += 1
            }
            return columns > 3 ? x : 0
        }

        /// Whether an offset falls inside a fenced code block (fences included).
        /// `codeRegions` is kept fresh by restyle().
        func isInCodeRegion(_ offset: Int) -> Bool {
            codeRegions.contains { $0.contains(offset) }
        }

        private func intersects(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
            a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
        }

        // MARK: [[ link completion

        private let linkPopup = LinkCompletionPopup()
        /// The link being completed, as of the last update.
        private var linkContext: LinkCompletion.Context?
        /// Where Esc put the list away: it stays away until the caret leaves
        /// that link.
        private var dismissedLinkStart: Int?

        /// Open, refresh or close the suggestion list for where the caret is now.
        func updateLinkCompletion() {
            guard let textView, parent.isLive, textView.window?.firstResponder === textView,
                  let targets = parent.linkTargets,
                  textView.selectedRange().length == 0,
                  let context = LinkCompletion.context(in: textView.string as NSString,
                                                       caret: textView.selectedRange().location),
                  !isInCodeRegion(context.queryRange.location)
            else { return closeLinkCompletion() }
            if dismissedLinkStart == context.queryRange.location { return closeLinkCompletion(keepDismissal: true) }
            let items = LinkCompletion.suggestions(for: context.query, notes: targets())
            guard !items.isEmpty, let window = textView.window else { return closeLinkCompletion() }
            linkContext = context
            linkPopup.onPick = { [weak self] in self?.acceptLink($0) }
            linkPopup.show(items, below: linkAnchor(context), in: window)
        }

        func closeLinkCompletion(keepDismissal: Bool = false) {
            linkContext = nil
            if !keepDismissal { dismissedLinkStart = nil }
            linkPopup.close()
        }

        /// Screen point under the `[[` the list hangs from.
        private func linkAnchor(_ context: LinkCompletion.Context) -> NSPoint {
            guard let textView else { return .zero }
            let start = NSRange(location: max(0, context.queryRange.location - 2), length: 0)
            let rect = textView.firstRect(forCharacterRange: start, actualRange: nil)
            return NSPoint(x: rect.minX, y: rect.minY)
        }

        @objc func clipViewDidScroll() {
            guard let linkContext, linkPopup.isOpen, let window = textView?.window else { return }
            linkPopup.show(linkPopup.model.items, below: linkAnchor(linkContext), in: window)
        }

        /// Keys while the list is open: ↑/↓ choose, Return/Tab take, Esc closes.
        func handleLinkCompletionCommand(_ selector: Selector) -> Bool {
            guard linkPopup.isOpen, let context = linkContext else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): linkPopup.move(1)
            case #selector(NSResponder.moveUp(_:)): linkPopup.move(-1)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                guard let pick = linkPopup.selection else { return false }
                acceptLink(pick)
            case #selector(NSResponder.cancelOperation(_:)):
                dismissedLinkStart = context.queryRange.location
                closeLinkCompletion(keepDismissal: true)
            default:
                return false
            }
            return true
        }

        /// Replace the link being typed with `suggestion`, as one undoable edit.
        private func acceptLink(_ suggestion: LinkCompletion.Suggestion) {
            guard let textView, let context = linkContext else { return }
            let edit = LinkCompletion.accept(suggestion, in: context)
            closeLinkCompletion()
            // Its own undo step, not merged into the typing around it.
            textView.breakUndoCoalescing()
            textView.insertText(edit.text, replacementRange: edit.range)
            textView.breakUndoCoalescing()
            textView.setSelectedRange(NSRange(location: edit.caret, length: 0))
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
                    fragment.slabInset = slabInset(forBlockAt: region.lowerBound)
                    // Container width from the view bounds (reliable post-layout;
                    // the TLM's container can report 0 during the delegate call).
                    if let tv = textView {
                        let cw = textLayoutManager.textContainer?.size.width ?? 0
                        fragment.fallbackWidth = cw > 0 ? cw : tv.bounds.width - tv.textContainerInset.width * 2
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
            guard !textView.hasMarkedText() else { updateLinkCompletion(); return }
            refresh()
            updateLinkCompletion()
        }

        private var lastCaretParagraph: NSRange?

        public func textViewDidChangeSelection(_ notification: Notification) {
            // Marker reveal only depends on which line the caret is on — moving
            // within a line must not restyle the whole document (it re-laid out
            // everything and flickered).
            guard let textView else { return }
            updateLinkCompletion()
            // Not mid-composition: the selection moves with every jamo, and a
            // restyle would pull the marked text out from under the input method.
            // Committing the composition sends textDidChange, which restyles.
            guard !textView.hasMarkedText() else { return }
            if parent.isLive { parent.onCaretMove?(textView.selectedRange().location) }
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
