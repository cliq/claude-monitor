// App/UI/MenuBarController.swift
import AppKit
import Combine
import SwiftUI

final class MenuBarController {
    private let statusItem: NSStatusItem
    private let store: SessionStore
    private let onOpenDashboard: () -> Void
    private let onOpenSettings: () -> Void
    private var cancellable: AnyCancellable?

    init(store: SessionStore,
         onOpenDashboard: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.onOpenDashboard = onOpenDashboard
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureButton()
        buildMenu()

        cancellable = store.$orderedSessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in self?.refresh(sessions) }
        refresh(store.orderedSessions)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Claude Monitor")
        button.image?.isTemplate = false
    }

    private func buildMenu() {
        let menu = NSMenu()

        let dashboard = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashboard.target = self
        menu.addItem(dashboard)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Monitor",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func refresh(_ sessions: [Session]) {
        guard let button = statusItem.button else { return }
        let needsYou = sessions.filter { $0.state == .needsYou }.count
        let anyWaiting = sessions.contains { $0.state == .waiting }
        let anyWorking = sessions.contains { $0.state == .working }

        let color: NSColor
        if needsYou > 0      { color = NSColor(red: 0xEF/255, green: 0x44/255, blue: 0x44/255, alpha: 1) }
        else if anyWaiting   { color = NSColor(red: 0xF5/255, green: 0x9E/255, blue: 0x0B/255, alpha: 1) }
        else if anyWorking   { color = NSColor(red: 0x3B/255, green: 0x82/255, blue: 0xF6/255, alpha: 1) }
        else                 { color = NSColor(red: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1) }

        let size = CGSize(width: 16, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)).fill()
        img.unlockFocus()
        img.isTemplate = false
        button.image = img
        button.title = needsYou > 0 ? " \(needsYou)" : ""
    }

    @objc private func openDashboard() { onOpenDashboard() }
    @objc private func openSettings()  { onOpenSettings() }
}
