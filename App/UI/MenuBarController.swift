// App/UI/MenuBarController.swift
import AppKit
import Combine
import SwiftUI

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
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
        super.init()

        configureButton()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()

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

    private func rebuildMenu() {
        menu.removeAllItems()

        if preferences.showDashboardWindow {
            let openItem = NSMenuItem(title: "Open Dashboard",
                                      action: #selector(openDashboard),
                                      keyEquivalent: "d")
            openItem.target = self
            menu.addItem(openItem)
        } else {
            appendSessionRows(into: menu)
        }

        let toggle = NSMenuItem(title: "Show Dashboard Window",
                                action: #selector(toggleDashboardWindow),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = preferences.showDashboardWindow ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Monitor",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func appendSessionRows(into menu: NSMenu) {
        let sessions = store.orderedSessions
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let now = Date()
        for session in sessions {
            let item = NSMenuItem(title: rowTitle(for: session, now: now),
                                  action: #selector(sessionRowClicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.image = circleImage(color: SessionStateColor.nsColor(for: session.state))
            item.toolTip = session.lastPromptPreview
            item.representedObject = session
            menu.addItem(item)
        }
    }

    private func rowTitle(for session: Session, now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(session.enteredStateAt)))
        let elapsed = String(format: "%d:%02d", secs / 60, secs % 60)
        return "\(session.projectName)  ·  \(session.state.displayLabel) · \(elapsed)"
    }

    private func circleImage(color: NSColor, size: CGSize = CGSize(width: 14, height: 14)) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).fill()
        img.unlockFocus()
        img.isTemplate = false
        return img
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

    @objc private func openDashboard()         { onOpenDashboard() }
    @objc private func openSettings()          { onOpenSettings() }

    @objc private func toggleDashboardWindow() {
        preferences.showDashboardWindow.toggle()
    }

    @objc private func sessionRowClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        onSessionClick(session)
    }
}

extension MenuBarController: NSMenuDelegate {
    /// Fires immediately before the dropdown is displayed. Rebuilding here is
    /// what keeps elapsed times and the session list fresh on every open and
    /// reflects toggle-state changes without an explicit observer.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}
