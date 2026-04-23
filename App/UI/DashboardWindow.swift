// App/UI/DashboardWindow.swift
import AppKit
import Combine
import SwiftUI

final class DashboardWindow {
    private let window: BorderlessFloatingWindow
    private var subscription: AnyCancellable?

    // Must match VerticalFirstGridLayout defaults so the window frames the tiles exactly.
    private let tileSize = CGSize(width: 160, height: 80)
    private let gutter: CGFloat = 8
    private let padding: CGFloat = 8
    private let emptyStateSize = NSSize(width: 260, height: 120)
    private let maxHeightFraction: CGFloat = 0.8

    init<Content: View>(rootView: Content, store: SessionStore) {
        let hosting = NSHostingController(rootView: rootView)
        let window = BorderlessFloatingWindow(contentViewController: hosting)
        // Borderless only — no `.resizable`, because on a borderless window edge-area
        // mouseDowns would start a resize drag that shrinks height and collapses the grid
        // to a single horizontal row. We size the window programmatically instead.
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Preferences.windowFrameAutosaveName)
        self.window = window

        resize(toFit: store.orderedSessions.count)
        subscription = store.$orderedSessions
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in self?.resize(toFit: count) }
    }

    func showAndBringToFront() {
        if !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window.orderOut(nil) }

    var isVisible: Bool { window.isVisible }

    private func resize(toFit sessionCount: Int) {
        let newSize = desiredContentSize(forSessionCount: sessionCount)
        // Anchor the top-left so the window grows down/right instead of jumping.
        let oldFrame = window.frame
        let topY = oldFrame.origin.y + oldFrame.size.height
        let newOrigin = NSPoint(x: oldFrame.origin.x, y: topY - newSize.height)
        window.setFrame(NSRect(origin: newOrigin, size: newSize),
                        display: window.isVisible, animate: false)
    }

    private func desiredContentSize(forSessionCount count: Int) -> NSSize {
        guard count > 0 else { return emptyStateSize }
        let screenFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxHeight = screenFrame.height * maxHeightFraction
        let slot = tileSize.height + gutter
        let maxRows = max(1, Int(floor((maxHeight - 2 * padding + gutter) / slot)))
        let rows = min(count, maxRows)
        let cols = Int(ceil(Double(count) / Double(rows)))
        let width = 2 * padding + CGFloat(cols) * tileSize.width + CGFloat(max(0, cols - 1)) * gutter
        let height = 2 * padding + CGFloat(rows) * tileSize.height + CGFloat(max(0, rows - 1)) * gutter
        return NSSize(width: width, height: height)
    }
}

/// Borderless windows default to non-key/non-main, which suppresses drag-and-drop
/// and keyboard focus. We need both (tile reordering via drag).
final class BorderlessFloatingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Pass programmatic frames through unchanged. Default `NSWindow` clamps the
    /// frame to the screen's visible area; when we grow the window to fit a new
    /// card, that clamp silently shifts the window up. On the next add we'd read
    /// the shifted frame as the new anchor and drift further, making the window
    /// appear to walk across the screen. HUD-style windows disable this.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
