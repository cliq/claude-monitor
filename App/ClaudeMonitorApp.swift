// App/ClaudeMonitorApp.swift
import SwiftUI
import AppKit

@main
struct ClaudeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // A Settings scene hosts the preferences window. All other windows are
        // constructed in AppDelegate so we control their lifetimes directly.
        Settings {
            SettingsView(preferences: delegate.preferences)
        }
    }
}
