import AppKit
import SwiftUI

// Keep the content width fixed when a page starts or stops scrolling.
// This applies only to this settings scroll view, never to system preferences.
struct OverlayScrollbars: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollbarAnchor() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollbarAnchor)?.applyStyle()
    }
}

private final class ScrollbarAnchor: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyStyle() {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
    }
}
