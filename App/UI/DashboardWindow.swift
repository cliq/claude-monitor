// App/UI/DashboardWindow.swift
import AppKit
import Combine
import SwiftUI

final class DashboardWindow {
    private let window: BorderlessFloatingWindow
    private let preferences: Preferences
    private var subscription: AnyCancellable?
    private var levelSubscription: AnyCancellable?
    private var frameObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private let emptyStateSize = NSSize(width: 260, height: 120)
    private let screenEdgeMargin: CGFloat = 20
    /// A column never grows past this share of its screen's visible height.
    static let maxHeightFraction: CGFloat = 0.8
    /// A column wraps before a tile that would sit at least this share of its
    /// height below the screen's visible bottom.
    static let maxOffscreenFraction: CGFloat = 0.4

    /// The last values `resize` laid out, so moves can re-flow the same tiles.
    private var lastCount: Int
    private var lastMetrics: TileMetrics
    private var reflowWorkItem: DispatchWorkItem?

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
        window.level = preferences.windowsFloatOnTop ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        self.window = window
        self.preferences = preferences
        self.lastCount = store.visibleSessions.count
        self.lastMetrics = TileMetrics.resolve(preferences.tileSize)

        // Initial frame: restore the saved top-right corner if it still lives on a
        // connected screen, otherwise default to the top-right of the main screen.
        window.setFrame(frame(count: lastCount, metrics: lastMetrics,
                              topRight: initialTopRight(saved: preferences.dashboardWindowFrame)),
                        display: false, animate: false)
        // From here on, only `resize`/`restoreSavedFrameIfPossible` may change the
        // window's size — see `BorderlessFloatingWindow.isSizeLocked`.
        window.isSizeLocked = true

        observeFrameChanges()
        observeScreenParameterChanges()
        observeWakeNotifications()

        // React to the visible session count (ignored sessions excluded — the grid
        // renders `visibleSessions`, so sizing on `orderedSessions` would leave an
        // empty slot per ignored session) or the tile-size preference changing.
        // The filter is inlined instead of reading `store.visibleSessions` in the
        // sink because @Published emits before the property is updated.
        let visibleCount = Publishers.CombineLatest(store.$orderedSessions, store.$ignoredSessionIds)
            .map { sessions, ignored in sessions.filter { !ignored.contains($0.id) }.count }
            .removeDuplicates()
        subscription = Publishers.CombineLatest(
            visibleCount,
            preferences.$tileSize.removeDuplicates()
        )
        .sink { [weak self] count, size in
            self?.resize(count: count, metrics: TileMetrics.resolve(size))
        }
        levelSubscription = preferences.$windowsFloatOnTop
            .removeDuplicates()
            .sink { [weak window] floats in
                window?.level = floats ? .floating : .normal
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
        lastCount = count
        lastMetrics = metrics
        // Anchor the top-RIGHT corner so new cards grow down-and-to-the-left instead
        // of pushing the right edge outward. This matches the default top-right
        // positioning and keeps the window feeling stable when docked to that corner.
        let target = frame(count: count, metrics: metrics,
                           topRight: NSPoint(x: window.frame.maxX, y: window.frame.maxY))
        if window.frame != target {
            window.setFrameAuthorized(target, display: window.isVisible)
        }
    }

    /// Restore the saved top-right corner if the saved frame's center still lives on a
    /// connected screen. Otherwise default to the top-right of the main screen's
    /// visible frame with a small margin.
    private func initialTopRight(saved: NSRect?) -> NSPoint {
        if let saved {
            let center = NSPoint(x: saved.midX, y: saved.midY)
            let onScreen = NSScreen.screens.contains { $0.frame.contains(center) }
            if onScreen {
                return NSPoint(x: saved.maxX, y: saved.maxY)
            }
        }
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.maxX - screenEdgeMargin, y: screen.maxY - screenEdgeMargin)
    }

    /// The frame for `count` tiles hanging from `topRight`, sized for the screen
    /// under that corner.
    private func frame(count: Int, metrics: TileMetrics, topRight: NSPoint) -> NSRect {
        let size: NSSize
        if count > 0 {
            let screenFrame = screen(under: topRight)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            size = Self.contentSize(count: count, metrics: metrics,
                                    screenHeight: screenFrame.height,
                                    spaceBelowTop: topRight.y - screenFrame.minY)
        } else {
            size = emptyStateSize
        }
        return NSRect(origin: NSPoint(x: topRight.x - size.width, y: topRight.y - size.height),
                      size: size)
    }

    /// The screen the window hangs from. Sizing against `window.screen` (whichever
    /// screen holds most of the window) or the main screen would measure a column
    /// against a display the window doesn't start on.
    private func screen(under topRight: NSPoint) -> NSScreen? {
        let inside = NSPoint(x: topRight.x - 1, y: topRight.y - 1)
        return NSScreen.screens.first { $0.frame.contains(inside) }
            ?? window.screen
            ?? NSScreen.main
    }

    /// Re-flow the tiles once the user stops dragging: the space below the
    /// window's top edge decides how many rows a column holds.
    private func scheduleReflow() {
        reflowWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard NSEvent.pressedMouseButtons == 0 else {
                self.scheduleReflow()  // still dragging
                return
            }
            self.resize(count: self.lastCount, metrics: self.lastMetrics)
            // The drag saved the pre-reflow frame; resize notifications arrive with
            // no button pressed, so `observeFrameChanges` won't record this one.
            // A stale size moves the saved center, which launch and wake restores
            // check against the connected screens.
            self.preferences.dashboardWindowFrame = self.window.frame
        }
        reflowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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
            self.scheduleReflow()
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

        // The returning screen may be a different height, so re-size as well as move.
        let target = frame(count: lastCount, metrics: lastMetrics,
                           topRight: NSPoint(x: saved.maxX, y: saved.maxY))
        if window.frame != target {
            window.setFrameAuthorized(target, display: window.isVisible)
        }
    }

    /// Window size for `count` tiles flowing column-major. A column holds as many
    /// rows as fit in `maxHeightFraction` of the screen, but wraps before a tile
    /// that would be `maxOffscreenFraction` or more below the screen's visible
    /// bottom — a window hanging from low on the screen starts a new column
    /// instead of hiding its last cards. `spaceBelowTop` is the distance from the
    /// window's top edge down to that visible bottom.
    static func contentSize(count: Int, metrics: TileMetrics,
                            screenHeight: CGFloat, spaceBelowTop: CGFloat) -> NSSize {
        let tileHeight = metrics.tileSize.height
        let slot = tileHeight + metrics.gutter
        let usable = screenHeight * maxHeightFraction - 2 * metrics.padding + metrics.gutter
        let maxRows = max(1, Int(floor(usable / slot)))
        // Row i spans `padding + i * slot` to that plus `tileHeight` below the top; it
        // stays while less than `maxOffscreenFraction` of it is past the bottom.
        let lastVisibleTop = spaceBelowTop - metrics.padding - (1 - maxOffscreenFraction) * tileHeight
        let rowsOnScreen = lastVisibleTop > 0
            ? Int(ceil(min(lastVisibleTop / slot, CGFloat(count))))
            : 0
        let rows = max(1, min(count, maxRows, rowsOnScreen))
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

    /// On macOS 26 (Tahoe), `NSHostingView.windowDidLayout` calls its private
    /// `updateAnimatedWindowSize` and resizes the hosting window to SwiftUI's
    /// ideal content size even when `sizingOptions` is empty — pre-Tahoe, the
    /// empty option set disabled all hosting-driven window sizing. That fires
    /// milliseconds after every `DashboardWindow.resize` and shrinks the window
    /// (e.g. a 220×124 single-tile frame down to 220×98), clipping the tiles.
    /// All sizing is owned by `DashboardWindow`, so once it arms this lock,
    /// frame changes that alter the *size* are dropped unless they come through
    /// `setFrameAuthorized`. Origin-only changes (user drags, screen-change
    /// evacuations) always pass.
    var isSizeLocked = false

    func setFrameAuthorized(_ frameRect: NSRect, display: Bool) {
        let wasLocked = isSizeLocked
        isSizeLocked = false
        defer { isSizeLocked = wasLocked }
        setFrame(frameRect, display: display, animate: false)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard !isSizeLocked || frameRect.size == frame.size else { return }
        super.setFrame(frameRect, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        guard !isSizeLocked || frameRect.size == frame.size else { return }
        super.setFrame(frameRect, display: displayFlag, animate: animateFlag)
    }

    /// Pass programmatic frames through unchanged. Default `NSWindow` clamps the
    /// frame to the screen's visible area; when we grow the window to fit a new
    /// card, that clamp silently shifts the window up. On the next add we'd read
    /// the shifted frame as the new anchor and drift further, making the window
    /// appear to walk across the screen. HUD-style windows disable this.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
