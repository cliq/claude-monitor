// iOS/ClaudeMonitorMobileApp.swift
import SwiftUI

@main
struct ClaudeMonitorMobileApp: App {
    @StateObject private var store = UsageStore()
    @StateObject private var sessions = SessionsStore()
    @StateObject private var browser = BridgeBrowser()
    @AppStorage("selectedTab") private var selectedTab = Tab.sessions
    @Environment(\.scenePhase) private var scenePhase

    enum Tab: String {
        case sessions, usage
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                MobileSessionsView(sessions: sessions, store: store, browser: browser)
                    .tabItem { Label("Sessions", systemImage: "square.grid.2x2.fill") }
                    .tag(Tab.sessions)
                MobileUsageView(store: store, browser: browser)
                    .tabItem { Label("Usage", systemImage: "gauge.with.dots.needle.50percent") }
                    .tag(Tab.usage)
            }
            .tint(UsagePalette.name)
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
