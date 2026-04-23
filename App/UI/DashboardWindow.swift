// App/UI/DashboardWindow.swift
import AppKit
import SwiftUI

final class DashboardWindow {
    private let window: NSWindow

    init<Content: View>(rootView: Content) {
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Claude Monitor"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setFrameAutosaveName(Preferences.windowFrameAutosaveName)
        window.isReleasedWhenClosed = false
        window.level = .normal
        self.window = window
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
}
