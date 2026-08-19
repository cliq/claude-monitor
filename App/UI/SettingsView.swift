// App/UI/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let updateChecker: UpdateChecker

    var body: some View {
        TabView {
            DirectoriesSettingsView(preferences: preferences)
                .frame(width: 560, height: 440)
                .tabItem { Label("Directories", systemImage: "folder") }

            GeneralSettingsView(preferences: preferences, updateChecker: updateChecker)
                .frame(width: 560, height: 300)
                .tabItem { Label("General", systemImage: "gearshape") }

            AppearanceSettingsView(preferences: preferences)
                .frame(width: 560, height: 300)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            TerminalsSettingsView(preferences: preferences)
                .frame(width: 560, height: 320)
                .tabItem { Label("Terminals", systemImage: "terminal") }

            NotificationsSettingsView(preferences: preferences)
                .frame(width: 560, height: 420)
                .tabItem { Label("Push Notifications", systemImage: "bell.badge") }

            UsageSettingsView(preferences: preferences)
                .frame(width: 560, height: 540)
                .tabItem { Label("Usage", systemImage: "gauge.with.needle") }
        }
    }
}
