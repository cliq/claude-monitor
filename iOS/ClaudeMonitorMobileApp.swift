// iOS/ClaudeMonitorMobileApp.swift
import SwiftUI

@main
struct ClaudeMonitorMobileApp: App {
    @StateObject private var store = UsageStore()
    @StateObject private var browser = BridgeBrowser()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileUsageView(store: store, browser: browser)
                .preferredColorScheme(.dark)
        }
        // Poll only while visible; iOS would suspend the loop anyway.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { store.startPolling() } else { store.stopPolling() }
        }
    }
}
