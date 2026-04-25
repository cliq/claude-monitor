// App/UI/MenuBarController.swift
import AppKit
import Combine
import SwiftUI

final class MenuBarController {
    private let statusItem: NSStatusItem
    private let store: SessionStore
    private let preferences: Preferences
    private let onSessionClick: (Session) -> Void
    private let onOpenDashboard: () -> Void
    private let onOpenSettings: () -> Void
    private var cancellable: AnyCancellable?

    init(store: SessionStore,
         preferences: Preferences,
         onSessionClick: @escaping (Session) -> Void,
         onOpenDashboard: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.preferences = preferences
        self.onSessionClick = onSessionClick
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

        // Pick the "winning" aggregate state (priority: needsYou > waiting >
        // working > idle) and reuse the shared per-state palette so the dot in
        // the status item matches the per-session dots in menu mode.
        let winning: SessionState
        if needsYou > 0    { winning = .needsYou }
        else if anyWaiting { winning = .waiting }
        else if anyWorking { winning = .working }
        else               { winning = .finished } // idle → gray
        let color = SessionStateColor.nsColor(for: winning)

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
