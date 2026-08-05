// App/AppDelegate.swift
import AppKit
import Combine
import SwiftUI
import WidgetKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    private var store: SessionStore!
    private var pushNotifier: PushNotifier!
    private var server: EventServer!
    private var sweeper: StaleSessionSweeper!
    private var dashboard: DashboardWindow!
    private var menuBar: MenuBarController!
    private lazy var bridge: TerminalBridgeProtocol = CompositeTerminalBridge(
        providers: TerminalRegistry.installed(),
        isDisabled: { [weak self] bundleID in
            self?.preferences.disabledTerminalBundleIDs.contains(bundleID) ?? false
        }
    )
    private var onboardingWindow: NSWindow?
    private var windowVisibilityCancellable: AnyCancellable?
    private var usagePoller: UsagePoller?
    private var usageBridge: UsageBridgeServer?
    private var usagePanelWindow: UsagePanelWindow?
    private var usageCancellables: Set<AnyCancellable> = []
    private var lastPublishedAccountsHash: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Single instance guard. Skipped in the test host so a running
        //    production instance can't make the unit-test app self-terminate.
        if ProcessInfo.processInfo.environment["CLAUDE_MONITOR_SKIP_SINGLE_INSTANCE"] != "1",
           case .alreadyRunning = SingleInstanceGuard.acquire(at: SingleInstanceGuard.defaultLocation) {
            NSApp.terminate(nil)
            return
        }

        // 1a. On app update, refresh the on-disk hook integration so users who
        //     already onboarded pick up new hook behavior without a manual
        //     reinstall. Gated on the build number so we only rewrite user config
        //     when the app actually changed: redeploy hook.sh, then reinstall any
        //     OUTDATED already-managed config dirs (never auto-opting in new ones).
        //     All failures only log — a hook problem must not block launch.
        let build = HookMaintenance.currentBuild
        if HookMaintenance.needsRefresh(currentBuild: build, lastBuild: preferences.lastHookRefreshBuild) {
            do {
                try HookScriptDeployer.deploy()
            } catch {
                NSLog("HookScriptDeployer: launch deploy failed — \(error)")
            }

            let managedDirs = preferences.managedConfigDirectoryPaths.map { URL(fileURLWithPath: $0) }
            var refreshed = HookMaintenance.reinstallOutdated(
                managedDirs: managedDirs,
                inspect: { try HookInstaller.inspect(configDir: $0).status },
                install: { try HookInstaller.install(configDir: $0) }
            ).count
            if preferences.prowlOfflineHookEnabled {
                refreshed += HookMaintenance.reinstallOutdated(
                    managedDirs: managedDirs,
                    inspect: { try HookInstaller.inspectOfflineHook(configDir: $0).status },
                    install: { try HookInstaller.installOfflineHook(configDir: $0) }
                ).count
            }
            if refreshed > 0 {
                NSLog("HookMaintenance: refreshed \(refreshed) outdated managed hook entr(ies) after update to build \(build)")
            }
            preferences.lastHookRefreshBuild = build
        }

        // 1b. Build the push notifier and wire it into the session store so every
        //     applied event is considered for a Prowl push (gated by master toggle).
        let prowlClient = ProwlClient()

        // Two-step wiring so the notifier can read the store's ignore set.
        // Both objects need each other; the store is created first as nil-safe
        // weak reference inside the notifier's closure.
        var storeRef: SessionStore?
        pushNotifier = PushNotifier(
            preferences: preferences,
            keychainGetter: { try? KeychainStore.prowl.get() },
            prowlSend: prowlClient.send,
            isIgnored: { sessionId in
                storeRef?.ignoredSessionIds.contains(sessionId) ?? false
            }
        )

        let notifier = pushNotifier!
        store = SessionStore(onEventApplied: { [weak notifier] event in
            notifier?.handle(event: event)
        })
        storeRef = store

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
        let content = DashboardView(store: store,
                                    preferences: preferences,
                                    onClickSession: { [weak self] session in
            self?.handleClick(on: session)
        })
        dashboard = DashboardWindow(rootView: content, store: store, preferences: preferences)

        // 5. Menu bar.
        menuBar = MenuBarController(
            store: store,
            preferences: preferences,
            onSessionClick: { [weak self] session in self?.handleClick(on: session) },
            onOpenDashboard: { [weak self] in self?.dashboard.showAndBringToFront() },
            onOpenSettings:  { [weak self] in self?.openSettings() }
        )

        // 5a. Usage-limit monitoring + LAN bridge for external displays.
        //     Re-applied whenever any of the usage preferences change.
        applyUsagePreferences()
        Publishers.Merge4(preferences.$usageMonitorEnabled.dropFirst().map { _ in () },
                          preferences.$usageBridgeEnabled.dropFirst().map { _ in () },
                          preferences.$usageBridgePort.dropFirst().map { _ in () },
                          preferences.$showUsagePanel.dropFirst().map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyUsagePreferences() }
            .store(in: &usageCancellables)

        // Account edits (rename/disable/reorder) only need a repoll, not a
        // bridge restart. Debounced so typing a name doesn't spam the API.
        Publishers.Merge3(preferences.$disabledUsageAccountDirs.dropFirst().map { _ in () },
                          preferences.$usageAccountNames.dropFirst().map { _ in () },
                          preferences.$usageAccountOrder.dropFirst().map { _ in () })
            .debounce(for: .milliseconds(750), scheduler: RunLoop.main)
            .sink { [weak self] in self?.repollUsageAccounts() }
            .store(in: &usageCancellables)

        // 6. First-run onboarding.
        if !preferences.hasOnboarded && ProcessInfo.processInfo.environment["CLAUDE_MONITOR_SKIP_ONBOARDING"] != "1" {
            presentOnboarding()
        } else if preferences.showDashboardWindow {
            dashboard.showAndBringToFront()
        }

        // 7. Honor the show/hide-window preference for the rest of the session.
        //    `dropFirst()` so we don't immediately re-trigger show/hide on the
        //    initial value we just respected above.
        windowVisibilityCancellable = preferences.$showDashboardWindow
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                guard let self else { return }
                if visible {
                    self.dashboard.showAndBringToFront()
                } else {
                    self.dashboard.hide()
                }
            }
    }

    /// Start/stop the usage poller and bridge server to match preferences.
    /// Idempotent — safe to call on every preference change. Only ever invoked
    /// on the main thread (launch, RunLoop.main sink, menu action), so hopping
    /// onto the main actor is an assertion, not a dispatch.
    private func applyUsagePreferences() {
        MainActor.assumeIsolated { applyUsagePreferencesOnMain() }
    }

    @MainActor
    private func applyUsagePreferencesOnMain() {
        if preferences.usageMonitorEnabled {
            if usagePoller == nil {
                let prefs = preferences
                usagePoller = UsagePoller(accountsProvider: {
                    UsageAccountConfig.resolve(discovered: UsageAccountConfig.discover(),
                                               order: prefs.usageAccountOrder,
                                               disabledDirs: prefs.disabledUsageAccountDirs,
                                               customNames: prefs.usageAccountNames)
                }, publish: { [weak self] snapshot in
                    guard let self else { return }
                    UsageSnapshotStore.write(snapshot)
                    // Only reload the widget's timeline when the render-relevant
                    // payload actually changed, so a no-op poll doesn't churn it.
                    var hasher = Hasher()
                    hasher.combine(snapshot.accounts)
                    let hash = hasher.finalize()
                    if hash != self.lastPublishedAccountsHash {
                        self.lastPublishedAccountsHash = hash
                        WidgetCenter.shared.reloadTimelines(ofKind: UsageSnapshotStore.widgetKind)
                    }
                })
            }
            usagePoller?.start()
        } else {
            usagePoller?.stop()
            UsageSnapshotStore.clear()
            lastPublishedAccountsHash = nil
            WidgetCenter.shared.reloadTimelines(ofKind: UsageSnapshotStore.widgetKind)
        }
        syncUsagePanelVisibility()

        let desiredPort = UInt16(clamping: preferences.usageBridgePort)
        let wantBridge = preferences.usageMonitorEnabled && preferences.usageBridgeEnabled
        if !wantBridge || usageBridge?.port != desiredPort {
            usageBridge?.stop()
            usageBridge = nil
        }
        if wantBridge, usageBridge == nil, let poller = usagePoller {
            let prefs = preferences
            let bridge = UsageBridgeServer(snapshot: { poller.snapshot() },
                                           display: { prefs.usageBridgeMirrorsDisplay ? poller.displayOn : true })
            do {
                try bridge.start(port: desiredPort)
                usageBridge = bridge
            } catch {
                NSLog("UsageBridgeServer: failed to start on port \(desiredPort) — \(error)")
            }
        }
    }

    /// Show/hide the panel to match `showUsagePanel` (gated on the master
    /// toggle). Only raises the window when it isn't already visible so
    /// unrelated preference changes don't steal focus.
    @MainActor
    private func syncUsagePanelVisibility() {
        let wantVisible = preferences.usageMonitorEnabled && preferences.showUsagePanel
        guard wantVisible, let poller = usagePoller else {
            usagePanelWindow?.hide()
            return
        }
        if usagePanelWindow == nil {
            usagePanelWindow = UsagePanelWindow(poller: poller, onUserClose: { [weak self] in
                self?.preferences.showUsagePanel = false
            })
        }
        if usagePanelWindow?.isVisible != true {
            usagePanelWindow?.showAndBringToFront()
        }
    }

    /// Account edits change what the poller reports, not how it runs — fetch a
    /// fresh snapshot so the panel and the ESP32 don't wait out the 180s tick.
    private func repollUsageAccounts() {
        MainActor.assumeIsolated {
            guard preferences.usageMonitorEnabled, let poller = usagePoller else { return }
            Task { await poller.pollAll() }
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
            if self?.preferences.showDashboardWindow == true {
                self?.dashboard.showAndBringToFront()
            }
        })
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        // Activate first — when the dashboard window is hidden (menu mode) the
        // app may not be frontmost, in which case `sendAction` fails silently
        // because the responder chain has no key window to route through.
        NSApp.activate(ignoringOtherApps: true)
        // Trigger the Settings item from the application menu directly. This is
        // what Cmd+, routes to and is more reliable than `sendAction(_:to:nil)`,
        // which depends on a key window being present to walk the responder chain.
        DispatchQueue.main.async {
            guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
            let item = appMenu.items.first { menuItem in
                let title = menuItem.title
                return title.hasPrefix("Settings") || title.hasPrefix("Preferences")
            }
            if let item, let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
        }
    }

    /// Show a customized standard About panel. The default panel already pulls the
    /// app icon, version, build, and `NSHumanReadableCopyright` from the bundle;
    /// we only add a clickable cliq.dev link to the credits area above the copyright.
    static func showAboutPanel() {
        let link = URL(string: "https://www.cliq.dev/")!
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: "cliq.dev",
            attributes: [
                .link: link,
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.systemFont(ofSize: 11),
                .paragraphStyle: paragraph,
            ]
        )
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
