import AppKit
import SwiftUI

/// A scroll view for a strip that only goes sideways, such as the tab bar.
/// A wheel turn or a swipe that is mostly up-and-down moves the strip sideways,
/// and the strip itself never moves up or down. SwiftUI's horizontal
/// `ScrollView` took the toolbar's and the sidebar's insets (52pt on top in the
/// detail column), so its content was taller than the 32pt bar and a vertical
/// scroll pushed the tab names up under the toolbar.
final class SidewaysScrollView: NSScrollView {
    /// Whether the scroll in progress is being turned sideways. A trackpad
    /// gesture decides this once, when it begins, and keeps the answer through
    /// its momentum, so a swipe doesn't flip between the two directions.
    /// A plain mouse wheel decides it on every click.
    private var turning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasHorizontalScroller = false
        hasVerticalScroller = false
        drawsBackground = false
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .automatic
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: sideways(event))
    }

    /// The event as the strip should scroll by it: a mostly vertical one with
    /// its vertical and horizontal amounts swapped, anything else unchanged.
    /// Down (or a swipe up) goes right, toward the later tabs.
    func sideways(_ event: NSEvent) -> NSEvent {
        let mostlyVertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            turning = mostlyVertical
        }
        guard turning, let cg = event.cgEvent?.copy() else { return event }
        // Setting one of these makes CoreGraphics recompute the others from it,
        // so read them all first, then write line, fixed-point, point, each
        // horizontal (axis 2) before vertical (axis 1). Other orders leave the
        // amounts rescaled, or the event still vertical.
        let lines = (cg.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                     cg.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let fixed = (cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                     cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        let points = (cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                      cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lines.0)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lines.1)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed.0)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed.1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: points.0)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: points.1)
        return NSEvent(cgEvent: cg) ?? event
    }
}

/// SwiftUI content laid out in a row inside a `SidewaysScrollView`: as wide as
/// it wants to be, exactly as tall as the strip.
struct SidewaysScroll<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> SidewaysScrollView {
        let scroll = SidewaysScrollView(frame: .zero)
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            host.topAnchor.constraint(equalTo: clip.topAnchor),
            host.heightAnchor.constraint(equalTo: clip.heightAnchor),
        ])
        return scroll
    }

    func updateNSView(_ scroll: SidewaysScrollView, context: Context) {
        (scroll.documentView as? NSHostingView<Content>)?.rootView = content
    }
}
