// iOS/ClaudeMonitorMobileApp.swift
import SwiftUI

@main
struct ClaudeMonitorMobileApp: App {
    @StateObject private var store = UsageStore()
    @StateObject private var sessions = SessionsStore()
    @StateObject private var browser = BridgeBrowser()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileRootView(store: store, sessions: sessions, browser: browser)
                .preferredColorScheme(.dark)
                // One Mac serves both tabs; the usage store owns the choice.
                .onReceive(store.$endpoint) { sessions.endpoint = $0 }
        }
        // Poll only while visible; iOS would suspend the loops anyway.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                store.startPolling()
                sessions.startPolling()
            } else {
                store.stopPolling()
                sessions.stopPolling()
            }
        }
    }
}
