// App/UI/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        TabView {
            DirectoriesSettingsView(preferences: preferences)
                .frame(width: 560, height: 440)
                .tabItem { Label("Directories", systemImage: "folder") }

            AppearanceSettingsView(preferences: preferences)
                .frame(width: 560, height: 300)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            TerminalsSettingsView(preferences: preferences)
                .frame(width: 560, height: 320)
                .tabItem { Label("Terminals", systemImage: "terminal") }
        }
    }
}
