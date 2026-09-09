// App/UI/UsagePanelWindow.swift
import AppKit
import SwiftUI

/// Small titled window hosting `UsagePanelView`. Unlike the borderless
/// dashboard, a standard titled window is fine here: it's toggled on demand
/// from the menu bar and its size is fully driven by the SwiftUI content.
/// Position is persisted through `Preferences.usagePanelWindowFrame` rather
/// than `setFrameAutosaveName` — the floating panel's autosave entry was
/// written but never restored across relaunches.
@MainActor
final class UsagePanelWindow {
    private let window: NSPanel
    private let preferences: Preferences
    private var closeObserver: NSObjectProtocol?
    private var frameObservers: [NSObjectProtocol] = []
    private var needsFrameRestore = true
    /// Where the panel's top-left corner should stay. The panel isn't user-
    /// resizable, so every resize comes from SwiftUI content (accounts coming
    /// and going, the first layout after launch) — and AppKit keeps the
    /// bottom-left corner fixed through those, which would walk the title bar
    /// up and down the screen. Re-anchoring after each resize keeps it put.
    private var anchoredTopLeft: NSPoint?

    /// `onUserClose` fires when the user closes the panel with its close
    /// button — the owner uses it to flip `showUsagePanel` back off so the
    /// menu bar checkmark stays in sync. Programmatic `hide()` (orderOut)
    /// doesn't fire it.
    init(poller: UsagePoller, preferences: Preferences, onUserClose: @escaping () -> Void) {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Claude Usage"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // Utility panels hide whenever the app deactivates; the panel should
        // stay on screen like the dashboard for as long as the menu toggle is
        // on, across app switches, Spaces, and full-screen apps.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: UsagePanelView(poller: poller, preferences: preferences))
        self.window = panel
        self.preferences = preferences
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { _ in onUserClose() }
        observeFrameChanges()
    }

    deinit {
        let center = NotificationCenter.default
        if let observer = closeObserver { center.removeObserver(observer) }
        frameObservers.forEach { center.removeObserver($0) }
    }

    var isVisible: Bool { window.isVisible }

    func showAndBringToFront() {
        if needsFrameRestore {
            needsFrameRestore = false
            // Anchor by top-left: the panel's height follows its account list,
            // so a saved bottom-left origin would drift as accounts come and go.
            if let topLeft = Self.restoredTopLeft(saved: preferences.usagePanelWindowFrame,
                                                  screens: NSScreen.screens.map(\.frame)) {
                window.setFrameTopLeftPoint(topLeft)
            } else {
                window.center()
            }
            anchoredTopLeft = topLeft(of: window.frame)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Top-left corner to restore, or nil when nothing was saved or the saved
    /// frame's screen is no longer connected (then the panel is centered).
    nonisolated static func restoredTopLeft(saved: NSRect?, screens: [NSRect]) -> NSPoint? {
        guard let saved else { return nil }
        let center = NSPoint(x: saved.midX, y: saved.midY)
        guard screens.contains(where: { $0.contains(center) }) else { return nil }
        return NSPoint(x: saved.minX, y: saved.maxY)
    }

    private func topLeft(of frame: NSRect) -> NSPoint { NSPoint(x: frame.minX, y: frame.maxY) }

    /// Same rule as the dashboard: persist only user drags (mouse button held).
    /// AppKit also fires `didMove` for display changes and our own
    /// `setFrameTopLeftPoint`, which must not overwrite the chosen position.
    private func observeFrameChanges() {
        let center = NotificationCenter.default
        frameObservers = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                guard let self, NSEvent.pressedMouseButtons != 0 else { return }
                self.preferences.usagePanelWindowFrame = self.window.frame
                self.anchoredTopLeft = self.topLeft(of: self.window.frame)
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                guard let self, let anchor = self.anchoredTopLeft,
                      self.topLeft(of: self.window.frame) != anchor else { return }
                self.window.setFrameTopLeftPoint(anchor)
            },
        ]
    }

    func hide() { window.orderOut(nil) }
}
