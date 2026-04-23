// App/AppDelegate.swift
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    private let store = SessionStore()
    private var server: EventServer!
    private var sweeper: StaleSessionSweeper!
    private var dashboard: DashboardWindow!
    private var menuBar: MenuBarController!
    private var bridge: TerminalBridgeProtocol = TerminalBridge()
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Single instance guard.
        if case .alreadyRunning = SingleInstanceGuard.acquire(at: SingleInstanceGuard.defaultLocation) {
            NSApp.terminate(nil)
            return
        }

        // 2. Start the HTTP server and publish its port.
        server = EventServer { [weak self] event in
            DispatchQueue.main.async { self?.store.apply(event) }
        }
        do {
            try server.start()
            if let port = server.port {
                try PortFileWriter(destination: PortFileWriter.defaultLocation).write(port: port)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Claude Monitor couldn't start its event server"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }

        // 3. 60s stale sweep.
        sweeper = StaleSessionSweeper(store: store)
        sweeper.start()

        // 4. Dashboard window.
        let content = DashboardView(store: store, onClickSession: { [weak self] session in
            self?.handleClick(on: session)
        })
        dashboard = DashboardWindow(rootView: content, store: store)

        // 5. Menu bar.
        menuBar = MenuBarController(
            store: store,
            onOpenDashboard: { [weak self] in self?.dashboard.showAndBringToFront() },
            onOpenSettings:  { [weak self] in self?.openSettings() }
        )

        // 6. First-run onboarding.
        if !preferences.hasOnboarded && ProcessInfo.processInfo.environment["CLAUDE_MONITOR_SKIP_ONBOARDING"] != "1" {
            presentOnboarding()
        } else {
            dashboard.showAndBringToFront()
        }
    }

    private func handleClick(on session: Session) {
        let result = bridge.focus(tty: session.tty, expectedPid: session.pid)
        switch result {
        case .focused:
            break
        case .noSuchTab:
            NSLog("TerminalBridge: no tab matched tty=\(session.tty) pid=\(session.pid)")
            NSSound.beep()
        case .terminalNotRunning:
            NSLog("TerminalBridge: Terminal.app is not running; cannot focus tty=\(session.tty)")
            NSSound.beep()
        case .scriptError(let message):
            NSLog("TerminalBridge script error: \(message)")
            NSSound.beep()
        }
    }

    private func presentOnboarding() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Welcome to Claude Monitor"
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView(preferences: preferences) { [weak self, weak window] in
            window?.close()
            self?.dashboard.showAndBringToFront()
        })
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
