// App/UI/DashboardWindow.swift
import AppKit
import Combine
import SwiftUI

final class DashboardWindow {
    private let window: BorderlessFloatingWindow
    private let preferences: Preferences
    private var subscription: AnyCancellable?
    private var frameObservers: [NSObjectProtocol] = []

    private let emptyStateSize = NSSize(width: 260, height: 120)
    private let maxHeightFraction: CGFloat = 0.8
    private let screenEdgeMargin: CGFloat = 20

    init<Content: View>(rootView: Content, store: SessionStore, preferences: Preferences) {
        let hosting = NSHostingController(rootView: rootView)
        // Prevent `NSHostingController` from resizing the window to match intrinsic
        // SwiftUI content size. Its auto-resize anchors the top-LEFT, which caused
        // the window to drift rightward every time a new card was added — even with
        // `resize()` re-anchoring the top-right moments later. All window sizing is
        // now driven exclusively by `DashboardWindow.resize(count:metrics:)`.
        hosting.sizingOptions = []
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
        self.window = window
        self.preferences = preferences

        // Initial frame: restore the saved top-right corner if it still lives on a
        // connected screen, otherwise default to the top-right of the main screen.
        let initialSize = desiredContentSize(
            count: store.orderedSessions.count,
            metrics: TileMetrics.resolve(preferences.tileSize)
        )
        let origin = initialOrigin(for: initialSize, saved: preferences.dashboardWindowFrame)
        window.setFrame(NSRect(origin: origin, size: initialSize), display: false, animate: false)

        observeFrameChanges()

        // React to either the session count or the tile-size preference changing.
        subscription = Publishers.CombineLatest(
            store.$orderedSessions.map(\.count).removeDuplicates(),
            preferences.$tileSize.removeDuplicates()
        )
        .sink { [weak self] count, size in
            self?.resize(count: count, metrics: TileMetrics.resolve(size))
        }
    }

    deinit {
        frameObservers.forEach { NotificationCenter.default.removeObserver($0) }
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

    private func resize(count: Int, metrics: TileMetrics) {
        let newSize = desiredContentSize(count: count, metrics: metrics)
        // Anchor the top-RIGHT corner so new cards grow down-and-to-the-left instead
        // of pushing the right edge outward. This matches the default top-right
        // positioning and keeps the window feeling stable when docked to that corner.
        let oldFrame = window.frame
        let rightX = oldFrame.origin.x + oldFrame.size.width
        let topY = oldFrame.origin.y + oldFrame.size.height
        let newOrigin = NSPoint(x: rightX - newSize.width, y: topY - newSize.height)
        window.setFrame(NSRect(origin: newOrigin, size: newSize),
                        display: window.isVisible, animate: false)
    }

    /// Restore the saved top-right corner if the saved frame's center still lives on a
    /// connected screen. Otherwise default to the top-right of the main screen's
    /// visible frame with a small margin.
    private func initialOrigin(for size: NSSize, saved: NSRect?) -> NSPoint {
        if let saved {
            let center = NSPoint(x: saved.midX, y: saved.midY)
            let onScreen = NSScreen.screens.contains { $0.frame.contains(center) }
            if onScreen {
                let rightX = saved.origin.x + saved.size.width
                let topY = saved.origin.y + saved.size.height
                return NSPoint(x: rightX - size.width, y: topY - size.height)
            }
        }
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.maxX - size.width - screenEdgeMargin,
                       y: screen.maxY - size.height - screenEdgeMargin)
    }

    /// Persist the current frame on user drag or any programmatic setFrame. The app is
    /// a singleton for the lifetime of the process, so these observers outlive deinit
    /// — but we clean them up anyway for hygiene and for tests that new up instances.
    private func observeFrameChanges() {
        let center = NotificationCenter.default
        let record: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            self.preferences.dashboardWindowFrame = self.window.frame
        }
        frameObservers = [
            center.addObserver(forName: NSWindow.didMoveNotification,
                               object: window, queue: .main, using: record),
            center.addObserver(forName: NSWindow.didResizeNotification,
                               object: window, queue: .main, using: record),
        ]
    }

    private func desiredContentSize(count: Int, metrics: TileMetrics) -> NSSize {
        guard count > 0 else { return emptyStateSize }
        let screenFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxHeight = screenFrame.height * maxHeightFraction
        let slot = metrics.tileSize.height + metrics.gutter
        let usable = maxHeight - 2 * metrics.padding + metrics.gutter
        let maxRows = max(1, Int(floor(usable / slot)))
        let rows = min(count, maxRows)
        let cols = Int(ceil(Double(count) / Double(rows)))
        let interTileWidth  = CGFloat(max(0, cols - 1)) * metrics.gutter
        let interTileHeight = CGFloat(max(0, rows - 1)) * metrics.gutter
        let width  = 2 * metrics.padding + CGFloat(cols) * metrics.tileSize.width  + interTileWidth
        let height = 2 * metrics.padding + CGFloat(rows) * metrics.tileSize.height + interTileHeight
        return NSSize(width: width, height: height)
    }
}

/// Borderless windows default to non-key/non-main, which suppresses click-to-focus
/// and keyboard events. We opt back in so tile taps and the menu-bar / settings
/// open paths work correctly.
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
