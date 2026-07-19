// App/UI/UsagePanelWindow.swift
import AppKit
import SwiftUI

/// Small titled window hosting `UsagePanelView`. Unlike the borderless
/// dashboard, a standard titled window is fine here: it's opened on demand from
/// the menu bar and its size is fully driven by the SwiftUI content.
@MainActor
final class UsagePanelWindow {
    private let window: NSPanel

    init(poller: UsagePoller) {
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
    }

    func showAndBringToFront() {
        if window.frame.origin == .zero { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window.orderOut(nil) }
}
