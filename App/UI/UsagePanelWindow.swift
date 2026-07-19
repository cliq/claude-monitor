// App/UI/UsagePanelWindow.swift
import AppKit
import SwiftUI

/// Small titled window hosting `UsagePanelView`. Unlike the borderless
/// dashboard, a standard titled window is fine here: it's toggled on demand
/// from the menu bar and its size is fully driven by the SwiftUI content.
@MainActor
final class UsagePanelWindow {
    private let window: NSPanel
    private var closeObserver: NSObjectProtocol?

    /// `onUserClose` fires when the user closes the panel with its close
    /// button — the owner uses it to flip `showUsagePanel` back off so the
    /// menu bar checkmark stays in sync. Programmatic `hide()` (orderOut)
    /// doesn't fire it.
    init(poller: UsagePoller, onUserClose: @escaping () -> Void) {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Claude Usage"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentViewController = NSHostingController(rootView: UsagePanelView(poller: poller))
        panel.setFrameAutosaveName("UsagePanelWindow")
        self.window = panel
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { _ in onUserClose() }
    }

    deinit {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isVisible: Bool { window.isVisible }

    func showAndBringToFront() {
        if window.frame.origin == .zero { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window.orderOut(nil) }
}
