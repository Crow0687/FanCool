import AppKit
import SwiftUI
import OSLog
import FanCoolCore

/// Keep the native scroll surface transparent, including the scroller gutter.
struct TransparentScrollBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollBackgroundView { ScrollBackgroundView() }
    func updateNSView(_ view: ScrollBackgroundView, context: Context) { view.updateScrollSurface() }
}

final class ScrollBackgroundView: NSView {
    private weak var configuredScrollView: NSScrollView?
    private static let logger = Logger(subsystem: HelperIdentity.appIdentifier, category: "scroll-surface")
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateScrollSurface()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScrollSurface()
    }
    func updateScrollSurface() {
        // SwiftUI may attach the representable before its scroll-view ancestors.
        DispatchQueue.main.async { [weak self] in
            guard let self, let scrollView = self.enclosingScrollView else { return }
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.contentView.drawsBackground = false
            scrollView.contentView.backgroundColor = .clear
            scrollView.scrollerStyle = .overlay
            if self.configuredScrollView !== scrollView {
                self.configuredScrollView = scrollView
                Self.logger.notice("Transparent scroll surface overlay=\(scrollView.scrollerStyle == .overlay) background=\(scrollView.drawsBackground) clipBackground=\(scrollView.contentView.drawsBackground)")
            }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
