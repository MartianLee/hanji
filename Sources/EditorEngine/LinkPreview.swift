import AppKit
import SwiftUI
import MarkdownCore

/// The note a link points to, in a popover, once the pointer rests on the link
/// — with ⌘ held while editing, without in reading mode (as in Obsidian).
final class LinkPreviewController {
    static let delay: TimeInterval = 0.5
    /// How long the popover outlives the pointer leaving the link, so it can be
    /// reached.
    static let grace: TimeInterval = 0.3
    static let width: CGFloat = 360
    static let maxHeight: CGFloat = 320

    private weak var coordinator: MarkdownEditorView.Coordinator?
    private var popover: NSPopover?
    private var shownLink: Range<Int>?
    private var pending: (link: Range<Int>, work: DispatchWorkItem)?
    private var closing: DispatchWorkItem?
    /// The note's links, kept until the text changes (asked on every pointer move).
    private var links: (text: NSString, refs: [LinkRef])?

    init(coordinator: MarkdownEditorView.Coordinator) { self.coordinator = coordinator }

    var isShown: Bool { popover?.isShown == true }

    func hover(at offset: Int?, modifiers: NSEvent.ModifierFlags) {
        guard let coordinator, let textView = coordinator.textView else { return }
        let allowed = coordinator.parent.isReading || modifiers.contains(.command)
        guard allowed, let offset, let link = link(at: offset, in: textView.string as NSString) else {
            pending?.work.cancel(); pending = nil
            scheduleClose()
            return
        }
        closing?.cancel(); closing = nil
        if link.range == shownLink && isShown { return }
        if link.range == pending?.link { return }
        pending?.work.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pending = nil; self?.show(link) }
        pending = (link.range, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func close() {
        pending?.work.cancel(); pending = nil
        closing?.cancel(); closing = nil
        popover?.close()
        popover = nil
        shownLink = nil
    }

    private func link(at offset: Int, in text: NSString) -> LinkRef? {
        if links.map({ !$0.text.isEqual(to: text as String) }) ?? true {
            links = (text.copy() as! NSString, LinkParser.links(in: text as String))
        }
        return links?.refs.first { $0.range.lowerBound <= offset && offset < $0.range.upperBound }
    }

    private func show(_ link: LinkRef) {
        guard let coordinator, let textView = coordinator.textView, let window = textView.window,
              let preview = coordinator.parent.notePreview?(link.target) else { return }
        close()
        let source = (textView.string as NSString).substring(with: NSRange(location: link.range.lowerBound, length: link.range.count))
        let card = NoteCardView(title: preview.title, markdown: preview.text,
                                heading: NoteEmbeds.heading(inLink: source), width: Self.width, maxHeight: 10_000)
        let fitting = NSHostingController(rootView: card).view.fittingSize.height
        let height = min(max(60, fitting), Self.maxHeight)
        let content = NSHostingController(rootView: ScrollView { card }.frame(width: Self.width, height: height))
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentViewController = content
        popover.contentSize = NSSize(width: Self.width, height: height)
        let screen = textView.firstRect(forCharacterRange: NSRange(location: link.range.lowerBound, length: link.range.count),
                                        actualRange: nil)
        let anchor = textView.convert(window.convertFromScreen(screen), from: nil)
        popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
        self.popover = popover
        shownLink = link.range
    }

    private func scheduleClose() {
        guard isShown, closing == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closing = nil
            // Still on its way to (or inside) the popover: look again shortly.
            if let frame = self.popover?.contentViewController?.view.window?.frame,
               frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) {
                self.scheduleClose()
            } else {
                self.close()
            }
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: work)
    }
}
