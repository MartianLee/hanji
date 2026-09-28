import SwiftUI
import AppKit
import MarkdownCore

/// The `[[` suggestion list: a small borderless panel under the link being
/// typed. It never takes focus — the text view keeps the keyboard, and the
/// coordinator forwards ↑/↓, Return/Tab and Esc to it while it's open.
final class LinkCompletionPopup {
    final class Model: ObservableObject {
        @Published var items: [LinkCompletion.Suggestion] = []
        @Published var selected = 0
    }
    let model = Model()
    private var panel: NSPanel?
    /// Called when a row is clicked.
    var onPick: ((LinkCompletion.Suggestion) -> Void)?

    var isOpen: Bool { panel?.isVisible == true }
    var selection: LinkCompletion.Suggestion? { model.items[safe: model.selected] }

    static let rowHeight: CGFloat = 34
    static let width: CGFloat = 320

    /// Show `items` with the list's top-left at `origin` (screen coordinates,
    /// the bottom-left of the `[[`), attached to `parent`.
    func show(_ items: [LinkCompletion.Suggestion], below origin: NSPoint, in parent: NSWindow) {
        if items.map(\.path) != model.items.map(\.path) { model.selected = 0 }
        model.items = items
        let panel = self.panel ?? makePanel()
        let height = CGFloat(items.count) * Self.rowHeight + 8
        var frame = NSRect(x: origin.x, y: origin.y - height - 4, width: Self.width, height: height)
        // Keep it on screen: flip above the line when there's no room below.
        if let screen = parent.screen?.visibleFrame {
            if frame.minY < screen.minY { frame.origin.y = origin.y + 24 }
            frame.origin.x = min(frame.origin.x, screen.maxX - frame.width)
        }
        panel.setFrame(frame, display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selected = (model.selected + delta + model.items.count) % model.items.count
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        panel.contentView = NSHostingView(rootView: LinkCompletionList(model: model) { [weak self] in
            self?.onPick?($0)
        })
        self.panel = panel
        return panel
    }
}

private struct LinkCompletionList: View {
    @ObservedObject var model: LinkCompletionPopup.Model
    let pick: (LinkCompletion.Suggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.element.path) { i, item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).lineLimit(1)
                    if !item.folder.isEmpty {
                        Text(item.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: LinkCompletionPopup.rowHeight, alignment: .leading)
                .padding(.horizontal, 10)
                .background(i == model.selected ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { pick(item) }
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
