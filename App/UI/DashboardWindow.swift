// App/UI/DashboardWindow.swift
import AppKit
import Combine
import SwiftUI

final class DashboardWindow {
    private let window: BorderlessFloatingWindow
    private let preferences: Preferences
    private var subscription: AnyCancellable?
    private var frameObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private let emptyStateSize = NSSize(width: 260, height: 120)
    private let maxHeightFraction: CGFloat = 0.8
    private let screenEdgeMargin: CGFloat = 20

    init<Content: View>(rootView: Content, store: SessionStore, preferences: Preferences) {
        // `FirstMouseHostingView` opts into first-mouse handling so a click on a tile
        // activates the target terminal in a single click — even when the dashboard
        // isn't the frontmost app. Dragging the empty background still moves the
        // window (background isn't a tap target) and dragging on a tile does nothing
        // (tile content is opaque-hit-testable, so `isMovableByWindowBackground`
        // doesn't fire there).
        let hostingView = FirstMouseHostingView(rootView: rootView)
        // Prevent the hosting view from resizing the window to match intrinsic
        // SwiftUI content size. Its auto-resize anchors the top-LEFT, which caused
        // the window to drift rightward every time a new card was added — even with
        // `resize()` re-anchoring the top-right moments later. All window sizing is
        // now driven exclusively by `DashboardWindow.resize(count:metrics:)`.
        hostingView.sizingOptions = []
        let hosting = NSViewController()
        hosting.view = hostingView
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
        observeScreenParameterChanges()
        observeWakeNotifications()

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
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
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

    /// Persist the frame only on genuine user drags. AppKit also fires `didMove`/
    /// `didResize` when displays connect/disconnect (it evacuates the window onto
    /// the surviving screen) and when we call `setFrame` programmatically. Persisting
    /// those would overwrite the user's intended position with main-screen
    /// coordinates and leave nothing to restore on wake. User drags fire while the
    /// mouse button is held; system/programmatic moves fire with no button pressed,
    /// so the pressed-buttons mask cleanly separates them.
    private func observeFrameChanges() {
        let center = NotificationCenter.default
        let record: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            guard NSEvent.pressedMouseButtons != 0 else { return }
            self.preferences.dashboardWindowFrame = self.window.frame
        }
        frameObservers = [
            center.addObserver(forName: NSWindow.didMoveNotification,
                               object: window, queue: .main, using: record),
            center.addObserver(forName: NSWindow.didResizeNotification,
                               object: window, queue: .main, using: record),
        ]
    }

    /// On display attach/detach, AppKit evacuates the window onto whichever screen
    /// survived. Snap back to the saved spot once the original screen returns (e.g.
    /// the secondary monitor reconnects after wake). The pressed-buttons filter in
    /// `observeFrameChanges` keeps the synthetic evacuation from corrupting the
    /// saved frame, so we always have a real position to restore to.
    private func observeScreenParameterChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restoreSavedFrameIfPossible()
        }
        frameObservers.append(observer)
    }

    /// On wake, AppKit may have already shoved the dashboard onto the main display
    /// — and `didChangeScreenParametersNotification` doesn't always fire (or fires
    /// before `NSScreen.screens` reflects the reconnected display). Retry the
    /// restore at staggered intervals because external monitors can take several
    /// seconds to renegotiate after wake.
    private func observeWakeNotifications() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let observer = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleWakeRestoreAttempts()
        }
        workspaceObservers = [observer]
    }

    private func scheduleWakeRestoreAttempts() {
        let delays: [TimeInterval] = [0, 0.5, 1.5, 3, 5, 8]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.restoreSavedFrameIfPossible()
            }
        }
    }

    private func restoreSavedFrameIfPossible() {
        guard let saved = preferences.dashboardWindowFrame else { return }
        let savedCenter = NSPoint(x: saved.midX, y: saved.midY)
        let savedScreenAvailable = NSScreen.screens.contains { $0.frame.contains(savedCenter) }
        guard savedScreenAvailable else { return }

        let currentSize = window.frame.size
        let rightX = saved.origin.x + saved.size.width
        let topY = saved.origin.y + saved.size.height
        let target = NSRect(
            origin: NSPoint(x: rightX - currentSize.width, y: topY - currentSize.height),
            size: currentSize
        )
        if window.frame != target {
            window.setFrame(target, display: window.isVisible, animate: false)
        }
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

/// Accept first-mouse so a click on a tile fires its tap gesture even when the
/// app is inactive — otherwise the first click is consumed by window activation
/// and the user has to click twice.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
